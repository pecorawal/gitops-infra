#!/usr/bin/env bash
# =============================================================================
#  Prepara o namespace e as credenciais de UM cluster, a partir da Credential
#  compartilhada do ACM. Para ambientes SEM o External Secrets Operator.
#
#  Faz, de forma idempotente:
#    1. cria o namespace <cluster>
#    2. cria <cluster>-azure-creds   (Opaque)  osServicePrincipal.json + ssh-privatekey
#    3. cria <cluster>-pull-secret   (dockerconfigjson) .dockerconfigjson
#
#  Os nomes seguem a convencao que o chart espera, entao no values.yaml basta:
#      provision:
#        credentials:
#          mode: existing
#
#  Uso (no HUB, como cluster-admin):
#    ./docs/cliente/scripts/preparar-credenciais.sh <cluster> [<ns-origem>/<credential>]
#
#  Sem o segundo argumento, o script localiza sozinho a Credential do ACM
#  (label cluster.open-cluster-management.io/type=azr).
# =============================================================================
set -euo pipefail

CLUSTER="${1:?uso: $0 <cluster> [<ns-origem>/<credential>]}"
ORIGEM="${2:-}"

command -v oc      >/dev/null || { echo "ERRO: 'oc' nao encontrado no PATH." >&2; exit 1; }
command -v python3 >/dev/null || { echo "ERRO: 'python3' nao encontrado no PATH." >&2; exit 1; }
oc whoami >/dev/null 2>&1     || { echo "ERRO: sem sessao no cluster. Faca 'oc login' no HUB." >&2; exit 1; }

echo "Hub: $(oc whoami --show-server)"

# ------------------------------------------------ localizar a Credential do ACM
if [[ -z "$ORIGEM" ]]; then
  ACHADAS=$(oc get secret -A -l cluster.open-cluster-management.io/type=azr \
    -o go-template='{{range .items}}{{.metadata.namespace}}/{{.metadata.name}}{{"\n"}}{{end}}' 2>/dev/null || true)
  QTD=$(printf '%s' "$ACHADAS" | grep -c . || true)
  if [[ "$QTD" -eq 0 ]]; then
    echo "ERRO: nenhuma Credential Azure do ACM encontrada (label type=azr)." >&2
    echo "      Crie em: ACM > Credentials > Add credential > Microsoft Azure" >&2
    echo "      Ou informe explicitamente:  $0 $CLUSTER <ns>/<secret>" >&2
    exit 1
  elif [[ "$QTD" -eq 1 ]]; then
    ORIGEM=$(printf '%s' "$ACHADAS" | grep .)
    echo "Credential encontrada: $ORIGEM"
  else
    echo "Mais de uma Credential Azure encontrada. Escolha uma e repita:" >&2
    printf '%s\n' "$ACHADAS" | grep . | sed 's/^/  /' >&2
    echo >&2; echo "  $0 $CLUSTER <ns>/<credential>" >&2
    exit 1
  fi
fi
SRC_NS="${ORIGEM%%/*}"
SRC_NAME="${ORIGEM##*/}"

oc get secret "$SRC_NAME" -n "$SRC_NS" >/dev/null 2>&1 \
  || { echo "ERRO: secret '$SRC_NAME' nao existe no namespace '$SRC_NS'." >&2; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
oc get secret "$SRC_NAME" -n "$SRC_NS" -o json > "$TMP/src.json"

# Extrai uma chave do secret e grava decodificada. Sai 1 se a chave nao existir.
# Feito em python porque os nomes tem ponto (osServicePrincipal.json), o que
# torna o jsonpath do oc traicoeiro.
extrai() { # <chave> <arquivo-destino>
  python3 - "$TMP/src.json" "$1" "$2" <<'PY'
import base64, json, sys
data = json.load(open(sys.argv[1])).get("data") or {}
if sys.argv[2] not in data:
    sys.exit(1)
open(sys.argv[3], "wb").write(base64.b64decode(data[sys.argv[2]]))
PY
}

echo "Chaves na Credential:"
python3 -c 'import json,sys;[print("  -",k) for k in sorted((json.load(open(sys.argv[1])).get("data") or {}))]' "$TMP/src.json"

falta=0
for k in osServicePrincipal.json pullSecret; do
  extrai "$k" "$TMP/$k" || { echo "ERRO: a Credential $ORIGEM nao tem a chave '$k'." >&2; falta=1; }
done
[[ $falta -eq 0 ]] || exit 1

# --------------------------------------------------------------- 1. o namespace
# Um namespace em Terminating aceita 'oc apply' sem erro (e no-op), mas recusa
# qualquer objeto novo. Sem esta trava o script seguiria e falharia so na criacao
# do Secret, com uma mensagem que nao explica a causa.
FASE=$(oc get namespace "$CLUSTER" -o jsonpath='{.status.phase}' 2>/dev/null || true)
if [[ "$FASE" == "Terminating" ]]; then
  DESDE=$(oc get namespace "$CLUSTER" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null)
  cat >&2 <<FIM
ERRO: o namespace $CLUSTER esta em Terminating desde $DESDE.
      Ele nao aceita objetos novos, entao nao adianta recriar as credenciais
      agora. Alguem o apagou e a delecao esta travada.

      Descubra o que esta segurando:

        # o que sobrou dentro dele
        oc api-resources --verbs=list --namespaced -o name \\
          | xargs -n1 oc get -n $CLUSTER --show-kind --ignore-not-found 2>/dev/null

        # suspeito 1: ClusterDeployment com finalizer do Hive (job de deprovision)
        oc get clusterdeployment -n $CLUSTER \\
          -o jsonpath='{range .items[*]}{.metadata.name}: {.metadata.finalizers}{"\\n"}{end}'
        oc logs -n $CLUSTER -l hive.openshift.io/job-type=deprovision --tail=50

        # suspeito 2: APIService indisponivel trava a delecao de QUALQUER namespace
        oc get apiservice | grep -v ' True '

      ATENCAO: se houver um ClusterDeployment, esperar e o certo -- o Hive esta
      destruindo o cluster na Azure e forcar o finalizer deixaria recursos orfaos.
FIM
  exit 1
fi
oc create namespace "$CLUSTER" --dry-run=client -o yaml | oc apply -f - >/dev/null
oc label namespace "$CLUSTER" \
  "cluster.open-cluster-management.io/managedCluster=$CLUSTER" --overwrite >/dev/null
echo "OK  namespace/$CLUSTER"

# ------------------------------------------------ 2. osServicePrincipal + ssh
ARGS=(--from-file=osServicePrincipal.json="$TMP/osServicePrincipal.json")
if extrai ssh-privatekey "$TMP/ssh-privatekey" && [[ -s "$TMP/ssh-privatekey" ]]; then
  ARGS+=(--from-file=ssh-privatekey="$TMP/ssh-privatekey")
else
  echo "    (a Credential nao tem ssh-privatekey; o cluster subira sem acesso SSH aos nos)"
fi
oc create secret generic "${CLUSTER}-azure-creds" -n "$CLUSTER" "${ARGS[@]}" \
  --dry-run=client -o yaml | oc apply -f - >/dev/null
echo "OK  secret/${CLUSTER}-azure-creds"

# ---------------------------------------------------------------- 3. pull secret
# A Credential do ACM guarda o pull secret em texto, na chave "pullSecret".
# O Hive exige tipo kubernetes.io/dockerconfigjson, chave ".dockerconfigjson".
python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$TMP/pullSecret" 2>/dev/null \
  || { echo "ERRO: a chave pullSecret da Credential nao contem JSON valido." >&2; exit 1; }
oc create secret docker-registry "${CLUSTER}-pull-secret" -n "$CLUSTER" \
  --from-file=.dockerconfigjson="$TMP/pullSecret" \
  --dry-run=client -o yaml | oc apply -f - >/dev/null
echo "OK  secret/${CLUSTER}-pull-secret"

echo
echo "Pronto. Em clusters/$CLUSTER/values.yaml deixe:"
echo "    provision:"
echo "      credentials:"
echo "        mode: existing"
echo "Depois preencha os <PREENCHER>, vire provision.enabled: true e commite."
