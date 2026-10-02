#!/usr/bin/env bash
# =============================================================================
#  EMERGENCIA -- devolve o IngressController "default" ao Load Balancer INTERNO.
#
#  Sintoma que este script trata: em cluster privado, o LB do router default
#  virou PUBLICO (scope External), o IP mudou e o acesso interno a console
#  caiu.
#
#  Uso (logado no CLUSTER GERENCIADO, nao no hub):
#    ./docs/cliente/scripts/restaurar-ingress-default.sh            # so diagnostica
#    ./docs/cliente/scripts/restaurar-ingress-default.sh --confirmar
# =============================================================================
set -euo pipefail

NS_OP=openshift-ingress-operator
NS_ING=openshift-ingress
CONFIRMAR="${1:-}"

echo "Cluster: $(oc whoami --show-server)"
echo

escopo() {
  oc get ingresscontroller default -n "$NS_OP" \
    -o jsonpath='{.spec.endpointPublishingStrategy.loadBalancer.scope}' 2>/dev/null
}
ip_lb() {
  oc get svc router-default -n "$NS_ING" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null
}
interno() {
  oc get svc router-default -n "$NS_ING" \
    -o jsonpath='{.metadata.annotations.service\.beta\.kubernetes\.io/azure-load-balancer-internal}' 2>/dev/null
}

echo "=== ESTADO ATUAL ==="
echo "  scope do IngressController default : $(escopo)"
echo "  anotacao azure-load-balancer-internal: $(interno)"
echo "  IP do LB                            : $(ip_lb)"
echo

if [[ "$(escopo)" == "Internal" && "$(interno)" == "true" ]]; then
  echo "Ja esta Internal. Nada a fazer."
  exit 0
fi

if [[ "$CONFIRMAR" != "--confirmar" ]]; then
  cat <<TXT
=== O QUE SERIA FEITO (rode com --confirmar) ===

  1. patch no IngressController default -> scope Internal
  2. delete do Service router-default, para o ingress-operator recriar o LB
     como interno (a mudanca de escopo nao se aplica ao Service existente)

  IMPACTO: as rotas servidas pelo router default ficam indisponiveis por
  1-3 minutos, enquanto a Azure provisiona o Load Balancer novo. O IP sera
  DIFERENTE do atual -- o registro *.apps precisa apontar para o IP novo.

TXT
  exit 0
fi

echo "=== 1. scope -> Internal ==="
oc patch ingresscontroller default -n "$NS_OP" --type=merge -p \
  '{"spec":{"endpointPublishingStrategy":{"type":"LoadBalancerService","loadBalancer":{"scope":"Internal"}}}}'

echo "=== 2. recriando o Service router-default ==="
# O operator nao converte um LB publico existente em interno: e preciso deixar
# que ele recrie o Service ja com a anotacao de LB interno da Azure.
oc delete svc router-default -n "$NS_ING"

echo "=== 3. aguardando o LB novo (ate 5 min) ==="
for i in $(seq 1 60); do
  novo=$(ip_lb)
  if [[ -n "$novo" ]]; then
    echo
    echo "  scope    : $(escopo)"
    echo "  interno  : $(interno)"
    echo "  IP novo  : $novo"
    break
  fi
  printf '.'
  sleep 5
done
echo

echo "=== 4. PROXIMO PASSO MANUAL ==="
cat <<TXT
  O IP mudou. Atualize o registro wildcard *.apps na Azure Private DNS Zone
  para o IP acima, senao a console continua inacessivel mesmo com o LB correto:

    oc get ingresscontroller default -n $NS_OP -o jsonpath='{.status.domain}{"\n"}'
    oc get svc router-default -n $NS_ING -o jsonpath='{.status.loadBalancer.ingress[0].ip}{"\n"}'

  Confira quando voltar:
    oc get co ingress
    oc get pods -n $NS_ING
TXT
