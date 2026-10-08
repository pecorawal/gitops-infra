#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Fase central da demo · "do commit à violação"
#
#  Cada etapa troca o Deployment do pagamentos-api no Git por uma variação que
#  viola UMA política DEMO, faz commit + push, força o refresh do Argo CD
#  (auto-sync) e espera o sync — o ACS mostra a violação em ~1 minuto.
#
#    ./seguranca/demo-apps/etapa.sh 00   # versão inicial (aceitável) — estado de partida
#    ./seguranca/demo-apps/etapa.sh 01   # CVE corrigível: Log4Shell
#    ./seguranca/demo-apps/etapa.sh 02   # tag latest
#    ./seguranca/demo-apps/etapa.sh 03   # container privilegiado
#    ./seguranca/demo-apps/etapa.sh 04   # runtime: ferramenta de rede (curl)
#    ./seguranca/demo-apps/etapa.sh 05   # runtime: exec no pod (comando ao vivo, sem commit)
#    ./seguranca/demo-apps/etapa.sh 06   # versão final (corrige tudo)
#    ./seguranca/demo-apps/etapa.sh status
#
#  Requisitos: clone da branch 'seguranca' com permissão de push; oc no hub
#  (ou OC_CONTEXT=<contexto do hub>). Rodar a partir da raiz do repositório.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

ETAPAS=seguranca/demo-apps/etapas
ALVO=seguranca/demo-apps/pagamentos-demo/10-deployment.yaml
APP=pagamentos-demo
NS=pagamentos-demo
oc() { command oc ${OC_CONTEXT:+--context="$OC_CONTEXT"} "$@"; }

titulo() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
mostrar() { printf '\n\033[1;36mNo ACS:\033[0m %s\n' "$*"; }

status() {
  titulo "Argo CD"
  oc -n openshift-gitops get applications.argoproj.io "$APP" \
    -o jsonpath='  sync={.status.sync.status} saúde={.status.health.status} revisão={.status.sync.revision}{"\n"}'
  titulo "Cluster ($NS)"
  oc -n "$NS" get deploy pagamentos-api \
    -o jsonpath='  etapa={.metadata.annotations.demo\.acs/etapa}{"\n"}  imagem={.spec.template.spec.containers[0].image}{"\n"}  réplicas={.status.readyReplicas}/{.spec.replicas}{"\n"}'
  # só eventos recentes (2 min): FailedCreate de etapas anteriores não confundem
  oc -n "$NS" get events -o json 2>/dev/null | jq -r --arg d "$(date -u -d '-2 min' +%FT%TZ)" \
    '[.items[] | select(.reason=="FailedCreate" and ((.lastTimestamp // .eventTime // "") >= $d))]
     | last | select(.) | "  FailedCreate: \(.message[0:140])"' || true
}

aguardar_sync() {
  local rev; rev=$(git rev-parse HEAD)
  oc -n openshift-gitops annotate applications.argoproj.io "$APP" argocd.argoproj.io/refresh=normal --overwrite >/dev/null
  printf 'Aguardando o Argo CD sincronizar %s ' "${rev:0:7}"
  for _ in $(seq 1 45); do
    if [[ "$(oc -n openshift-gitops get applications.argoproj.io "$APP" -o jsonpath='{.status.sync.revision} {.status.sync.status}')" == "$rev Synced" ]]; then
      echo " ok"; return 0
    fi
    printf '.'; sleep 4
  done
  echo; echo "AVISO: o Argo CD ainda não sincronizou ${rev:0:7}; confira a Application '$APP'." >&2
}

aplicar() {
  local n=$1 arq desc
  arq=$(ls "$ETAPAS/$n"-*.yaml 2>/dev/null | head -1) || true
  [[ -n "$arq" ]] || { echo "etapa $n não existe em $ETAPAS" >&2; exit 2; }
  desc=$(sed -n "s/^ *demo\.acs\/etapa: *//p" "$arq" | head -1 | tr -d "'\"")
  titulo "Etapa $desc"
  sed -n '/^#  /s/^#  /  /p' "$arq"
  cp "$arq" "$ALVO"
  if git diff --quiet -- "$ALVO"; then
    echo "(o Git já está nesta etapa; nada para commitar)"
  else
    git add "$ALVO"
    git commit -q -m "demo(etapa $n): $desc"
    git push -q
    echo "commit $(git rev-parse --short HEAD) enviado"
  fi
  aguardar_sync
  status
}

case "${1:-}" in
  00) aplicar 00
      mostrar "Violations › User Workloads › Active, filtro Namespace: $NS — nenhuma política DEMO.
         Ponto de partida: a aplicação em produção, limpa." ;;
  01) aplicar 01
      mostrar "Violations › Active: 'DEMO - CVE corrigível…', 'Log4Shell', 'Spring4Shell' (estágio Deploy).
         Vulnerability Management › Results › User Workloads (Namespace $NS, Fixable): CVE-2021-44228.
         Contraste: ./seguranca/pipeline/roxctl-check.sh → o CI teria BARRADO antes do commit." ;;
  02) aplicar 02
      mostrar "Active: 'DEMO - Tag latest proibida'. Resolved: as de Log4Shell (a imagem saiu)." ;;
  03) aplicar 03
      mostrar "Active: 'DEMO - Container privilegiado…' (CRITICAL). No cluster: FailedCreate pela SCC —
         a versão anterior segue atendendo. Contraste humano:
         oc apply -f seguranca/demo-apps/variacoes/privilegiado.yaml → NEGADO pelo ACS (aba Attempted)." ;;
  04) aplicar 04
      echo "(o Collector precisa ver o curl rodar: aguarde ~1 minuto)"
      mostrar "Active: 'DEMO - Ferramenta de rede…' (estágio Runtime), com processo, argumentos e horário.
         Resolved: a de privilégio." ;;
  05) titulo "Etapa 05 - viola em runtime: exec no pod (mudança fora do Git)"
      echo "  Alguém tenta 'consertar' direto em produção:"
      echo "  \$ oc -n $NS exec deploy/pagamentos-api -- cat /etc/redhat-release"
      oc -n "$NS" exec deploy/pagamentos-api -- cat /etc/redhat-release || true
      mostrar "Violations › Attempted: 'DEMO - Exec em pod de pagamentos' — o comando foi recusado
         e a tentativa ficou registrada (quem, quando, em qual pod)." ;;
  06) aplicar 06
      mostrar "Resolved: todas as violações de Deploy das etapas anteriores.
         Ainda Active: a de runtime (curl) — evento que ACONTECEU não some com nova versão.
         Abra-a e clique 'Mark as resolved' (NÃO 'Resolve and add to process baseline':
         isso liberaria o curl para sempre). Resta só 'Docker CIS 4.1' (LOW, informativo)." ;;
  status) status ;;
  *) sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
