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

### Overrides do operando cert-manager (obrigatório em cluster privado)

Antes dos issuers (sync-wave `-1`), o chart ajusta o CR `CertManager/cluster` —
o objeto que o cert-manager-operator cria sozinho para configurar o operando.
O ArgoCD usa `ServerSideApply`, então mexe só nos campos declarados.

```yaml
certManager:
  operatorConfig:
    enabled: true
    controller:
      overrideArgs:
        - "--dns01-recursive-nameservers-only"
        - "--dns01-recursive-nameservers=1.1.1.1:53,8.8.8.8:53"
```

**Por que isso é necessário:** depois de gravar o TXT `_acme-challenge` na zona
pública, o cert-manager faz uma auto-checagem antes de avisar o Let's Encrypt.
Num cluster privado o resolver do pod é o DNS interno do OpenShift, que
encaminha para o DNS da VNet — e esse enxerga a **Private** DNS Zone. A consulta
vai para o servidor errado, o TXT não é encontrado e o `Certificate` trava
indefinidamente em *Waiting for DNS-01 challenge propagation*. Os dois
argumentos fazem o cert-manager consultar resolvers públicos diretamente,
ignorando o `/etc/resolv.conf` do pod.

> Se a saída para 53/udp na internet for bloqueada, substitua a lista por um
> resolver interno que enxergue a zona **pública**.

O mesmo bloco aceita `controller.overrideEnv` (útil para `HTTPS_PROXY`/`NO_PROXY`),
`controller.overrideResources`, `webhook.overrideArgs` e `cainjector.overrideArgs`.

Conferir depois do sync:

```bash
oc get certmanager cluster -o jsonpath='{.spec.controllerConfig.overrideArgs}{"\n"}'
oc rollout status deploy/cert-manager -n cert-manager
```

### Um único issuer para os dois wildcards

O `ClusterIssuer` **`letsencrypt-prod`** usa desafio **DNS01 na Azure DNS Zone
pública** (`cgibs.gov.br`) e emite:

| Certificado | Namespace | Usado por |
|---|---|---|
| `*.cgibs.gov.br` (`public-ingress-tls`) | `openshift-ingress` | `defaultCertificate` do IC público |
| `*.pri.cgibs.gov.br` (`private-ingress-tls`) | `openshift-ingress` | `defaultCertificate` do IC privado |

O wildcard **privado também sai do Let's Encrypt**, e isso funciona porque o
desafio DNS01 não precisa que o nome final seja resolvível na internet — ele só
precisa do registro TXT:

```
_acme-challenge.pri.cgibs.gov.br   TXT   <token>      ← gravado na zona PÚBLICA
```

O Let's Encrypt consulta esse TXT na zona pública `cgibs.gov.br`, valida, e emite
o certificado. O nome `app.pri.cgibs.gov.br` continua existindo **apenas** na
Azure Private DNS Zone, alcançável só de dentro da VNet.

> **Requisito para isso funcionar**
>
> ```bash
> dig +short NS pri.cgibs.gov.br
> ```
>
> Não pode retornar nada. Se `pri.cgibs.gov.br` estiver delegado publicamente a
> outro servidor de nomes, o TXT gravado em `cgibs.gov.br` não será encontrado e a
> emissão falha. Nesse caso, delegue a validação com `cnameStrategy` ou ligue a
> CA interna (abaixo).

Os `Certificate` são criados **no namespace `openshift-ingress`** — é de lá que o
IngressController lê `spec.defaultCertificate`.

```bash
oc get clusterissuer
oc get certificate -n openshift-ingress
oc describe certificate private-ingress-tls -n openshift-ingress
```

> Enquanto testa, use o servidor de staging em `certManager.acme.server` para não
> gastar a cota do Let's Encrypt (50 certificados por domínio por semana). O
> certificado emitido não será confiável.

### CA interna (desligada)

`certManager.internalCA.enabled: false` nesta arquitetura — os dois ingress usam
certificados ACME confiáveis e nada precisa ser distribuído aos clients.

O chart continua capaz de montar a cadeia (`selfsigned-bootstrap` → `Certificate`
raiz → `ClusterIssuer internal-ca`) caso um ambiente futuro não tenha domínio
delegado publicamente. Para ligar: `internalCA.enabled: true` e aponte
`ingress.private.certificate.issuer: internal-ca`.

## 3.4 IngressControllers

Preencha `ingress.*` e vire:

```yaml
ingress:
  enabled: true
```

| | `private` | `public` | `default` |
|---|---|---|---|
| Domínio | `pri.cgibs.gov.br` | `cgibs.gov.br` | `apps.<cluster>.cgibs.gov.br` |
| `scope` | `Internal` (Azure Internal LB) | `External` (Azure Public LB) | conforme `publish` |
| Admite | `ingress-type: private` | `ingress-type: public` | o resto |
| Certificado | `*.pri.cgibs.gov.br` | `*.cgibs.gov.br` | do cluster |
| DNS | Azure Private DNS Zone | Azure DNS Zone | — |

Ambos com `dnsManagementPolicy: Unmanaged`: quem cria os registros é o ExternalDNS,
não o ingress-operator. Sem isso os dois brigam pelos mesmos registros.

### A label de admissão

```yaml
ingress:
  private:
    routeSelector:
      key: ingress-type      # a chave da label
      value: private         # o valor exigido
```

Só entram nesse IngressController as Routes que carreguem `ingress-type: private`.

### O IngressController default fica com o OpenShift

`ingress.default.isolateByLabel: true` aplica ao `default`:

```yaml
routeSelector:
  matchExpressions:
    - key: ingress-type
      operator: NotIn
      values: [public, private]
```

Duas consequências, ambas desejadas:

1. Rotas com `ingress-type: private` ou `public` **não** são mais admitidas pelo
   default — sem isso elas seriam servidas por dois routers ao mesmo tempo.
2. Rotas **sem** a label continuam no default. `NotIn` no seletor de labels do
   Kubernetes casa também com objetos que não têm a chave, então console, OAuth
   e demais rotas de plataforma seguem funcionando sem alteração.

Uma rota com `ingress-type: interno` (ou qualquer outro valor) também vai para o
default — é assim que se publica uma aplicação interna do OpenShift sem expô-la.

Para reverter à mão:

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
    # <nome>-<cluster>: só olha as Routes admitidas por este router.
    # O chart monta esse sufixo sozinho, a partir de clusterName.
    routerName: private-<cluster>
```

O que separa a zona privada da pública **não** é o provider (é `Azure` nos dois
casos) e sim o resource ID em `spec.zones`:

```
/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/privateDnsZones/pri.cgibs.gov.br
/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/dnszones/cgibs.gov.br
```

```bash
az network private-dns zone show -n pri.cgibs.gov.br -g <rg> --query id -o tsv
az network dns         zone show -n cgibs.gov.br     -g <rg> --query id -o tsv
```

### A exclusão do subdomínio privado

`pri.cgibs.gov.br` é **subdomínio** de `cgibs.gov.br`. O filtro da instância
pública (`.*\.cgibs\.gov\.br`) casaria também com `app.pri.cgibs.gov.br`. Por
isso o values traz:

```yaml
externalDNS:
  public:
    excludeDomains:
      - "pri.cgibs.gov.br"
```

que gera um `filterType: Exclude` no CR. Na prática as duas instâncias já estão
separadas por `routerName`, mas a exclusão é a garantia explícita de que nenhuma
instância vai mexer nos registros da outra.

Verificar:

```bash
oc get externaldns
oc logs -n external-dns-operator deploy/external-dns-private -f
```

## 3.6 Publicar uma aplicação

### Com Route (recomendado)

Os dois wildcards já são o certificado padrão dos routers, então **na maioria dos
casos basta a label** — nenhum `Certificate` precisa ser pedido:

```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: checkout
  namespace: pagamentos
  labels:
    ingress-type: private          # ou: ingress-type: public
spec:
  host: checkout.pri.cgibs.gov.br  # um nível sob o domínio -> coberto pelo wildcard
  to:
    kind: Service
    name: checkout
  port:
    targetPort: 8080
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
```

A partir daí, sem mais nenhuma ação:

1. o IngressController `private-<cluster>` admite a rota (label bate com o `routeSelector`);
2. o ExternalDNS cria `checkout.pri.cgibs.gov.br` na Azure Private DNS Zone
   apontando para o LB interno;
3. o wildcard `*.pri.cgibs.gov.br` já serve o TLS.

Conferir qual router admitiu:

```bash
oc get route checkout -n pagamentos -o jsonpath='{.status.ingress[*].routerName}'; echo
```

### Com Ingress

Um objeto `Ingress` é convertido em `Route` pelo route-controller-manager, e a
Route gerada **herda as labels do Ingress** — então `ingress-type` funciona pelos
dois caminhos. Com a anotação `cert-manager.io/cluster-issuer`, o cert-manager
emite o certificado automaticamente (ingress-shim):

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: checkout
  namespace: pagamentos
  labels:
    ingress-type: private
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    # Sem esta anotação, a label é copiada apenas na CRIAÇÃO da Route.
    # Com ela, alterar a label no Ingress também atualiza a Route existente.
    route.openshift.io/reconcile-labels: "true"
spec:
  ingressClassName: openshift-default
  tls:
    - hosts:
        - checkout.pri.cgibs.gov.br
      secretName: checkout-tls
  rules:
    - host: checkout.pri.cgibs.gov.br
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: checkout
                port:
                  number: 8080
```

> **Atenção à anotação `route.openshift.io/reconcile-labels`.** No
> route-controller-manager, a Route recebe `Labels: ingress.Labels` no momento em
> que é criada, mas as labels só continuam sendo reconciliadas nas atualizações se
> essa anotação estiver como `"true"`. Sem ela, trocar `private` por `public` no
> Ingress não move a rota de router. Confirme com:
>
> ```bash
> oc get route -n pagamentos -l ingress-type=private --show-labels
> ```

### Certificado dedicado, via GitOps

Se a aplicação precisar de certificado próprio (host fora do wildcard, chave
separada, ou exigência de auditoria), declare em `certManager.appCertificates`:

```yaml
certManager:
  appCertificates:
    - name: portal-tls
      namespace: portal
      issuer: letsencrypt-prod
      secretName: portal-tls
      dnsNames:
        - "portal.cgibs.gov.br"
        - "www.portal.cgibs.gov.br"    # dois níveis: fora do wildcard
```

O namespace precisa existir — quem o cria são os ApplicationSets de `workloads/`,
que usam `CreateNamespace=true`.

➡️ [4. Troubleshooting](04-troubleshooting.md)
➡️ [5. Estender: novos operadores, manifestos e camadas](05-estender.md)

## 3.7 Regra do NSG para o ingress público (opcional)

O `nsg-rule` mantém uma inbound rule do Network Security Group (TCP 80/443
vindo da `Internet`) apontando para o **IP público do LB do IngressController
público**. Um CronJob lê o Service, compara e faz upsert na Azure — só escreve
quando o IP muda. Existe porque o IP do LB pode mudar (recriação do Service,
troca de escopo) e a regra ficaria apontando para o endereço antigo.

### Passo 1 — papel na Azure

O Service Principal é o **mesmo** já usado para DNS (`externalDNS.azure.aadClientId`).
Além dos papéis de DNS, ele precisa de **`Network Contributor`** no resource
group do NSG. Sem isso o CronJob falha com `AuthorizationFailed` na primeira
execução.

### Passo 2 — preencher o values e ligar

```yaml
nsgRule:
  enabled: true
  serviceName: router-public        # SEM o clusterName -- o chart põe o sufixo
  nsgName: "<nome-do-nsg>"
  nsgResourceGroup: "<rg-do-nsg>"
  subscriptionId: "<subscription>"
```

`serviceName` é validado contra `ingress.public.name`/`ingress.private.name`:
um nome que não corresponda a nenhum IngressController **falha o render**, em
vez de deixar o Job esperando 25 minutos pelo IP de um Service inexistente.

### Passo 3 — criar o Secret no spoke

O `criar-secrets-day2.sh` só cria este Secret quando encontra
`nsgRule.enabled: true` no arquivo. Então ligue o `enabled` **antes** de rodar
o script, e commite **depois**:

```bash
oc login <api-do-spoke>
./docs/cliente/scripts/criar-secrets-day2.sh clusters/<cluster>/values.yaml
```

Ele pede o client secret do SPN uma vez e o reaproveita para cert-manager,
ExternalDNS e nsg-rule. A saída confirma:

```
OK  secret/azure-spn -n nsg-rule (nsg-rule)
```

O nome vem de `nsgRule.secretName` e o namespace de `nsgRule.namespace`.

> Ordem importa: se você commitar antes de criar o Secret, o CronJob nasce e
> falha (`CreateContainerConfigError`) até o Secret aparecer. Não é destrutivo,
> mas polui o histórico de Jobs.

### Passo 4 — commitar e acompanhar

```bash
oc get cronjob -n nsg-rule
oc get jobs -n nsg-rule
oc logs -n nsg-rule job/<nome-do-job>
```

O log diz o que fez: `regra ... ja aponta para <ip> - nada a fazer` ou
`Criando/atualizando regra ... -> <ip>`. Para forçar uma execução sem esperar
o `schedule`:

```bash
oc create job -n nsg-rule --from=cronjob/nsg-rule-<cluster> nsg-rule-manual
```

