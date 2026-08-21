#!/usr/bin/env bash
# =============================================================================
#  Cria no CLUSTER GERENCIADO (spoke) os Secrets que nao podem ir para o Git.
#
#  Le os valores nao-sensiveis de clusters/<cluster>/values.yaml e pede apenas
#  o client secret do Service Principal, interativamente.
#
#  Uso:
#    oc login <api-do-cluster-gerenciado>
#    ./docs/cliente/scripts/criar-secrets-day2.sh clusters/azr-cliente-dev-01/values.yaml
# =============================================================================
set -euo pipefail

VALUES="${1:?uso: $0 <caminho-do-values.yaml>}"
[[ -f "$VALUES" ]] || { echo "arquivo nao encontrado: $VALUES" >&2; exit 1; }

get() { python3 -c "
import sys,yaml
d=yaml.safe_load(open('$VALUES'))
for k in '$1'.split('.'):
    d=d[k]
print(d)
"; }

get2() { python3 -c "
import sys,yaml
d=yaml.safe_load(open('$VALUES'))
for k in '$1'.split('.'):
    if isinstance(d, dict) and k in d:
        d=d[k]
    else:
        print('$2'); sys.exit(0)
print(d)
"; }

TENANT=$(get externalDNS.azure.tenantId)
SUBSCRIPTION=$(get externalDNS.azure.subscriptionId)
CLIENT_ID=$(get externalDNS.azure.aadClientId)
RG_PRIVATE=$(get externalDNS.private.resourceGroup)
RG_PUBLIC=$(get externalDNS.public.resourceGroup)
SECRET_PRIVATE=$(get externalDNS.private.configSecretName)
SECRET_PUBLIC=$(get externalDNS.public.configSecretName)

for v in TENANT SUBSCRIPTION CLIENT_ID RG_PRIVATE RG_PUBLIC; do
  if [[ "${!v}" == "<PREENCHER>" || -z "${!v}" ]]; then
    echo "ERRO: $v ainda esta como <PREENCHER> em $VALUES" >&2; exit 1
  fi
done

echo "Cluster alvo: $(oc whoami --show-server)"
echo "Service Principal: $CLIENT_ID (tenant $TENANT)"
read -rsp "Client secret do Service Principal: " CLIENT_SECRET; echo

# --- 1. cert-manager: apenas o client secret (o resto vem do ClusterIssuer) ---
oc create namespace cert-manager --dry-run=client -o yaml | oc apply -f -
oc create secret generic azuredns-config -n cert-manager \
  --from-literal=client-secret="$CLIENT_SECRET" \
  --dry-run=client -o yaml | oc apply -f -
echo "OK  secret/azuredns-config -n cert-manager"

# --- 2. ExternalDNS: um azure.json por zona (resourceGroups diferentes) ---
mk_azure_json() {
  printf '{"tenantId":"%s","subscriptionId":"%s","resourceGroup":"%s","aadClientId":"%s","aadClientSecret":"%s"}' \
    "$TENANT" "$SUBSCRIPTION" "$1" "$CLIENT_ID" "$CLIENT_SECRET"
}
oc create namespace external-dns-operator --dry-run=client -o yaml | oc apply -f -
for pair in "$SECRET_PRIVATE:$RG_PRIVATE" "$SECRET_PUBLIC:$RG_PUBLIC"; do
  name="${pair%%:*}"; rg="${pair##*:}"
  oc create secret generic "$name" -n external-dns-operator \
    --from-literal=azure.json="$(mk_azure_json "$rg")" \
    --dry-run=client -o yaml | oc apply -f -
  echo "OK  secret/$name -n external-dns-operator (resourceGroup=$rg)"
done

# --- 3. nsg-rule: SPN para sincronizar a regra do NSG com o IP do LB ---
#   O CronJob de nsg-rule usa este Secret para autenticar na Azure e
#   criar/atualizar a inbound rule (80/443 do Internet) apontando para o IP
#   publico do Load Balancer do IngressController.
NSG_ENABLED=$(get2 nsgRule.enabled false)
if [[ "$NSG_ENABLED" == "True" ]]; then
  NSG_NS=$(get2 nsgRule.namespace nsg-rule)
  oc create namespace "$NSG_NS" --dry-run=client -o yaml | oc apply -f -
  oc create secret generic azure-spn -n "$NSG_NS" \
    --from-literal=clientId="$CLIENT_ID" \
    --from-literal=clientSecret="$CLIENT_SECRET" \
    --from-literal=tenantId="$TENANT" \
    --dry-run=client -o yaml | oc apply -f -
  echo "OK  secret/azure-spn -n $NSG_NS (nsg-rule)"
else
  echo "SKIP nsgRule.enabled=false (sem secret azure-spn)"
fi

unset CLIENT_SECRET
echo
echo "Pronto. Agora vire operators/certManager/ingress/externalDNS/nsgRule para enabled: true em $VALUES e commite."
