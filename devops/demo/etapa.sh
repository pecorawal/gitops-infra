#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Demo DevOps · "do commit ao deploy no cluster gerenciado"
#
#  O apresentador faz o papel do desenvolvedor: cada etapa troca devops/app/lib.js,
#  faz commit + push e acompanha a esteira (webhook → Tekton no hub → Quay no
#  cluster 2 → commit da tag → Argo CD → cluster 2).
#
#    ./devops/demo/etapa.sh 00         versão 1.0 (azul)   — estado de partida
#    ./devops/demo/etapa.sh 01         versão 1.1 (verde)  — nova versão em DEV
#    ./devops/demo/etapa.sh 02         versão "v1.2"       — teste falha, nada é implantado
#    ./devops/demo/etapa.sh 03         versão 1.2 (vermelho) — correção, volta a fluir
#    ./devops/demo/etapa.sh promover   copia a tag de DEV para PROD (depois: Sync no Argo CD)
#    ./devops/demo/etapa.sh drift      escala DEV à mão no cluster 2; o Argo CD desfaz
#    ./devops/demo/etapa.sh rollback   git revert da última promoção (depois: Sync)
#    ./devops/demo/etapa.sh status     o que está no Git, no Argo CD e no cluster 2
#
#  --dry-run (em qualquer posição): mostra o que faria, sem commit/push nem oc.
#  Requisitos: clone da branch devops com push; contextos do oc em devops/config.env.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../config.env
source devops/config.env

DRY=0; ARGS=()
for a in "$@"; do [[ "$a" == "--dry-run" ]] && DRY=1 || ARGS+=("$a"); done
set -- "${ARGS[@]:-}"

APP_LIB=devops/app/lib.js
ETAPAS=devops/demo/etapas
DEV_VALUES=devops/gitops/values-dev.yaml
PROD_VALUES=devops/gitops/values-prod.yaml
APP_DEV="pagamentos-dev-$CLUSTER_GERENCIADO"
APP_PROD="pagamentos-prod-$CLUSTER_GERENCIADO"

titulo()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
mostrar() { printf '\n\033[1;36mMostrar:\033[0m %s\n' "$*"; }
run()     { if (( DRY )); then echo "  [dry-run] $*"; else "$@"; fi; }
hub()     { command oc --context="$HUB_CTX" "$@"; }
ger()     { command oc --context="$GER_CTX" "$@"; }
tag_de()  { sed -nE 's/^\s*tag:\s*"?([^"]*)"?/\1/p' "$1"; }

commit_push() {   # $1 = mensagem; demais = arquivos
  local msg=$1; shift
  run git add "$@"
  if git diff --cached --quiet && (( ! DRY )); then echo "  nada mudou no Git"; return 1; fi
  run git commit -q -m "$msg"
  run git pull -q --rebase origin devops
  run git push -q origin HEAD:devops
  echo "  commit: $msg"
}

refresh() {   # força o Argo CD a ler o Git agora (sem esperar o polling de 3 min)
  run hub -n openshift-gitops annotate applications.argoproj.io "$1" \
    argocd.argoproj.io/refresh=hard --overwrite >/dev/null
}

acompanhar_pipeline() {
  (( DRY )) && { echo "  [dry-run] tkn pipelinerun logs -f --last"; return; }
  echo "  aguardando o webhook disparar a pipeline..."
  local antes; antes=$(hub -n devops-ci get pipelinerun -o name 2>/dev/null | wc -l)
  for _ in $(seq 1 30); do
    (( $(hub -n devops-ci get pipelinerun -o name 2>/dev/null | wc -l) > antes )) && break
    sleep 2
  done
  tkn --context "$HUB_CTX" -n devops-ci pipelinerun logs -f --last || true
  hub -n devops-ci get pipelinerun --sort-by=.metadata.creationTimestamp | tail -1
}

etapa_app() {   # $1 = número da etapa
  local n=$1 desc
  case $n in
    00) desc="versão 1.0 (azul) — estado de partida" ;;
    01) desc="versão 1.1 (verde) — nova funcionalidade" ;;
    02) desc="versão 'v1.2' — erro de digitação que o teste pega" ;;
    03) desc="versão 1.2 (vermelho) — correção" ;;
    *) echo "etapa desconhecida: $n" >&2; exit 1 ;;
  esac
  titulo "Etapa $n · $desc"
  git --no-pager diff --no-index --color "$APP_LIB" "$ETAPAS/$n-lib.js" || true
  run cp "$ETAPAS/$n-lib.js" "$APP_LIB"
  commit_push "demo(etapa $n): $desc" "$APP_LIB" || return 0
  acompanhar_pipeline
  if [[ $n == 02 ]]; then
    mostrar "Pipelines › devops-ci: unit-tests VERMELHO, build/update-gitops não rodaram.
         Argo CD continua Synced na tag anterior; a página no cluster 2 não mudou."
    return
  fi
  refresh "$APP_DEV"
  mostrar "GitHub: commit 'ci(dev): pagamentos-api <tag>' feito pela pipeline.
         Quay (cluster 2): nova tag em $QUAY_ORG/pagamentos-api.
         Argo CD: $APP_DEV Synced na nova revisão.
         Página: https://$(route_dev)"
}

route_dev() { (( DRY )) && echo "<rota>" || ger -n pagamentos-dev get route pagamentos-api -o jsonpath='{.spec.host}' 2>/dev/null || echo "<rota>"; }

promover() {
  local tag; tag=$(tag_de "$DEV_VALUES")
  titulo "Promoção · tag $tag de DEV para PROD (mesma imagem, sem novo build)"
  run sed -i -E "s|^(\s*tag:).*|\1 \"$tag\"|" "$PROD_VALUES"
  commit_push "promo(prod): pagamentos-api $tag" "$PROD_VALUES" || return 0
  refresh "$APP_PROD"
  mostrar "Argo CD: $APP_PROD fica OutOfSync — o diff mostra só a troca da tag.
         Clique Sync (é a aprovação do go-live). Ou: $0 sync-prod"
}

sync_prod() {
  titulo "Sync de PROD"
  run hub -n openshift-gitops patch applications.argoproj.io "$APP_PROD" --type merge \
    -p '{"operation":{"initiatedBy":{"username":"etapa.sh"},"sync":{"revision":"devops"}}}'
}

drift() {
  titulo "Drift · alguém escala DEV à mão no cluster 2"
  run ger -n pagamentos-dev scale deploy/pagamentos-api --replicas=5
  (( DRY )) || { sleep 3; ger -n pagamentos-dev get deploy pagamentos-api; }
  mostrar "Argo CD: $APP_DEV fica OutOfSync por alguns segundos e o selfHeal volta para 1 réplica.
         O Git é a fonte da verdade; o cluster converge sozinho."
}

rollback() {
  local c; c=$(git log -1 --format=%h --grep='^promo(prod):' -- "$PROD_VALUES")
  [[ -z "$c" ]] && { echo "nenhuma promoção para reverter" >&2; exit 1; }
  titulo "Rollback · git revert $c ($(git log -1 --format=%s "$c"))"
  run git revert --no-edit "$c"
  run git push -q origin HEAD:devops
  refresh "$APP_PROD"
  mostrar "Argo CD: $APP_PROD OutOfSync para a tag anterior → Sync. Rollback = um commit auditável."
}

status() {
  titulo "Git"
  echo "  dev : $(tag_de "$DEV_VALUES")"; echo "  prod: $(tag_de "$PROD_VALUES")"
  (( DRY )) && return
  titulo "Argo CD (hub)"
  for a in "$APP_DEV" "$APP_PROD"; do
    hub -n openshift-gitops get applications.argoproj.io "$a" \
      -o jsonpath="  $a: sync={.status.sync.status} saúde={.status.health.status}{'\n'}" 2>/dev/null || echo "  $a: não encontrada"
  done
  titulo "Pipelines (hub, últimas 3)"
  hub -n devops-ci get pipelinerun --sort-by=.metadata.creationTimestamp 2>/dev/null | tail -3
  titulo "Cluster gerenciado"
  for ns in pagamentos-dev pagamentos-prod; do
    ger -n "$ns" get deploy pagamentos-api \
      -o jsonpath="  $ns: {.spec.template.spec.containers[0].image} réplicas={.status.readyReplicas}/{.spec.replicas}{'\n'}" 2>/dev/null || echo "  $ns: sem deploy"
  done
}

case "${1:-}" in
  00|01|02|03) etapa_app "$1" ;;
  promover)    promover ;;
  sync-prod)   sync_prod ;;
  drift)       drift ;;
  rollback)    rollback ;;
  status)      status ;;
  *) sed -n '3,22p' "$0"; exit 1 ;;
esac
