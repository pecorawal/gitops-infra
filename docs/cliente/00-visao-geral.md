# Visão geral

Este repositório provisiona e configura clusters **OpenShift IPI na Azure** usando
**Red Hat Advanced Cluster Management (ACM/Hive)** e **OpenShift GitOps (ArgoCD)**.

Você edita **um único arquivo** — `clusters/<seu-cluster>/values.yaml` — e o ArgoCD
faz o resto. Nada de `oc apply` manual depois do bootstrap inicial.

## O que é entregue

| Camada | O que é criado | Onde roda |
|---|---|---|
| Provisionamento | `ClusterDeployment` (Hive) + `install-config` + `MachinePool` + `ManagedCluster` | Hub |
| Operators | cert-manager Operator, ExternalDNS Operator | Cluster novo |
| Certificados | `ClusterIssuer` ACME/Azure DNS e CA interna, `Certificate` dos ingress e das apps | Cluster novo |
| Ingress | IngressController **privado** (LB interno) e **público** (LB externo) | Cluster novo |
| DNS | ExternalDNS → **Azure Private DNS Zone** e → **Azure DNS Zone** pública | Cluster novo |

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
                          └─ wave 40  dns-<cluster>        → charts/external-dns-config [SPOKE]
```

As cinco Applications filhas leem **o mesmo** `clusters/<cluster>/values.yaml`.

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
```

Você pode virar todos de uma vez ou avançar camada por camada — as sync-waves
garantem a ordem correta em qualquer um dos casos.

## Como as rotas são separadas

A separação entre ingress privado, público e default é feita por **label na Route**:

| Label na Route | IngressController | Load Balancer | Zona DNS | Certificado |
|---|---|---|---|---|
| `router: private` | `private` | Azure Internal LB | Private DNS Zone | `internal-ca` (configurável) |
| `router: public` | `public` | Azure Public LB | Azure DNS Zone | `letsencrypt-prod` (configurável) |
| _(sem label)_ | `default` | conforme `publish` | — | do cluster |

A chave da label (`router`) e os valores (`private` / `public`) são parâmetros
em `ingress.private.routeSelector` e `ingress.public.routeSelector`.

## Documentos

1. [Pré-requisitos](01-pre-requisitos.md)
2. [Provisionar o cluster](02-provisionar-cluster.md)
3. [Day-2: ingress, DNS e certificados](03-day2-ingress-dns-certs.md)
4. [Troubleshooting](04-troubleshooting.md)
