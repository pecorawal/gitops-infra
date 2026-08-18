# 1. Pré-requisitos

Tudo aqui é feito **uma única vez**, no **hub** (o cluster onde rodam ACM e OpenShift GitOps).

## 1.1 No hub

- Red Hat Advanced Cluster Management instalado e saudável.
- OpenShift GitOps (ArgoCD) instalado no namespace `openshift-gitops`.
- `oc` autenticado no hub.

## 1.2 Na Azure

| Recurso | Para quê |
|---|---|
| VNet + 2 subnets (masters e workers) | BYO VNet — o instalador **não** cria rede |
| Azure DNS Zone (pública) do `baseDomain` | API/ingress público e desafio DNS01 do Let's Encrypt |
| Azure Private DNS Zone | registros do ingress privado |
| Service Principal para a instalação | papel `Contributor` na subscription (ou nos RGs usados) |
| Service Principal para DNS | `DNS Zone Contributor` na zona pública e `Private DNS Zone Contributor` na zona privada |

> Pode ser o mesmo Service Principal para tudo, desde que acumule os papéis.

Se `outboundType: UserDefinedRouting`, a subnet precisa de rota de saída
(firewall/NAT) **antes** da instalação — o instalador não a cria.

## 1.3 Credential do ACM

A Credential **precisa ser criada no namespace com o mesmo nome do cluster**, porque
o Hive só lê Secrets do namespace do `ClusterDeployment`.

```bash
export CLUSTER=azr-cliente-dev-01
oc new-project "$CLUSTER"
```

No console do ACM: **Credentials → Add credential → Microsoft Azure**

- *Credential name*: `azr-cliente-dev-01-azure`
- *Namespace*: **`azr-cliente-dev-01`** (o namespace criado acima)
- Base DNS domain, Service Principal (clientId/clientSecret/tenantId/subscriptionId),
  Base domain resource group name, pull secret e chave SSH.

Confirme:

```bash
oc get secret -n "$CLUSTER" -l cluster.open-cluster-management.io/type=azr
```

## 1.4 Derivar o pull secret

A Credential do ACM guarda o pull secret na chave `pullSecret`, mas o Hive exige um
Secret do tipo `kubernetes.io/dockerconfigjson`. Um comando, uma vez por cluster:

```bash
export CLUSTER=azr-cliente-dev-01
export ACM_CRED=azr-cliente-dev-01-azure

oc get secret "$ACM_CRED" -n "$CLUSTER" -o jsonpath='{.data.pullSecret}' \
  | base64 -d > /tmp/ps.json

oc create secret docker-registry "${CLUSTER}-pull-secret" -n "$CLUSTER" \
  --from-file=.dockerconfigjson=/tmp/ps.json

rm -f /tmp/ps.json
```

## 1.5 Escolher a versão do OpenShift

```bash
oc get clusterimageset | grep 4.18
```

O nome que aparecer (ex.: `img4.18.20-multi-appsub`) vai em `provision.imageSetRef`.

## 1.6 Aplicar o root — uma única vez

```bash
oc apply -f argocd/root-cliente.yaml
```

Isso instala, a partir de `bootstrap/`:

- `GitOpsCluster` — registra os clusters do ACM como destino de deploy no ArgoCD;
- `ManagedClusterSet` / `Placement` / `ManagedClusterSetBinding`;
- o `ApplicationSet` **`cliente-clusters`**, que passa a reagir a cada commit em `clusters/`.

Verifique:

```bash
oc get application  cliente-bootstrap  -n openshift-gitops
oc get applicationset cliente-clusters  -n openshift-gitops
oc get gitopscluster -n openshift-gitops
```

> **Atenção:** no hub, use **ou** `argocd/root-cliente.yaml` (branch `cliente`) **ou**
> `argocd/root-clusters.yaml` (branch `main`) — os dois sincronizam a pasta `bootstrap/`
> e brigariam pelos mesmos objetos.

➡️ [2. Provisionar o cluster](02-provisionar-cluster.md)
