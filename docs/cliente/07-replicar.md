# 7. Replicar a esteira em outro cliente

O que muda de um cliente para outro são **três coisas**: a URL do repositório,
o `values.yaml` de cada cluster e os Secrets (que nunca ficam no Git). Os charts
não mudam.

## 7.1 O que trocar no repositório

Todas as ocorrências abaixo apontam para o repositório de origem. Troque para o
repositório do cliente:

```bash
grep -rn "github.com/pecorawal/gitops-infra" --exclude-dir=.git .
```

| Arquivo | Campo |
|---|---|
| `bootstrap/02-appset-cliente.yaml` | `generators[].git.repoURL` e `template.spec.source.repoURL` |
| `argocd/root-cliente.yaml` | `spec.source.repoURL` |
| `charts/cluster-bundle/values.yaml` | `global.repoURL` (só o default; o ApplicationSet sobrescreve) |
| `bootstrap/app-set-import.yaml`, `argocd/root-*.yaml` | idem, se usar o fluxo de importação |

A `targetRevision` (`cliente`) também é sua escolha — pode ser `main` no repo do
cliente.

## 7.2 Criar o primeiro cluster

```bash
cp -r clusters/azr-cliente-dev-01 clusters/<nome-do-cluster>
```

O diretório-modelo já vem com **todos** os blocos e placeholders. Duas regras:

- o nome do diretório tem que ser **igual** a `clusterName`
- nunca use uma linha `---` no arquivo (ver [Causa 0](04-troubleshooting.md))

Substitua os `<MAIUSCULAS>`. Cada um tem, ao lado, o comando que descobre o
valor ou um exemplo:

| Placeholder | Onde obter |
|---|---|
| `<AZURE_SUBSCRIPTION_ID>` | `az account show --query id -o tsv` |
| `<AZURE_TENANT_ID>` | `az account show --query tenantId -o tsv` |
| `<AZURE_SP_CLIENT_ID>` | `appId` do Service Principal |
| `<CLUSTER_IMAGE_SET>` | `oc get clusterimageset` (no hub) |
| `<PUBLIC_DOMAIN>` / `<PRIVATE_DOMAIN>` | zonas DNS na Azure |
| `<PUBLIC_DNS_ZONE_ID>` | `az network dns zone show -n <dom> -g <rg> --query id -o tsv` |
| `<PRIVATE_DNS_ZONE_ID>` | `az network private-dns zone show -n <dom> -g <rg> --query id -o tsv` |
| `<VNET_*>`, `<*_SUBNET>` | rede pré-existente do cliente |
| `<CLUSTER_SET>` | `oc get managedclusterset` (no hub) |

Confira antes de commitar:

```bash
./docs/cliente/scripts/verificar-values.sh <nome-do-cluster>
```

> Os charts **falham o render** se sobrar qualquer `<MAIUSCULAS>` num bloco
> ligado. Um placeholder esquecido vira erro na Application, não cluster
> instalado errado.

## 7.3 Ligar por camadas

Não ligue tudo de uma vez. Cada `enabled: true` é um commit, e cada camada tem
pré-requisito fora do Git:

| Ordem | Bloco | Pré-requisito |
|---|---|---|
| 1 | `provision` | Credential do ACM + Secrets no namespace do cluster (`preparar-credenciais.sh`) |
| 2 | `operators` | cluster provisionado e registrado no ArgoCD |
| 3 | `certManager` | Secret `azuredns-config` no spoke (`criar-secrets-day2.sh`) |
| 4 | `ingress` | certificados emitidos (wave 20 antes da 30) |
| 5 | `externalDNS` | Secrets `azure-config-file-*` no spoke |
| 6 | `nsgRule` | SPN com `Network Contributor` no RG do NSG **e** no da VNet |
| 7 | `autoscaling` | cluster de pé |
| 8 | `identityProvider` | registro de aplicação no IdP + Secret em `openshift-config` |

## 7.4 O que nunca vai para o Git

| Secret | Onde | Criado por |
|---|---|---|
| credenciais Azure + pull secret | hub, ns do cluster | `preparar-credenciais.sh` |
| `azuredns-config` | spoke, `cert-manager` | `criar-secrets-day2.sh` |
| `azure-config-file-{private,public}` | spoke, `external-dns-operator` | `criar-secrets-day2.sh` |
| `azure-spn` | spoke, `nsg-rule` | `criar-secrets-day2.sh` |
| `openid-client-secret` | spoke, `openshift-config` | `criar-secrets-day2.sh` |

`externalDNS.azure.aadClientSecret` fica **sempre vazio** no values.

## 7.5 Antes de entregar

```bash
# nenhum dado real de outro cliente
grep -rniE "<seu-cliente-anterior>|subscription-id-antigo" --exclude-dir=.git .

# todos os charts renderizam com o modelo
for c in charts/*/; do
  helm template t "$c" -f clusters/azr-cliente-dev-01/values.yaml >/dev/null \
    && echo "OK  $(basename $c)" || echo "FALHOU $(basename $c)"
done
```
