#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Jornada de Fundação · Segurança — coleta dos 8 KPIs direto das ferramentas
#
#  Fecha a demo: os números que o time de segurança acabou de ver na tela
#  saem do ACS Central e do ACM Governance, sem planilha no meio.
#
#  Requisitos: curl, jq e oc com acesso ao HUB (ACM) — que neste ambiente é
#  também o cluster do Central (SecurityPolicy em ACS_NS, para o EST-03).
#
#    export ROX_ENDPOINT=central-rhacs-operator.apps.<hub>:443
#    export ROX_API_TOKEN=<token>      # papel Analyst (ou Admin) — ver abaixo
#    ./coletar-kpis.sh                 # tabela
#    ./coletar-kpis.sh --csv > kpis-$(date +%F).csv
#
#  AUTENTICAÇÃO NO CENTRAL (uma das duas):
#    ROX_API_TOKEN       token criado em Platform Configuration > Integrations >
#                        API Token, com papel **Analyst** (leitura de tudo).
#                        O papel "Continuous Integration" só lê imagens: alertas,
#                        clusters e políticas voltam 403.
#                        Token do OpenShift (oc whoami -t, sha256~...) NÃO serve:
#                        o Central só o aceita se houver auth provider OpenShift.
#    ROX_ADMIN_PASSWORD  senha do usuário admin (laboratório).
#
#  Variáveis opcionais:
#    OC_CONTEXT=<contexto>     contexto do kubeconfig do hub (padrão: o atual)
#    JANELA_DIAS=30            janela para violações e remediação
#    ACS_NS=rhacs-operator     namespace do Central, onde ficam as SecurityPolicy
#    NS_PROD='pagamentos-demo' regex dos namespaces considerados "produção" (RSK-05)
#    EXCLUIR_NS='<regex>'      namespaces de plataforma fora da conta (padrão: openshift-*,
#                              kube-*, ACM/MCE, hive, hypershift, stackrox, rhacs-operator).
#                              EXCLUIR_NS='' conta tudo.
#    BUILD_BLOQUEADOS=0        builds reprovados pelo roxctl no período (vem do CI)
#    BUILD_VIOLACOES=0         violações de build no período (vem do CI)
#
#  Por que os de build vêm de fora: o roxctl image check avalia no Central,
#  mas o resultado não vira violação persistida — ele fica no log do pipeline.
# ---------------------------------------------------------------------------
set -uo pipefail

: "${ROX_ENDPOINT:?defina ROX_ENDPOINT}"
ROX_ENDPOINT="${ROX_ENDPOINT#https://}"
if [[ -n "${ROX_API_TOKEN:-}" ]]; then
  [[ "$ROX_API_TOKEN" == sha256~* ]] && {
    echo "ERRO: ROX_API_TOKEN é um token do OpenShift (sha256~...). Use um API Token do ACS" \
         "com papel Analyst ou ROX_ADMIN_PASSWORD." >&2; exit 2; }
  AUTH=(-H "Authorization: Bearer $ROX_API_TOKEN")
elif [[ -n "${ROX_ADMIN_PASSWORD:-}" ]]; then
  AUTH=(-u "admin:$ROX_ADMIN_PASSWORD")
else
  echo "ERRO: defina ROX_API_TOKEN (papel Analyst) ou ROX_ADMIN_PASSWORD" >&2; exit 2
fi
JANELA_DIAS="${JANELA_DIAS:-30}"
NS_PROD="${NS_PROD:-pagamentos-demo}"
ACS_NS="${ACS_NS:-rhacs-operator}"
BUILD_BLOQUEADOS="${BUILD_BLOQUEADOS:-0}"
EXCLUIR_NS="${EXCLUIR_NS-^(openshift|kube|open-cluster-management|multicluster-engine|hive|hypershift|stackrox|rhacs-operator|redhat|default$)}"
BUILD_VIOLACOES="${BUILD_VIOLACOES:-0}"
POLICY_DIR="$(cd "$(dirname "$0")/../acs/policies" && pwd)"
CSV=false; [[ "${1:-}" == "--csv" ]] && CSV=true

DESDE=$(date -u -d "-${JANELA_DIAS} days" +%Y-%m-%dT%H:%M:%SZ)

# rox <path> [query]  — GET no Central; em erro HTTP avisa no stderr e retorna 1.
# A query vai num único argumento: tem espaço ("Violation State:...") e, sem
# aspas, o curl recebia o pedaço depois do espaço como se fosse uma URL.
rox() {
  local args=(-sk -G "${AUTH[@]}" -o "$TMP" -w '%{http_code}') codigo
  [[ -n "${2:-}" ]] && args+=(--data-urlencode "query=$2")
  [[ "$1" != */v1/*/* ]] && args+=(--data-urlencode "pagination.limit=${LIMITE:-5000}")
  codigo=$(curl "${args[@]}" "https://$ROX_ENDPOINT$1") || codigo=000
  if [[ "$codigo" != 200 ]]; then
    echo "AVISO: GET $1 -> HTTP $codigo $(head -c 160 "$TMP" 2>/dev/null)" >&2
    return 1
  fi
  cat "$TMP"
}
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT

oc() { command oc ${OC_CONTEXT:+--context="$OC_CONTEXT"} "$@"; }
pct() { [[ "$2" -gt 0 ]] && awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1f%%", 100*a/b}' || echo "n/d"; }

declare -a LINHAS
linha() { LINHAS+=("$1|$2|$3|$4"); }   # id | nome | valor | detalhe

# ── Pré-checagens: falham cedo, com a causa provável ─────────────────────────
codigo=$(curl -sk -o /dev/null -w '%{http_code}' "${AUTH[@]}" "https://$ROX_ENDPOINT/v1/alerts?pagination.limit=1") || codigo=000
case "$codigo" in
  200) ;;
  000) echo "ERRO: Central inacessível em https://$ROX_ENDPOINT" >&2; exit 2 ;;
  401) echo "ERRO: credencial recusada pelo Central (HTTP 401): token expirado/revogado ou senha errada." >&2; exit 2 ;;
  403) echo "ERRO: credencial sem permissão de leitura de violações (HTTP 403)." \
            "Use um API Token com papel Analyst (o papel Continuous Integration não basta)." >&2; exit 2 ;;
  *)   echo "ERRO: Central respondeu HTTP $codigo em /v1/alerts" >&2; exit 2 ;;
esac
HUB_OK=true
if ! oc api-resources --api-group=cluster.open-cluster-management.io -o name 2>/dev/null | grep -q '^managedclusters'; then
  HUB_OK=false
  echo "AVISO: o oc atual ($(oc whoami --show-server 2>/dev/null || echo 'sem login')) não é o hub ACM." \
       "RSK-01, RSK-02 e EST-03 sairão n/d. Use OC_CONTEXT=<contexto do hub>." >&2
fi

# Violações da janela (todas as fases e estados) — base de RSK-03/04/06/09
ALERTAS=$(rox /v1/alerts "Violation State:ACTIVE,ATTEMPTED,RESOLVED" \
  | jq --arg d "$DESDE" --arg x "$EXCLUIR_NS" '[(.alerts // [])[] | select(.time >= $d)
      | select($x == "" or ((.commonEntityInfo.namespace // "") | test($x) | not))]') || ALERTAS='[]'

# ── RSK-02 · Cobertura de segurança ───────────────────────────────────────
kpi_rsk02() {
  local acs gerenciados
  acs=$(rox /v1/clusters | jq '[(.clusters // [])[] | select(.healthStatus.overallHealthStatus=="HEALTHY")] | length') || acs=""
  gerenciados=""
  $HUB_OK && { gerenciados=$(oc get managedclusters -o json 2>/dev/null | jq '.items | length') || gerenciados=""; }
  if [[ -n "$acs" && -n "$gerenciados" ]]; then
    linha RSK-02 "Cobertura de segurança" "$(pct "$acs" "$gerenciados")" "$acs Secured Clusters saudáveis / $gerenciados ManagedClusters"
  else
    linha RSK-02 "Cobertura de segurança" "n/d" "sem acesso ao ACS ou ao hub ACM (oc)"
  fi
}

# ── RSK-03 · Deploys inseguros barrados ───────────────────────────────────
kpi_rsk03() {
  local deploy
  # Só o que foi de fato recusado (ATTEMPTED). Alertas com enforcement apenas
  # registrado (ex.: SCALE_TO_ZERO em deploy do Argo CD de openshift-gitops, que o
  # admission não bloqueia) não contam como barrados.
  deploy=$(jq '[.[] | select(.lifecycleStage=="DEPLOY" and .state=="ATTEMPTED")] | length' <<<"$ALERTAS")
  linha RSK-03 "Deploys inseguros barrados" "$((deploy + BUILD_BLOQUEADOS))" \
    "$BUILD_BLOQUEADOS no build (CI) + $deploy recusados no admission, ${JANELA_DIAS}d"
}

# ── RSK-04 · Shift-left de segurança ──────────────────────────────────────
kpi_rsk04() {
  local deploy runtime total
  deploy=$(jq '[.[] | select(.lifecycleStage=="DEPLOY")] | length' <<<"$ALERTAS")
  runtime=$(jq '[.[] | select(.lifecycleStage=="RUNTIME")] | length' <<<"$ALERTAS")
  total=$((BUILD_VIOLACOES + deploy + runtime))
  linha RSK-04 "Shift-left de segurança" "$(pct $((BUILD_VIOLACOES + deploy)) "$total")" \
    "build $BUILD_VIOLACOES + deploy $deploy de $total violações (runtime $runtime), ns de aplicação"
}

# ── RSK-05 · CVEs críticas/importantes corrigíveis em produção ────────────
kpi_rsk05() {
  local ids cves="" id n
  ids=$(rox /v1/images "Namespace:r/${NS_PROD}" | jq -r '(.images // [])[].id') || ids=""
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
  if $HUB_OK && j=$(oc get policies.policy.open-cluster-management.io -A \
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
  local f nome commit aplicada segs=() cr
  for f in "$POLICY_DIR"/*.yaml; do
    nome=$(awk '/^  name:/{print $2; exit}' "$f")
    commit=$(git -C "$POLICY_DIR" log -1 --format=%ct -- "$f" 2>/dev/null)
    # managedFields só vem com --show-managed-fields (o oc oculta por padrão)
    cr=$(oc -n "$ACS_NS" get securitypolicy "$nome" -o json --show-managed-fields 2>/dev/null) || continue
    # ACS >= 4.8 reporta o aceite em conditions; versões anteriores em .status.accepted
    [[ "$(jq -r '(.status.accepted // false) or any(.status.conditions[]?; .type=="AcceptedByCentral" and .status=="True")' <<<"$cr")" == "true" && -n "$commit" ]] || continue
    # Marco "aceita": condition AcceptedByCentral (ACS >= 4.8); senão, a última
    # escrita no objeto (managedFields).
    aplicada=$(jq -r '([.status.conditions[]? | select(.type=="AcceptedByCentral") | .lastTransitionTime]
                       + [.metadata.managedFields[]?.time // empty]) | first // empty
                      | sub("\\.[0-9]+";"") | fromdateiso8601' <<<"$cr")
    [[ -n "$aplicada" ]] || continue
    (( aplicada >= commit )) && segs+=("$(( aplicada - commit ))")
  done
  if [[ ${#segs[@]} -gt 0 ]]; then
    linha EST-03 "Tempo para adotar um novo padrão" \
      "$(printf '%s\n' "${segs[@]}" | awk '{s+=$1} END{m=s/NR; if (m<120) printf "%.0f s", m; else if (m<7200) printf "%.0f min", m/60; else printf "%.1f h", m/3600}')" \
      "commit → aceita no Central, média de ${#segs[@]} SecurityPolicies"
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
