#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Demo A · gate de segurança do build, rodado do notebook do apresentador
#  (o workflow .github/workflows/acs-image-check.yaml chama este mesmo script).
#
#    export ROX_ENDPOINT=central-rhacs-operator.apps.<cluster>:443
#    export ROX_API_TOKEN=<token>          # ou ROX_ADMIN_PASSWORD=<senha do admin>
#    ./roxctl-check.sh                                   # Log4Shell (padrão) -> BARRADA
#    ./roxctl-check.sh registry.access.redhat.com/ubi9/ubi-minimal:9.8   -> APROVADA
#
#  CRITÉRIO
#    O roxctl image check avalia a imagem contra as políticas com estágio BUILD.
#    A imagem é BARRADA se violar ao menos uma política com enforcement de build
#    (FAIL_BUILD_ENFORCEMENT; no JSON, failingCheck=true). Violações sem
#    enforcement aparecem como "só alerta" e NÃO reprovam.
#
#  CONTEXTO (cluster + namespace)
#    As políticas DEMO têm scope no namespace pagamentos-demo. Sem --cluster e
#    --namespace o Central avalia a imagem sem contexto e IGNORA políticas com
#    scope — por isso o check precisa do destino do deploy. O namespace precisa
#    existir no cluster (ver preparação D-1 do roteiro).
#      ROX_CLUSTER    nome do cluster no ACS (padrão: lido do SecuredCluster via oc)
#      ROX_NAMESPACE  namespace de destino (padrão: pagamentos-demo)
#
#  SAÍDA
#    0 = APROVADA · 1 = BARRADA · 2 = ERRO (o check não rodou; não conta como barrada)
# ---------------------------------------------------------------------------
set -uo pipefail
IMAGE="${1:-ghcr.io/christophetd/log4shell-vulnerable-app@sha256:6f88430688108e512f7405ac3c73d47f5c370780b94182854ea2cddc6bd59929}"   # Log4Shell
: "${ROX_ENDPOINT:?defina ROX_ENDPOINT}"
if [[ -z "${ROX_API_TOKEN:-}" && -z "${ROX_ADMIN_PASSWORD:-}" ]]; then
  echo "defina ROX_API_TOKEN ou ROX_ADMIN_PASSWORD" >&2; exit 2
fi
ROX_NAMESPACE="${ROX_NAMESPACE:-pagamentos-demo}"
ROX_CLUSTER="${ROX_CLUSTER:-$(oc get securedclusters.platform.stackrox.io -A \
  -o jsonpath='{.items[0].spec.clusterName}' 2>/dev/null)}"
if [[ -z "$ROX_CLUSTER" ]]; then
  echo "ERRO: defina ROX_CLUSTER (nome do cluster em Platform Configuration > Clusters)" >&2; exit 2
fi

if ! command -v roxctl >/dev/null; then
  echo ">> baixando roxctl do Central"
  if [[ -n "${ROX_API_TOKEN:-}" ]]; then auth=(-H "Authorization: Bearer $ROX_API_TOKEN")
  else auth=(-u "admin:$ROX_ADMIN_PASSWORD"); fi
  curl -fsSk "${auth[@]}" "https://$ROX_ENDPOINT/api/cli/download/roxctl-linux" -o ./roxctl \
    || { echo "ERRO: não foi possível baixar o roxctl do Central" >&2; exit 2; }
  chmod +x ./roxctl; PATH="$PWD:$PATH"
fi
rox() { roxctl --insecure-skip-tls-verify "$@"; }

echo ">> Imagem: $IMAGE"
echo ">> Contexto: cluster '$ROX_CLUSTER', namespace '$ROX_NAMESPACE'"

saida=$(mktemp); erro=$(mktemp); trap 'rm -f "$saida" "$erro"' EXIT

# Scan delegado ao Secured Cluster (--cluster): é ele que alcança o registry.
# Sem a delegação, o Central pode devolver a imagem com 0 componentes.
echo; echo ">> CVEs Críticas e Importantes com correção disponível (informativo)"
if rox image scan --image "$IMAGE" --cluster "$ROX_CLUSTER" --namespace "$ROX_NAMESPACE" \
     --output json >"$saida" 2>/dev/null && jq -e '.result' "$saida" >/dev/null 2>&1; then
  jq -r '.result.summary | "   Componentes vulneráveis: \(."TOTAL-COMPONENTS")  CVEs: \(."TOTAL-VULNERABILITIES")  (Críticas \(.CRITICAL) · Importantes \(.IMPORTANT) · Moderadas \(.MODERATE) · Baixas \(.LOW))"' "$saida"
  jq -r '[.result.vulnerabilities[]? | select(.cveSeverity=="CRITICAL" or .cveSeverity=="IMPORTANT")
          | select((.componentFixedVersion // "") != "")] | unique_by(.cveId)
         | "   Corrigíveis (Críticas + Importantes): \(length)  — amostra:",
           (sort_by(.cveSeverity) | .[:8][] | "     \(.cveId)  \(.cveSeverity)  \(.componentName) \(.componentVersion) -> \(.componentFixedVersion)")' "$saida"
else
  echo "   (scan indisponível; o gate abaixo decide de qualquer forma)"
fi

echo; echo ">> Gate de política (o que o pipeline decide)"
rox image check --image "$IMAGE" --cluster "$ROX_CLUSTER" --namespace "$ROX_NAMESPACE" \
  --output json >"$saida" 2>"$erro"

# A decisão vem do conteúdo, não do exit code: o roxctl também sai com 1 em erro
# de conexão, autenticação ou namespace inexistente — e isso não é "barrada".
if ! jq -e '.results' "$saida" >/dev/null 2>&1; then
  echo "RESULTADO: ERRO — o check não foi executado (não conta como barrada)."
  grep -v '^\s*$' "$erro" | tail -3
  exit 2
fi

printf '%-6s  %-9s  %s\n' BLOQ. SEVERID. POLÍTICA
jq -r '.results[].violatedPolicies[]? | [(if .failingCheck then "SIM" else "-" end), .severity, .name] | @tsv' "$saida" \
  | sort -r | awk -F'\t' '{printf "%-6s  %-9s  %s\n", $1, $2, $3}'

bloqueantes=$(jq '[.results[].violatedPolicies[]? | select(.failingCheck)] | length' "$saida")
alertas=$(jq '[.results[].violatedPolicies[]? | select(.failingCheck | not)] | length' "$saida")
echo
if (( bloqueantes > 0 )); then
  echo "RESULTADO: BARRADA no build — $bloqueantes política(s) com enforcement violada(s), $alertas só alerta."
  echo "           Conta para RSK-03 e RSK-04."
  exit 1
fi
echo "RESULTADO: APROVADA — nenhuma política com enforcement violada ($alertas só alerta). O build segue."
exit 0
