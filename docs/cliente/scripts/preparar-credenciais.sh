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
#  Os nomes seguem a mesma convencao que o chart espera, entao no values.yaml
#  basta:
#      provision:
#        credentials:
#          mode: existing
#
#  Uso (no HUB, como cluster-admin):
#    ./docs/cliente/scripts/preparar-credenciais.sh <cluster> [<ns-origem>/<credential>]
#
#  Sem o segundo argumento, o script localiza sozinho a Credential do ACM
#  (label cluster.open-cluster-management.io/type=azr). Se houver mais de uma,
#  ele lista e pede que voce escolha.
# =============================================================================
set -euo pipefail

CLUSTER="${1:?uso: $0 <cluster> [<ns-origem>/<credential>]}"
ORIGEM="${2:-}"

# ------------------------------------------------ localizar a Credential do ACM
if [[ -z "$ORIGEM" ]]; then
  mapfile -t ACHADAS < <(oc get secret -A -l cluster.open-cluster-management.io/type=azr \
    -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null)
  case ${#ACHADAS[@]} in
    0) echo "ERRO: nenhuma Credential Azure do ACM encontrada." >&2
       echo "      Crie em: ACM > Credentials > Add credential > Microsoft Azure" >&2
       exit 1 ;;
    1) ORIGEM="${ACHADAS[0]}"; echo "Credential encontrada: $ORIGEM" ;;
    *) echo "Mais de uma Credential Azure encontrada. Escolha uma e repita:" >&2
       printf '  %s\n' "${ACHADAS[@]}" >&2
       echo >&2; echo "  $0 $CLUSTER <ns>/<credential>" >&2
       exit 1 ;;
  esac
fi
SRC_NS="${ORIGEM%%/*}"
SRC_NAME="${ORIGEM##*/}"

oc get secret "$SRC_NAME" -n "$SRC_NS" >/dev/null 2>&1 \
  || { echo "ERRO: secret $ORIGEM nao existe." >&2; exit 1; }

# ------------------------------------------------------ conferir as chaves dela
falta=0
for k in osServicePrincipal.json pullSecret; do
  oc get secret "$SRC_NAME" -n "$SRC_NS" -o "jsonpath={.data['$(sed 's/\./\\./g' <<<"$k")']}" \
    | grep -q . || { echo "ERRO: a Credential $ORIGEM nao tem a chave '$k'." >&2; falta=1; }
done
[[ $falta -eq 0 ]] || { echo "      Chaves presentes:" >&2
  oc get secret "$SRC_NAME" -n "$SRC_NS" -o json | python3 -c \
    'import json,sys;[print("        -",k) for k in json.load(sys.stdin)["data"]]' >&2; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
get() { oc get secret "$SRC_NAME" -n "$SRC_NS" \
  -o "jsonpath={.data['$(sed 's/\./\\./g' <<<"$1")']}" | base64 -d; }

# --------------------------------------------------------------- 1. o namespace
oc create namespace "$CLUSTER" --dry-run=client -o yaml | oc apply -f - >/dev/null
oc label namespace "$CLUSTER" \
  "cluster.open-cluster-management.io/managedCluster=$CLUSTER" --overwrite >/dev/null
echo "OK  namespace/$CLUSTER"

# ------------------------------------------------ 2. osServicePrincipal + ssh
get 'osServicePrincipal.json' > "$TMP/osServicePrincipal.json"
ARGS=(--from-file=osServicePrincipal.json="$TMP/osServicePrincipal.json")
if get 'ssh-privatekey' > "$TMP/ssh-privatekey" 2>/dev/null && [[ -s "$TMP/ssh-privatekey" ]]; then
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
get 'pullSecret' > "$TMP/ps.json"
python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$TMP/ps.json" \
  || { echo "ERRO: a chave pullSecret nao contem JSON valido." >&2; exit 1; }
oc create secret docker-registry "${CLUSTER}-pull-secret" -n "$CLUSTER" \
  --from-file=.dockerconfigjson="$TMP/ps.json" \
  --dry-run=client -o yaml | oc apply -f - >/dev/null
echo "OK  secret/${CLUSTER}-pull-secret"

echo
echo "Pronto. Em clusters/$CLUSTER/values.yaml deixe:"
echo "    provision:"
echo "      credentials:"
echo "        mode: existing"
echo "Depois preencha os <PREENCHER>, vire provision.enabled: true e commite."
