#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Jornada de Fundação · Segurança — coleta dos 8 KPIs direto das ferramentas
#
#  Fecha a demo: os números que o time de segurança acabou de ver na tela
#  saem do ACS Central e do ACM Governance, sem planilha no meio.
#
#  Requisitos: curl, jq, oc logado no HUB (ACM) e, para EST-03, no cluster
#  do Central com acesso ao namespace stackrox.
#
#    export ROX_ENDPOINT=central-stackrox.apps.<hub>:443
#    export ROX_API_TOKEN=<token somente leitura>
#    ./coletar-kpis.sh                 # tabela
#    ./coletar-kpis.sh --csv > kpis-$(date +%F).csv
#
#  Variáveis opcionais:
#    JANELA_DIAS=30            janela para violações e remediação
#    NS_PROD='pagamentos-demo' regex dos namespaces considerados "produção" (RSK-05)
#    BUILD_BLOQUEADOS=0        builds reprovados pelo roxctl no período (vem do CI)
#    BUILD_VIOLACOES=0         violações de build no período (vem do CI)
#
#  Por que os de build vêm de fora: o roxctl image check avalia no Central,
#  mas o resultado não vira violação persistida — ele fica no log do pipeline.
# ---------------------------------------------------------------------------
set -uo pipefail

: "${ROX_ENDPOINT:?defina ROX_ENDPOINT}" "${ROX_API_TOKEN:?defina ROX_API_TOKEN}"
JANELA_DIAS="${JANELA_DIAS:-30}"
NS_PROD="${NS_PROD:-pagamentos-demo}"
BUILD_BLOQUEADOS="${BUILD_BLOQUEADOS:-0}"
BUILD_VIOLACOES="${BUILD_VIOLACOES:-0}"
POLICY_DIR="$(cd "$(dirname "$0")/../acs/policies" && pwd)"
CSV=false; [[ "${1:-}" == "--csv" ]] && CSV=true

DESDE=$(date -u -d "-${JANELA_DIAS} days" +%Y-%m-%dT%H:%M:%SZ)

rox() {  # rox <path> [query]
  local q=""; [[ -n "${2:-}" ]] && q="--data-urlencode query=$2"
  curl -fsSk -G -H "Authorization: Bearer $ROX_API_TOKEN" $q \
    --data-urlencode "pagination.limit=${LIMITE:-5000}" "https://$ROX_ENDPOINT$1"
}
pct() { [[ "$2" -gt 0 ]] && awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1f%%", 100*a/b}' || echo "n/d"; }

declare -a LINHAS
linha() { LINHAS+=("$1|$2|$3|$4"); }   # id | nome | valor | detalhe

# Violações da janela (todas as fases e estados) — base de RSK-03/04/06/09
ALERTAS=$(rox /v1/alerts "Violation State:ACTIVE,ATTEMPTED,RESOLVED" \
  | jq --arg d "$DESDE" '[.alerts[] | select(.time >= $d)]') || ALERTAS='[]'

# ── RSK-02 · Cobertura de segurança ───────────────────────────────────────
kpi_rsk02() {
  local acs gerenciados
  acs=$(rox /v1/clusters | jq '[.clusters[] | select(.healthStatus.overallHealthStatus=="HEALTHY")] | length') || acs=""
  gerenciados=$(oc get managedclusters -o json 2>/dev/null | jq '.items | length') || gerenciados=""
  if [[ -n "$acs" && -n "$gerenciados" ]]; then
    linha RSK-02 "Cobertura de segurança" "$(pct "$acs" "$gerenciados")" "$acs Secured Clusters saudáveis / $gerenciados ManagedClusters"
  else
    linha RSK-02 "Cobertura de segurança" "n/d" "sem acesso ao ACS ou ao hub ACM (oc)"
  fi
}

# ── RSK-03 · Deploys inseguros barrados ───────────────────────────────────
kpi_rsk03() {
  local deploy
  deploy=$(jq '[.[] | select(.lifecycleStage=="DEPLOY" and (.state=="ATTEMPTED" or (.enforcementCount // 0) > 0))] | length' <<<"$ALERTAS")
  linha RSK-03 "Deploys inseguros barrados" "$((deploy + BUILD_BLOQUEADOS))" \
    "$BUILD_BLOQUEADOS no build (CI) + $deploy no deploy (admission/scale-to-zero), ${JANELA_DIAS}d"
}

# ── RSK-04 · Shift-left de segurança ──────────────────────────────────────
kpi_rsk04() {
  local deploy runtime total
  deploy=$(jq '[.[] | select(.lifecycleStage=="DEPLOY")] | length' <<<"$ALERTAS")
  runtime=$(jq '[.[] | select(.lifecycleStage=="RUNTIME")] | length' <<<"$ALERTAS")
  total=$((BUILD_VIOLACOES + deploy + runtime))
  linha RSK-04 "Shift-left de segurança" "$(pct $((BUILD_VIOLACOES + deploy)) "$total")" \
    "build $BUILD_VIOLACOES + deploy $deploy de $total violações (runtime $runtime)"
}

# ── RSK-05 · CVEs críticas/importantes corrigíveis em produção ────────────
kpi_rsk05() {
  local ids cves="" id n
  ids=$(rox /v1/images "Namespace:r/${NS_PROD}" | jq -r '.images[].id') || ids=""
  for id in $ids; do
    cves+=$(rox "/v1/images/$id" | jq -r '
      .scan.components[]?.vulns[]?
      | select((.severity=="CRITICAL_VULNERABILITY_SEVERITY" or .severity=="IMPORTANT_VULNERABILITY_SEVERITY")
               and (.fixedBy // "") != "")
      | .cve')$'\n'
  done
  n=$(grep -v '^$' <<<"$cves" | sort -u | wc -l)
  linha RSK-05 "CVEs críticas corrigíveis em produção" "$n" \
    "CVEs únicas com correção em $(wc -w <<<"$ids") imagens de ns ~ /$NS_PROD/"
}

# ── RSK-06 · Tempo para remediar CVE crítica ──────────────────────────────
#  Proxy: tempo de vida das violações de política de CVE corrigível que foram
#  RESOLVIDAS na janela (detecção → deploy da imagem corrigida).
kpi_rsk06() {
  local ids id dias=()
  ids=$(jq -r '.[] | select(.state=="RESOLVED") | select(.policy.name | test("CVE|Fixable"; "i")) | .id' <<<"$ALERTAS")
  for id in $ids; do
    dias+=("$(rox "/v1/alerts/$id" | jq -r '
      ((.resolvedAt // .time) | sub("\\.[0-9]+";"") | fromdateiso8601) as $f
      | ((.firstOccurred // .time) | sub("\\.[0-9]+";"") | fromdateiso8601) as $i
      | ($f - $i) / 86400')")
  done
  if [[ ${#dias[@]} -gt 0 ]]; then
    linha RSK-06 "Tempo para remediar CVE crítica" \
      "$(printf '%s\n' "${dias[@]}" | awk '{s+=$1} END{printf "%.1f dias", s/NR}')" \
      "média de ${#dias[@]} violações de CVE corrigível resolvidas em ${JANELA_DIAS}d"
  else
    linha RSK-06 "Tempo para remediar CVE crítica" "n/d" "nenhuma violação de CVE resolvida na janela"
  fi
}

# ── RSK-09 · Mudanças fora do Git ─────────────────────────────────────────
kpi_rsk09() {
  local n
  n=$(jq '[.[] | select(.lifecycleStage=="RUNTIME")
               | select((.policy.categories // [] | index("Kubernetes Events"))
                        or (.policy.name | test("exec|port.?forward|Secret"; "i")))] | length' <<<"$ALERTAS")
  linha RSK-09 "Mudanças fora do Git" "$n" "exec, port-forward e acesso a Secret em runtime, ${JANELA_DIAS}d"
}

# ── RSK-01 · Conformidade da frota ────────────────────────────────────────
#  Cluster conforme = nenhuma política replicada NonCompliant no hub ACM.
kpi_rsk01() {
  local j total ok
  if j=$(oc get policies.policy.open-cluster-management.io -A \
           -l policy.open-cluster-management.io/cluster-name -o json 2>/dev/null); then
    total=$(jq '[.items[].metadata.labels["policy.open-cluster-management.io/cluster-name"]] | unique | length' <<<"$j")
    ok=$(jq '[.items | group_by(.metadata.labels["policy.open-cluster-management.io/cluster-name"])[]
              | select(all(.[]; .status.compliant=="Compliant"))] | length' <<<"$j")
    linha RSK-01 "Conformidade da frota" "$(pct "$ok" "$total")" "$ok de $total clusters sem violação (ACM Governance)"
  else
    linha RSK-01 "Conformidade da frota" "n/d" "sem acesso ao hub ACM (oc)"
  fi
}

# ── EST-03 · Tempo para adotar um novo padrão ─────────────────────────────
#  Commit da SecurityPolicy no Git → política aceita no Central (status do CR).
kpi_est03() {
  local f nome commit aplicada mins=() cr
  for f in "$POLICY_DIR"/*.yaml; do
    nome=$(awk '/^  name:/{print $2; exit}' "$f")
    commit=$(git -C "$POLICY_DIR" log -1 --format=%ct -- "$f" 2>/dev/null)
    cr=$(oc -n stackrox get securitypolicy "$nome" -o json 2>/dev/null) || continue
    [[ "$(jq -r '.status.accepted // false' <<<"$cr")" == "true" && -n "$commit" ]] || continue
    aplicada=$(jq -r '[.metadata.managedFields[].time] | max | fromdateiso8601' <<<"$cr")
    (( aplicada >= commit )) && mins+=("$(( (aplicada - commit) / 60 ))")
  done
  if [[ ${#mins[@]} -gt 0 ]]; then
    linha EST-03 "Tempo para adotar um novo padrão" \
      "$(printf '%s\n' "${mins[@]}" | awk '{s+=$1} END{printf "%.0f min", s/NR}')" \
      "commit → aceita no Central, média de ${#mins[@]} SecurityPolicies"
  else
    linha EST-03 "Tempo para adotar um novo padrão" "n/d" "nenhuma SecurityPolicy do Git aceita no Central"
  fi
}

kpi_rsk02; kpi_rsk03; kpi_rsk04; kpi_rsk05; kpi_rsk06; kpi_rsk09; kpi_rsk01; kpi_est03

if $CSV; then
  echo "data,kpi,nome,valor,detalhe"
  for l in "${LINHAS[@]}"; do IFS='|' read -r a b c d <<<"$l"; echo "$(date +%F),$a,\"$b\",\"$c\",\"$d\""; done
else
  printf '\nJornada de Fundação · Segurança — %s (janela %sd)\n\n' "$(date '+%d/%m/%Y %H:%M')" "$JANELA_DIAS"
  printf '%-7s %-40s %-12s %s\n' KPI Nome Valor Detalhe
  printf '%-7s %-40s %-12s %s\n' ------- ---------------------------------------- ------------ -------
  for l in "${LINHAS[@]}"; do   # padding por caractere, não por byte (acentos)
    IFS='|' read -r a b c d <<<"$l"
    printf '%-7s %s%*s %-12s %s\n' "$a" "$b" $((40 - ${#b})) '' "$c" "$d"
  done
  echo
fi
