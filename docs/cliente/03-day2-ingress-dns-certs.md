# 3. Day-2: ingress, DNS e certificados

Pré-requisito: o cluster já aparece registrado no ArgoCD.

```bash
oc get secret -n openshift-gitops -l argocd.argoproj.io/secret-type=cluster
```

## 3.1 Criar os Secrets que não vão para o Git

O client secret do Service Principal nunca é versionado. O script abaixo lê os
valores não-sensíveis do próprio `values.yaml` e pede só o segredo:

```bash
export KUBECONFIG=~/.kube/azr-cliente-prod-01     # o cluster NOVO, não o hub
./docs/cliente/scripts/criar-secrets-day2.sh clusters/azr-cliente-prod-01/values.yaml
```

Ele cria:

| Secret | Namespace | Conteúdo |
|---|---|---|
| `azuredns-config` | `cert-manager` | `client-secret` — usado pelo solver DNS01 |
| `azure-config-file-private` | `external-dns-operator` | `azure.json` com o RG da **Private** DNS Zone |
| `azure-config-file-public` | `external-dns-operator` | `azure.json` com o RG da DNS Zone **pública** |

São dois `azure.json` porque cada zona vive num resource group diferente.

## 3.2 Operators

```yaml
operators:
  enabled: true
```

Commite. Instala o **cert-manager Operator for Red Hat OpenShift** (ns
`cert-manager-operator`, operando em `cert-manager`) e o **ExternalDNS Operator**
(ns `external-dns-operator`).

```bash
oc get csv -n cert-manager-operator
oc get csv -n external-dns-operator
oc get pods -n cert-manager
```

## 3.3 Certificados

Preencha `certManager.*` e vire:

```yaml
certManager:
  enabled: true
```

São criados dois `ClusterIssuer`:

**`letsencrypt-prod`** — ACME com desafio DNS01 na Azure DNS Zone pública.
Funciona também para nomes que só resolvem dentro da VNet: o registro TXT
`_acme-challenge` é criado na zona **pública**, e é só ele que o Let's Encrypt
consulta. Requisito: o domínio precisa estar delegado publicamente.

**`internal-ca`** — CA própria. Com `internalCA.selfSigned: true` a cadeia é
montada dentro do cluster (`selfsigned-bootstrap` → `Certificate` raiz → `internal-ca`).
Não depende de internet, mas os clients precisam confiar na CA raiz:

```bash
oc get secret internal-ca-key-pair -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > internal-ca.crt
```

Para usar uma CA corporativa em vez da gerada: `selfSigned: false` e crie o Secret
`internal-ca-key-pair` (`tls.crt` + `tls.key`) no namespace `cert-manager`.

Qual issuer cada ingress usa é escolhido em
`ingress.<private|public>.certificate.issuer`.

Os certificados dos ingress são emitidos **no namespace `openshift-ingress`** —
é de lá que o IngressController lê `spec.defaultCertificate`.

```bash
oc get clusterissuer
oc get certificate -A
oc describe certificate public-ingress-tls -n openshift-ingress
```

> Para testar sem gastar a cota do Let's Encrypt, use o servidor de staging em
> `certManager.acme.server` (o certificado emitido não será confiável).

## 3.4 IngressControllers

Preencha `ingress.*` e vire:

```yaml
ingress:
  enabled: true
```

- **`private`** — `scope: Internal` (Azure Internal Load Balancer). Só é alcançável
  de dentro da VNet.
- **`public`** — `scope: External` (Azure Public Load Balancer).
- Ambos com `dnsManagementPolicy: Unmanaged`: quem cria os registros é o ExternalDNS,
  não o ingress-operator. Sem isso os dois brigam pelos mesmos registros.

### A label de admissão

```yaml
ingress:
  private:
    routeSelector:
      key: router          # a chave da label
      value: private       # o valor exigido
```

Só entram nesse IngressController as Routes que carreguem `router: private`.

### Isolamento do IngressController default

Uma Route é admitida por **todo** IngressController cujo `routeSelector` case com
ela. O `default` nasce com selector vazio, ou seja, admite tudo — inclusive as suas
rotas privadas, que passariam a ser servidas também pelo ingress default.

Por isso `ingress.default.isolateByLabel: true` aplica ao `default`:

```yaml
routeSelector:
  matchExpressions:
    - key: router
      operator: DoesNotExist
```

O default passa a recusar qualquer Route que tenha a label `router`. Rotas do
console, do OAuth e demais rotas de plataforma não têm essa label e continuam
funcionando normalmente.

Para desligar, use `isolateByLabel: false`. Para reverter à mão:

```bash
oc patch ingresscontroller default -n openshift-ingress-operator \
  --type=json -p '[{"op":"remove","path":"/spec/routeSelector"}]'
```

Verificar:

```bash
oc get ingresscontroller -n openshift-ingress-operator
oc get svc -n openshift-ingress          # os dois Load Balancers e seus IPs
```

## 3.5 ExternalDNS

Preencha `externalDNS.*` e vire:

```yaml
externalDNS:
  enabled: true
```

Duas instâncias, uma por IngressController:

```yaml
source:
  type: OpenShiftRoute
  openshiftRouteOptions:
    routerName: private        # só olha as Routes deste router
```

O que separa a zona privada da pública **não** é o provider (é `Azure` nos dois
casos) e sim o resource ID em `spec.zones`:

```
/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/privateDnsZones/<zona>   → Private DNS
/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/dnszones/<zona>          → DNS pública
```

Pegue os IDs com:

```bash
az network private-dns zone show -n <zona> -g <rg> --query id -o tsv
az network dns         zone show -n <zona> -g <rg> --query id -o tsv
```

Verificar:

```bash
oc get externaldns
oc logs -n external-dns-operator deploy/external-dns-private -f
```

## 3.6 Publicar uma aplicação

Basta rotular a Route:

```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: checkout
  namespace: pagamentos
  labels:
    router: public          # ou: router: private
spec:
  host: checkout.public.apps.azr-cliente-prod-01.cliente.com.br
  to:
    kind: Service
    name: checkout
  tls:
    termination: edge
```

A partir daí, sem mais nenhuma ação:

1. o IngressController `public` admite a rota;
2. o ExternalDNS cria o registro na Azure DNS Zone pública apontando para o LB público;
3. o certificado wildcard `*.public.apps...` do cert-manager já cobre o host.

### Certificado dedicado para uma aplicação

Se a aplicação precisar de certificado próprio (host fora do wildcard, ou chave
separada), declare em `certManager.appCertificates`:

```yaml
certManager:
  appCertificates:
    - name: checkout-tls
      namespace: pagamentos
      issuer: letsencrypt-prod      # ou internal-ca
      secretName: checkout-tls
      dnsNames:
        - "checkout.cliente.com.br"
```

O namespace precisa existir — quem o cria são os ApplicationSets de `workloads/`,
que usam `CreateNamespace=true`.

➡️ [4. Troubleshooting](04-troubleshooting.md)
