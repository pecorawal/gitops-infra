#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  As 4 métricas DORA da demo, extraídas ao vivo (sem planilha):
#
#    1. Frequência de deploy      entradas no histórico do Argo CD (DEV e PROD)
#    2. Lead time de mudança      commit de código  →  deploy em DEV (deployedAt)
#    3. Taxa de falha da esteira  PipelineRuns com falha ÷ total
#    4. Tempo de recuperação      falha de pipeline → próximo sucesso
#
#    ./devops/kpis/coletar-kpis.sh            # tabela
#    ./devops/kpis/coletar-kpis.sh --csv      # para comparar antes/depois
#
#  Fonte: hub (Applications e PipelineRuns) + git log local (data do commit
#  de origem, gravada pela task update-gitops como "origem: <sha>").
#  Requer: oc, jq, git. Rodar da raiz do repositório.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../config.env
source devops/config.env
hub() { command oc --context="$HUB_CTX" "$@"; }
git fetch -q origin devops || true

epoch() { date -d "$1" +%s; }
fmt()   { local s=${1%.*}; printf '%dm%02ds' $((s/60)) $((s%60)); }

historico() {  # $1 = app → linhas "deployedAt revision"
  hub -n openshift-gitops get applications.argoproj.io "$1" -o json 2>/dev/null \
    | jq -r '.status.history[]? | "\(.deployedAt) \(.revision)"'
}

DEV="pagamentos-dev-$CLUSTER_GERENCIADO"; PROD="pagamentos-prod-$CLUSTER_GERENCIADO"
deploys_dev=$(historico "$DEV" | grep -c . || true)
deploys_prod=$(historico "$PROD" | grep -c . || true)

# Lead time: para cada deploy em DEV, acha o commit de origem no corpo do commit GitOps
soma=0; n=0
while read -r quando rev; do
  [[ -z "$rev" ]] && continue
  origem=$(git log -1 --format=%b "$rev" 2>/dev/null | sed -n 's/^origem: //p')
  [[ -z "$origem" ]] && continue
  t0=$(git log -1 --format=%ct "$origem" 2>/dev/null) || continue
  soma=$(( soma + $(epoch "$quando") - t0 )); n=$((n+1))
done < <(historico "$DEV")
lead=$([[ $n -gt 0 ]] && fmt $((soma/n)) || echo "n/d")

# PipelineRuns: status final e horários
runs=$(hub -n devops-ci get pipelinerun -o json 2>/dev/null | jq -r '
  .items | sort_by(.metadata.creationTimestamp)[]
  | select(.status.completionTime != null)
  | "\(.status.conditions[0].status) \(.metadata.creationTimestamp) \(.status.completionTime)"')
total=$(grep -c . <<<"$runs" || true); falhas=$(grep -c '^False' <<<"$runs" || true)
taxa=$([[ $total -gt 0 ]] && echo "$(( 100*falhas/total ))%" || echo "n/d")

# Recuperação: da primeira falha de uma sequência até o próximo sucesso
rec_soma=0; rec_n=0; inicio_falha=""
while read -r ok criado fim; do
  [[ -z "$ok" ]] && continue
  if [[ $ok == False && -z "$inicio_falha" ]]; then inicio_falha=$criado
  elif [[ $ok == True && -n "$inicio_falha" ]]; then
    rec_soma=$(( rec_soma + $(epoch "$fim") - $(epoch "$inicio_falha") )); rec_n=$((rec_n+1)); inicio_falha=""
  fi
done <<<"$runs"
rec=$([[ $rec_n -gt 0 ]] && fmt $((rec_soma/rec_n)) || echo "n/d")

if [[ "${1:-}" == "--csv" ]]; then
  echo "metrica,valor"
  echo "deploys_dev,$deploys_dev"; echo "deploys_prod,$deploys_prod"
  echo "lead_time_medio,$lead"; echo "taxa_falha_esteira,$taxa"; echo "tempo_recuperacao,$rec"
else
  printf '\n\033[1mMétricas DORA · demo DevOps\033[0m\n'
  printf '  %-34s %s\n' "Frecuencia de despliegue (DEV)"  "$deploys_dev" \
                        "Frecuencia de despliegue (PROD)" "$deploys_prod" \
                        "Lead time commit → DEV (medio)"  "$lead ($n deploys)" \
                        "Tasa de fallo de la esteira"     "$taxa ($falhas/$total)" \
                        "Tiempo de recuperación (medio)"  "$rec"
fi
