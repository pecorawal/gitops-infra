#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Preparação da demo DevOps (D-1). Rodar a partir da raiz do repositório.
#
#    ./devops/scripts/preparar.sh placeholders   # grava QUAY_HOST/QUAY_ORG nos manifestos (commit)
#    ./devops/scripts/preparar.sh cluster        # marca o cluster gerenciado no ACM
#    ./devops/scripts/preparar.sh secrets        # cria os Secrets no hub (lê variáveis de ambiente)
#    ./devops/scripts/preparar.sh aplicar        # aplica ACM, pipeline e Argo CD no hub
#    ./devops/scripts/preparar.sh webhook        # mostra a URL e o segredo do webhook do GitHub
#    ./devops/scripts/preparar.sh tudo           # todos acima, em ordem
#
#  Variáveis para "secrets":
#    QUAY_PUSH_USER / QUAY_PUSH_TOKEN   robot com WRITE (usado pela pipeline no hub)
#    QUAY_PULL_USER / QUAY_PULL_TOKEN   robot com READ  (distribuído ao cluster 2 pela Policy)
#    GITHUB_TOKEN                       PAT com push na branch devops
#    WEBHOOK_SECRET                     opcional; gerado se vazio
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# shellcheck source=../config.env
source devops/config.env

hub() { command oc --context="$HUB_CTX" "$@"; }
titulo() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
aplicar_secret() { hub apply -f - >/dev/null; }

placeholders() {
  titulo "Placeholders → $QUAY_HOST / $QUAY_ORG"
  [[ "$QUAY_HOST" == *"<"* ]] && { echo "edite QUAY_HOST em devops/config.env" >&2; exit 1; }
  mapfile -t arquivos < <(grep -rlE '<QUAY_HOST>|<QUAY_ORG>' devops \
    --include='*.yaml' --exclude-dir=docs --exclude-dir=scripts || true)
  if [[ ${#arquivos[@]} -eq 0 ]]; then echo "nada a trocar (já preparado)"; return; fi
  sed -i -e "s|<QUAY_HOST>|$QUAY_HOST|g" -e "s|<QUAY_ORG>|$QUAY_ORG|g" "${arquivos[@]}"
  printf '  %s\n' "${arquivos[@]}"
  git add "${arquivos[@]}"
  git commit -q -m "devops: registry $QUAY_HOST/$QUAY_ORG" && git push -q origin HEAD:devops
  echo "commit + push feitos"
}

cluster() {
  titulo "Marcando $CLUSTER_GERENCIADO com devops=gerenciado"
  hub label managedcluster "$CLUSTER_GERENCIADO" devops=gerenciado --overwrite
}

secrets() {
  titulo "Secrets no hub"
  : "${QUAY_PUSH_USER:?}" "${QUAY_PUSH_TOKEN:?}" "${QUAY_PULL_USER:?}" "${QUAY_PULL_TOKEN:?}" "${GITHUB_TOKEN:?}"
  WEBHOOK_SECRET="${WEBHOOK_SECRET:-$(openssl rand -hex 20)}"
  hub apply -f devops/pipeline/00-namespace.yaml -f devops/acm/00-clusterset-bindings.yaml >/dev/null
  hub -n devops-ci create secret docker-registry quay-push --docker-server="$QUAY_HOST" \
    --docker-username="$QUAY_PUSH_USER" --docker-password="$QUAY_PUSH_TOKEN" \
    --dry-run=client -o yaml | aplicar_secret
  hub -n devops-policies create secret docker-registry quay-pull --docker-server="$QUAY_HOST" \
    --docker-username="$QUAY_PULL_USER" --docker-password="$QUAY_PULL_TOKEN" \
    --dry-run=client -o yaml | aplicar_secret
  hub -n devops-ci create secret generic github-token --from-literal=token="$GITHUB_TOKEN" \
    --dry-run=client -o yaml | aplicar_secret
  hub -n devops-ci create secret generic github-webhook --from-literal=secret="$WEBHOOK_SECRET" \
    --dry-run=client -o yaml | aplicar_secret
  echo "quay-push, github-token, github-webhook (devops-ci) e quay-pull (devops-policies) ok"
}

aplicar() {
  titulo "ACM: bindings, GitOpsCluster e Policy"
  hub apply -f devops/acm/
  titulo "Pipeline (devops-ci)"
  hub apply -k devops/pipeline
  titulo "Argo CD: aplicação raiz"
  hub apply -f devops/argocd/root-devops.yaml
}

webhook() {
  titulo "Webhook do GitHub (Settings › Webhooks › Add webhook)"
  echo "  Payload URL : https://$(hub -n devops-ci get route el-devops-webhook -o jsonpath='{.spec.host}')"
  echo "  Content type: application/json   ·   Just the push event"
  echo "  Secret      : $(hub -n devops-ci get secret github-webhook -o jsonpath='{.data.secret}' | base64 -d)"
}

case "${1:-}" in
  placeholders|cluster|secrets|aplicar|webhook) "$1" ;;
  tudo) placeholders; cluster; secrets; aplicar; webhook ;;
  *) sed -n '3,20p' "$0"; exit 1 ;;
esac
