# Visão geral

Este repositório provisiona e configura clusters **OpenShift IPI na Azure** usando
**Red Hat Advanced Cluster Management (ACM/Hive)** e **OpenShift GitOps (ArgoCD)**.

Você edita **um único arquivo** — `clusters/<seu-cluster>/values.yaml` — e o ArgoCD
faz o resto. Uma **única** Credential do ACM atende todos os provisionamentos:
um comando por cluster a materializa no namespace certo
(`preparar-credenciais.sh`), ou nenhum comando, se o hub tiver o External Secrets
Operator.

## O que é entregue

| Camada | O que é criado | Onde roda |
|---|---|---|
| Provisionamento | `ClusterDeployment` (Hive) + `install-config` + `MachinePool` + `ManagedCluster` | Hub |
| Operators | cert-manager Operator, ExternalDNS Operator | Cluster novo |
| Certificados | `ClusterIssuer` ACME/Azure DNS, wildcards `*.cgibs.gov.br` e `*.pri.cgibs.gov.br` | Cluster novo |
| Ingress | IngressController **privado** (LB interno) e **público** (LB externo), separados pela label `ingress-type` | Cluster novo |
| DNS | ExternalDNS → **Azure Private DNS Zone** e → **Azure DNS Zone** pública | Cluster novo |
| Autoscaling | `ClusterAutoscaler` global + `MachineAutoscaler` por MachineSet (pool worker, min..max) | Cluster novo |

## Como o fluxo se encadeia

```
argocd/root-cliente.yaml            (aplicado UMA vez, na mão)
        │
        └─► bootstrap/              GitOpsCluster + ApplicationSet
                │
                └─► ApplicationSet "cliente-clusters"
                     varre clusters/*/values.yaml
                     │
                     └─► Application "bundle-<cluster>"  →  charts/cluster-bundle
                          (o APP DOS APPS — só emite Applications)
                          │
                          ├─ wave  0  provision-<cluster>  → charts/azure-ipi-cluster   [HUB]
                          ├─ wave 10  operators-<cluster>  → charts/cluster-operators   [SPOKE]
                          ├─ wave 20  certs-<cluster>      → charts/cert-manager-config [SPOKE]
                          ├─ wave 30  ingress-<cluster>    → charts/ingress-controllers [SPOKE]
                          ├─ wave 40  dns-<cluster>        → charts/external-dns-config [SPOKE]
                          ├─ wave 50  nsg-<cluster>        → charts/nsg-rule            [SPOKE]
                          └─ wave 60  autoscale-<cluster>  → charts/cluster-autoscaling [SPOKE]
```

As sete Applications filhas leem **o mesmo** `clusters/<cluster>/values.yaml`.

## Agrupamento por ambiente

O `ManagedClusterSet` em que o cluster entra é decidido por `labels.env`:

| `labels.env` | ManagedClusterSet |
|---|---|
| `prod`, `pro` | `pro` |
| `non-prod`, `non-pro`, `dev`, `qa`, `hml` | `non-pro` |
| qualquer outro | `clusterSets.default` (ou falha, se vazio) |

O nome do ambiente e o nome do set não precisam coincidir: `env: prod` leva ao
`ManagedClusterSet` chamado `pro`.

Os dois sets já existem no ACM e **não são criados por este repositório** — só
vinculados ao namespace `openshift-gitops`
(`bootstrap/03-cluster-set-bindings.yaml`). O mapa é editável em
`clusterSets.byEnv` no values do cluster. Detalhes em
[2.3](02-provisionar-cluster.md#23-escolher-o-managedclusterset-pelo-env).

## Os interruptores

Cada bloco do `values.yaml` tem um `enabled:`. Enquanto ele for `false`, o chart
correspondente não emite nada — o ArgoCD fica escutando o repositório e materializa
a camada no instante em que você preenche os valores e vira o interruptor.

```
provision.enabled    →  cria o cluster
operators.enabled    →  instala cert-manager e ExternalDNS
certManager.enabled  →  cria ClusterIssuers e Certificates
ingress.enabled      →  cria os IngressControllers
externalDNS.enabled  →  publica os registros de DNS
nsgRule.enabled      →  sincroniza a inbound rule do NSG com o IP do LB do ingress
autoscaling.enabled  →  liga o autoscaling do pool worker (min..max por MachineSet)
```

Você pode virar todos de uma vez ou avançar camada por camada — as sync-waves
garantem a ordem correta em qualquer um dos casos.

## Como as rotas são separadas

A separação entre os três IngressControllers é feita por **uma label na Route**:
`ingress-type`.

| Label na Route | IngressController | Load Balancer | Domínio | Zona DNS | Certificado |
|---|---|---|---|---|---|
| `ingress-type: private` | `private` | Azure Internal LB | `pri.cgibs.gov.br` | Azure **Private** DNS Zone | `*.pri.cgibs.gov.br` |
| `ingress-type: public` | `public` | Azure Public LB | `cgibs.gov.br` | Azure DNS Zone (pública) | `*.cgibs.gov.br` |
| qualquer outro valor | `default` | conforme `publish` | `apps.<cluster>.cgibs.gov.br` | — | do cluster |
| _(sem a label)_ | `default` | conforme `publish` | `apps.<cluster>.cgibs.gov.br` | — | do cluster |

O **`default` fica reservado às aplicações internas do OpenShift**. Ele recebe o
seletor:

```yaml
routeSelector:
  matchExpressions:
    - key: ingress-type
      operator: NotIn
      values: [public, private]
```

`NotIn` no seletor de labels do Kubernetes também casa com objetos que **não têm**
a label — por isso o console, o OAuth e as demais rotas de plataforma continuam
no `default` sem qualquer alteração.

A chave da label e os valores reservados são parâmetros
(`ingress.default.labelKey`, `ingress.default.reservedValues`,
`ingress.<private|public>.routeSelector`).

## Certificados: os dois wildcards saem do Let's Encrypt

Não há CA interna nesta arquitetura. O `ClusterIssuer` **`letsencrypt-prod`**
emite os dois wildcards por desafio **DNS01 na Azure DNS Zone pública**:

- `*.cgibs.gov.br` → certificado padrão do IngressController público
- `*.pri.cgibs.gov.br` → certificado padrão do IngressController privado

O wildcard privado também sai daí: o desafio grava o TXT
`_acme-challenge.pri.cgibs.gov.br` na zona **pública** `cgibs.gov.br`, e é só esse
registro que o Let's Encrypt consulta. O nome final continua resolvendo apenas na
Private DNS Zone, dentro da VNet.

> **Requisito:** `pri.cgibs.gov.br` não pode estar delegado publicamente para
> outro servidor de nomes. Confirme com `dig +short NS pri.cgibs.gov.br` — não
> deve retornar nada.

Como os dois wildcards já cobrem qualquer host de um nível sob os dois domínios,
**a maioria das aplicações não precisa pedir certificado nenhum**: basta a label
correta na Route. Certificado próprio só é necessário para host fora do wildcard,
chave separada ou exigência de auditoria — ver
[3.6](03-day2-ingress-dns-certs.md#36-publicar-uma-aplicação).

## Documentos

1. [Pré-requisitos](01-pre-requisitos.md)
2. [Provisionar o cluster](02-provisionar-cluster.md)
3. [Day-2: ingress, DNS e certificados](03-day2-ingress-dns-certs.md)
4. [Troubleshooting](04-troubleshooting.md)
5. [Estender: novos operadores, manifestos e camadas](05-estender.md)
