#!/usr/bin/env bash
# =============================================================================
#  Por que o interruptor que liguei nao surtiu efeito?
#
#  Compara TRES coisas que precisam concordar:
#    1. o que esta no arquivo em disco  (clusters/<cluster>/values.yaml)
#    2. o que o Helm efetivamente le    (merge com os defaults do chart)
#    3. o que o ArgoCD leu de fato      (ConfigMap bundle-<cluster>-info)
#
#  Uso:
#    ./docs/cliente/scripts/verificar-values.sh <cluster>
#  (o passo 3 e pulado se voce nao estiver logado no hub)
# =============================================================================
set -euo pipefail

CLUSTER="${1:?uso: $0 <cluster>}"
VALUES="clusters/${CLUSTER}/values.yaml"
[[ -f "$VALUES" ]] || { echo "arquivo nao encontrado: $VALUES" >&2; exit 1; }

BLOCOS="provision operators certManager ingress externalDNS nsgRule autoscaling identityProvider"

echo "=== 1. ARQUIVO EM DISCO: $VALUES"

# --- chave duplicada: o YAML aceita, e a ULTIMA ocorrencia vence em silencio ---
python3 - "$VALUES" <<'PY'
import sys, yaml
caminho = sys.argv[1]

class Dup(yaml.SafeLoader): pass

achadas = []
def mapa(loader, node, deep=False):
    vistas = {}
    for kn, _ in node.value:
        k = loader.construct_object(kn, deep=True)
        if k in vistas:
            achadas.append((k, vistas[k], kn.start_mark.line + 1))
        vistas[k] = kn.start_mark.line + 1
    return yaml.SafeLoader.construct_mapping(loader, node, deep)

Dup.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, mapa)
d = yaml.load(open(caminho), Dup)

if achadas:
    print("  !! CHAVE DUPLICADA -- a ultima ocorrencia vence e a primeira e ignorada:")
    for k, l1, l2 in achadas:
        print(f"     '{k}' nas linhas {l1} e {l2}")
    print("     Foi ela que apagou o valor que voce editou. Remova a duplicata.")
else:
    print("  ok  sem chaves duplicadas")

print(f"  clusterName: {d.get('clusterName')!r}")
if d.get('clusterName') != caminho.split('/')[1]:
    print(f"  !! clusterName difere do nome do diretorio ({caminho.split('/')[1]})")

for b in "provision operators certManager ingress externalDNS nsgRule autoscaling identityProvider".split():
    bl = d.get(b)
    if bl is None:
        print(f"  {b:18} AUSENTE no arquivo")
        continue
    sub = {n: v.get('enabled') for n, v in bl.items()
           if isinstance(v, dict) and 'enabled' in v}
    extra = f"   aninhados={sub}" if sub else ""
    print(f"  {b:18} enabled={bl.get('enabled')}{extra}")
PY

echo
echo "=== 2. O QUE O HELM LE (merge chart + values do cluster)"
if command -v helm >/dev/null; then
  helm template "$CLUSTER" charts/cluster-bundle \
      -f "$VALUES" --set global.valuesPath="$VALUES" \
      | python3 -c "
import sys, yaml
for doc in yaml.safe_load_all(sys.stdin):
    if doc and doc.get('kind') == 'ConfigMap':
        for k, v in sorted(doc['data'].items()):
            print(f'  {k:26} {v}')
" || echo "  !! o render falhou -- a mensagem acima diz o motivo"
else
  echo "  SKIP helm nao encontrado"
fi

echo
echo "=== 3. O QUE O ARGOCD LEU DE FATO"
if oc whoami >/dev/null 2>&1; then
  if oc get cm "bundle-${CLUSTER}-info" -n openshift-gitops >/dev/null 2>&1; then
    oc get cm "bundle-${CLUSTER}-info" -n openshift-gitops \
      -o go-template='{{range $k,$v := .data}}  {{printf "%-26s %s" $k $v}}{{"\n"}}{{end}}'
    echo
    echo "  Divergiu do passo 2? Entao o ArgoCD nao esta lendo este arquivo."
    echo "  Confira o valueFiles que a Application do bundle esta usando:"
    echo "    oc get applications.argoproj.io bundle-${CLUSTER} -n openshift-gitops \\"
    echo "      -o jsonpath='{.spec.source.helm}{\"\\n\"}'"
  else
    echo "  ConfigMap bundle-${CLUSTER}-info nao existe."
    echo "  Ou o bundle ainda nao sincronizou a versao nova do chart, ou a"
    echo "  Application bundle-${CLUSTER} nem existe:"
    echo "    oc get applications.argoproj.io -n openshift-gitops | grep ${CLUSTER}"
  fi
else
  echo "  SKIP nao logado (oc login <hub>)"
fi
