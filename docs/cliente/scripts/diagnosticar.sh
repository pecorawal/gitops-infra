#!/usr/bin/env bash
# =============================================================================
#  Percorre a cadeia inteira e diz ONDE ela parou.
#
#    ApplicationSet -> bundle-<cluster> -> provision-<cluster> -> Namespace
#      -> ExternalSecrets -> ClusterDeployment -> ManagedCluster -> ArgoCD
#
#  Uso (no HUB, a partir da raiz do repositorio):
#    ./docs/cliente/scripts/diagnosticar.sh <nome-do-cluster>
# =============================================================================
set -uo pipefail

CLUSTER="${1:?uso: $0 <nome-do-cluster>}"
NS_ARGO="${NS_ARGO:-openshift-gitops}"
VALUES="clusters/${CLUSTER}/values.yaml"

ok()   { printf "  \033[32mOK\033[0m    %s\n" "$1"; }
bad()  { printf "  \033[31mFALHA\033[0m %s\n" "$1"; }
warn() { printf "  \033[33mAVISO\033[0m %s\n" "$1"; }
hdr()  { printf "\n\033[1m== %s\033[0m\n" "$1"; }

# ---------------------------------------------------------------- 1. o arquivo
hdr "1. Arquivo do cluster"
if [[ ! -f "$VALUES" ]]; then
  bad "$VALUES nao existe."
  echo "        O diretorio precisa se chamar exatamente como clusterName."
  ls -d clusters/*/ 2>/dev/null | sed 's/^/          existe: /'
  exit 1
fi
ok "$VALUES encontrado"

NOME=$(python3 -c "import yaml;print(yaml.safe_load(open('$VALUES'))['clusterName'])" 2>/dev/null)
if [[ "$NOME" != "$CLUSTER" ]]; then
  bad "clusterName='$NOME' difere do nome do diretorio '$CLUSTER'."
  echo "        O ApplicationSet nomeia a Application pelo DIRETORIO, mas os charts"
  echo "        usam clusterName. Os dois precisam ser iguais."
else
  ok "clusterName confere com o diretorio"
fi

ENABLED=$(python3 -c "import yaml;print(yaml.safe_load(open('$VALUES'))['provision']['enabled'])" 2>/dev/null)
if [[ "$ENABLED" != "True" ]]; then
  bad "provision.enabled = $ENABLED"
  echo
  echo "        ESTA E A CAUSA MAIS COMUM DE 'nao cria nem o namespace'."
  echo "        Com o interruptor em false o chart nao emite NENHUM objeto -- nem"
  echo "        Application filha, nem Namespace. O bundle fica verde, sem recursos."
  echo
  echo "        Corrija em $VALUES:"
  echo "            provision:"
  echo "              enabled: true"
  exit 1
fi
ok "provision.enabled = true"

MODE=$(python3 -c "import yaml;print(yaml.safe_load(open('$VALUES'))['provision']['credentials']['mode'])" 2>/dev/null)
ok "provision.credentials.mode = $MODE"

# ------------------------------------------------------- 2. render local (Helm)
hdr "2. Renderizacao local dos charts"
if ! OUT=$(helm template "$CLUSTER" charts/azure-ipi-cluster -f "$VALUES" 2>&1); then
  bad "charts/azure-ipi-cluster nao renderiza:"
  echo "$OUT" | sed 's/^/        /'
  echo
  echo "        Enquanto isto falhar, a Application provision-$CLUSTER fica em"
  echo "        ComparisonError e nada e aplicado -- inclusive o Namespace."
  exit 1
fi
ok "charts/azure-ipi-cluster renderiza ($(grep -c '^kind:' <<<"$OUT") objetos)"
grep '^kind:' <<<"$OUT" | sort | uniq -c | sed 's/^/        /'

if ! helm template "$CLUSTER" charts/cluster-bundle -f "$VALUES" \
      --set "global.valuesPath=${VALUES}" >/dev/null 2>&1; then
  bad "charts/cluster-bundle nao renderiza"
  exit 1
fi
ok "charts/cluster-bundle renderiza"

# ------------------------------------------------------------- 3. lado cluster
if ! oc whoami >/dev/null 2>&1; then
  warn "sem sessao oc -- parando aqui. Faca login no HUB para as checagens seguintes."
  exit 0
fi

hdr "3. Credenciais (mode=$MODE)"
if [[ "$MODE" == "externalSecret" ]]; then
  if oc get crd externalsecrets.external-secrets.io >/dev/null 2>&1; then
    ok "CRD ExternalSecret presente (External Secrets Operator instalado)"
    oc get clustersecretstore "$(python3 -c "import yaml;print(yaml.safe_load(open('$VALUES'))['provision']['credentials']['clusterSecretStore'])")" \
      >/dev/null 2>&1 && ok "ClusterSecretStore existe" || bad "ClusterSecretStore nao existe (bootstrap/05-acm-credentials-store.yaml)"
  else
    bad "mode=externalSecret mas o External Secrets Operator NAO esta instalado"
    echo
    echo "        ESTA E A CAUSA. Sem o CRD, o ArgoCD nao consegue nem comparar o"
    echo "        estado desejado (\"no matches for kind ExternalSecret\"), a"
    echo "        Application inteira vai a ComparisonError e NADA e aplicado --"
    echo "        inclusive o Namespace, que esta no mesmo chart."
    echo
    echo "        Corrija em $VALUES:"
    echo "            provision:"
    echo "              credentials:"
    echo "                mode: existing"
    echo "        e rode uma vez:"
    echo "            ./docs/cliente/scripts/preparar-credenciais.sh $CLUSTER"
    exit 1
  fi
else
  for sec in "${CLUSTER}-azure-creds" "${CLUSTER}-pull-secret"; do
    if oc get secret "$sec" -n "$CLUSTER" >/dev/null 2>&1; then
      ok "secret/$sec existe"
    else
      bad "secret/$sec NAO existe em $CLUSTER"
      echo "        Rode:  ./docs/cliente/scripts/preparar-credenciais.sh $CLUSTER"
      echo "        (o Hive so le Secrets do namespace do ClusterDeployment)"
    fi
  done
fi

hdr "4. ApplicationSet"
if oc get applicationsets.argoproj.io cliente-clusters -n "$NS_ARGO" >/dev/null 2>&1; then
  ok "applicationset/cliente-clusters existe"
  REV=$(oc get applicationsets.argoproj.io cliente-clusters -n "$NS_ARGO" -o jsonpath='{.spec.generators[0].git.revision}')
  echo "        revision do generator: $REV   (a branch precisa ter o commit)"
  oc get applicationsets.argoproj.io cliente-clusters -n "$NS_ARGO" \
    -o jsonpath='{range .status.conditions[*]}        {.type}={.status} {.message}{"\n"}{end}' 2>/dev/null
else
  bad "applicationset/cliente-clusters NAO existe"
  echo "        Aplique o root:  oc apply -f argocd/root-cliente.yaml"
  echo "        E confira:       oc get applications.argoproj.io cliente-bootstrap -n $NS_ARGO"
  exit 1
fi

hdr "5. Applications geradas"
for app in "bundle-$CLUSTER" "provision-$CLUSTER"; do
  if oc get applications.argoproj.io "$app" -n "$NS_ARGO" >/dev/null 2>&1; then
    read -r SYNC HEALTH < <(oc get applications.argoproj.io "$app" -n "$NS_ARGO" \
      -o jsonpath='{.status.sync.status} {.status.health.status}')
    ok "$app  sync=$SYNC  health=$HEALTH"
    oc get applications.argoproj.io "$app" -n "$NS_ARGO" \
      -o jsonpath='{range .status.conditions[*]}        [{.type}] {.message}{"\n"}{end}' 2>/dev/null
  else
    bad "$app nao existe"
    [[ "$app" == "bundle-$CLUSTER" ]] && \
      echo "        O generator nao casou clusters/*/values.yaml, ou a branch do
        generator ($REV) nao tem o seu commit."
  fi
done

hdr "6. Objetos no hub"
if NSJSON=$(oc get namespace "$CLUSTER" -o json 2>/dev/null); then
  TERM=$(python3 -c "import json,sys;d=json.load(sys.stdin);print(d['metadata'].get('deletionTimestamp') or '')" <<<"$NSJSON")
  if [[ -n "$TERM" ]]; then
    bad "namespace/$CLUSTER esta em Terminating desde $TERM"
    echo "        Quase sempre e o ClusterDeployment segurando, com o finalizer do"
    echo "        Hive, ate o job de deprovision terminar:"
    echo "          oc logs -n $CLUSTER -l hive.openshift.io/job-type=deprovision -f"
  else
    ok "namespace/$CLUSTER existe"
  fi
else
  bad "namespace/$CLUSTER NAO existe"
  echo "        A mensagem do ArgoCD \"is missing, it might have been deleted\" so"
  echo "        diz que esta declarado no Git e ausente no cluster -- nao diz se"
  echo "        foi apagado ou se nunca chegou a ser criado."
  echo "        Se os passos 1 a 4 acima estao OK, ele nunca foi criado: veja o erro"
  echo "        de sincronizacao em provision-$CLUSTER, no passo 5."
  echo "        Se ja existiu, confira o historico:"
  echo "          oc get applications.argoproj.io provision-$CLUSTER -n $NS_ARGO -o jsonpath='{.status.operationState.message}'"
fi

for kind in externalsecret secret clusterdeployment machinepool; do
  n=$(oc get "$kind" -n "$CLUSTER" --no-headers 2>/dev/null | wc -l)
  printf "        %-18s %s\n" "$kind" "$n"
done
oc get externalsecret -n "$CLUSTER" --no-headers 2>/dev/null \
  | awk '{printf "        externalsecret %-32s %s\n", $1, $3}'

hdr "7. Protecoes contra delecao acidental"
FIN=$(oc get applications.argoproj.io "provision-$CLUSTER" -n "$NS_ARGO" -o jsonpath='{.metadata.finalizers}' 2>/dev/null)
if [[ -n "$FIN" && "$FIN" == *"resources-finalizer"* ]]; then
  bad "provision-$CLUSTER ainda tem resources-finalizer: $FIN"
  echo "        Versao antiga do chart. Se o bundle prunar esta Application, ela"
  echo "        apaga em cascata o Namespace e o ClusterDeployment -- e o Hive"
  echo "        destroi o cluster na Azure. Atualize a branch e sincronize."
else
  ok "provision-$CLUSTER sem resources-finalizer (sem delecao em cascata)"
fi
JP='{.metadata.annotations.argocd\.argoproj\.io/sync-options}'
check_protecao() { # <kind> [-n <ns>]
  local kind="$1"; shift
  local so; so=$(oc get "$kind" "$CLUSTER" "$@" -o jsonpath="$JP" 2>/dev/null)
  if [[ -z "$so" ]]; then
    warn "$kind/$CLUSTER: sem anotacao sync-options (objeto ausente ou chart antigo)"
  elif [[ "$so" == *"Delete=false"* ]]; then
    ok "$kind/$CLUSTER protegido: $so"
  else
    bad "$kind/$CLUSTER sem Delete=false (atual: $so)"
    echo "        Prune=false sozinho NAO impede delecao em cascata."
  fi
}
check_protecao namespace
check_protecao clusterdeployment -n "$CLUSTER"

hdr "8. RBAC (namespaces)"
SA="system:serviceaccount:${NS_ARGO}:openshift-gitops-argocd-application-controller"
if [[ "$(oc auth can-i create namespaces --as="$SA" 2>/dev/null)" == "yes" ]]; then
  ok "o ArgoCD pode criar namespaces"
else
  bad "o ArgoCD NAO pode criar namespaces"
  echo "        oc apply -f argocd/00-rbac-acm.yaml"
  echo "        ./docs/cliente/scripts/verificar-rbac-acm.sh"
fi

echo
echo "Se tudo acima esta OK e o namespace continua ausente, veja a mensagem em"
echo "  oc get applications.argoproj.io provision-$CLUSTER -n $NS_ARGO -o jsonpath='{.status.conditions}' | python3 -m json.tool"
