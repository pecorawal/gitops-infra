#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Demo A · o mesmo gate do CI, rodado do notebook do apresentador.
#  Plano B quando o GitHub Actions estiver lento ou sem acesso ao Central.
#
#    export ROX_ENDPOINT=central-stackrox.apps.<hub>:443
#    export ROX_API_TOKEN=<token>
#    ./roxctl-check.sh                                   # imagem vulnerável
#    ./roxctl-check.sh registry.access.redhat.com/ubi9/ubi-minimal:9.8
#
#  Saída 0 = passou; diferente de 0 = o pipeline seria barrado.
# ---------------------------------------------------------------------------
set -euo pipefail
IMAGE="${1:-registry.access.redhat.com/ubi8/ubi:8.0}"
: "${ROX_ENDPOINT:?defina ROX_ENDPOINT}" "${ROX_API_TOKEN:?defina ROX_API_TOKEN}"

if ! command -v roxctl >/dev/null; then
  echo ">> baixando roxctl do Central"
  curl -fsSk -H "Authorization: Bearer $ROX_API_TOKEN" \
    "https://$ROX_ENDPOINT/api/cli/download/roxctl-linux" -o ./roxctl
  chmod +x ./roxctl; PATH="$PWD:$PATH"
fi

echo ">> CVEs Críticas e Importantes em $IMAGE"
roxctl image scan --insecure-skip-tls-verify --image "$IMAGE" --output table \
  --severity CRITICAL,IMPORTANT | tail -25 || true

echo; echo ">> Gate de política (o que o pipeline decide)"
if roxctl image check --insecure-skip-tls-verify --image "$IMAGE" --output table; then
  echo; echo "RESULTADO: APROVADA — o build segue."
else
  rc=$?; echo; echo "RESULTADO: BARRADA no build (exit $rc) — conta para RSK-03 e RSK-04."; exit $rc
fi
