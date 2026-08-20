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

## 1.3 Credential do ACM — uma só, para todos os clusters

Crie **uma única** Credential Azure no ACM, num namespace dedicado. Ela serve
todos os provisionamentos: não é preciso criar uma por cluster, nem criar o
namespace do cluster à mão.

```bash
oc new-project acm-credentials
```

No console do ACM: **Credentials → Add credential → Microsoft Azure**

- *Credential name*: `azure-cliente`
- *Namespace*: **`acm-credentials`**
- Base DNS domain, Service Principal (clientId/clientSecret/tenantId/subscriptionId),
  Base domain resource group name, pull secret e chave SSH.

Anote **namespace** e **nome** — vão nos dois lugares do passo 1.4:

```bash
oc get secret -A -l cluster.open-cluster-management.io/type=azr \
  -o custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name
```

## 1.4 Levar a Credential até o namespace de cada cluster

O Hive só lê Secrets do **namespace do `ClusterDeployment`**, e esse namespace é
diferente para cada cluster. Como a Credential é uma só, ela precisa ser
materializada em cada namespace. Há dois caminhos.

### Caminho A — `mode: existing` (padrão, não exige operador nenhum)

Um comando por cluster, antes de commitar:

```bash
./docs/cliente/scripts/preparar-credenciais.sh azr-cliente-dev-01
```

O script localiza sozinho a Credential do ACM (pela label
`cluster.open-cluster-management.io/type=azr`) e cria, de forma idempotente:

| Objeto | Tipo | Chaves | Lido por |
|---|---|---|---|
| `namespace/<cluster>` | — | — | tudo do Hive |
| `<cluster>-azure-creds` | `Opaque` | `osServicePrincipal.json`, `ssh-privatekey` | `credentialsSecretRef`, `sshPrivateKeySecretRef` |
| `<cluster>-pull-secret` | `kubernetes.io/dockerconfigjson` | `.dockerconfigjson` | `pullSecretRef` |

> **A conversão do pull secret está aqui.** A Credential do ACM guarda o pull
> secret em texto, na chave `pullSecret`; o Hive exige o tipo
> `kubernetes.io/dockerconfigjson` com a chave `.dockerconfigjson`. O script faz
> a tradução e valida que o conteúdo é JSON antes de aplicar.

Se houver mais de uma Credential Azure, ele lista e pede que você escolha:

```bash
./docs/cliente/scripts/preparar-credenciais.sh azr-cliente-dev-01 acm-credentials/azure-cliente
```

Os nomes gerados são exatamente os que o chart procura, então no `values.yaml`
basta:

```yaml
provision:
  credentials:
    mode: existing
```

Nada mais a preencher. Repetir o script para o mesmo cluster é seguro — ele
atualiza os Secrets a partir da Credential atual, útil quando o Service Principal
é rotacionado.

### Caminho B — `mode: externalSecret` (exige o External Secrets Operator)

Se o hub tiver o ESO, a cópia acontece sozinha a cada sincronização e não há
passo manual algum. Verifique:

```bash
oc get crd externalsecrets.external-secrets.io
```

> **Se o CRD não existir, não use este modo.** O ArgoCD não consegue nem comparar
> o estado desejado (`no matches for kind "ExternalSecret"`), a Application vai a
> `ComparisonError` e **nada** é aplicado — nem o `Namespace`, que está no mesmo
> chart. O sintoma é "o provisionamento fica parado e não cria nem o namespace".

Com o ESO presente, edite `bootstrap/05-acm-credentials-store.yaml` e troque
`acm-credentials` pelo seu namespace nos **quatro** pontos marcados
`# <<< NAMESPACE`. Isso cria:

| Objeto | Papel |
|---|---|
| `ServiceAccount eso-acm-credentials-reader` | identidade que o ESO usa para ler |
| `Role` + `RoleBinding` | leitura de Secrets **apenas** nesse namespace |
| `ClusterSecretStore acm-credentials-hub` | origem tipo `kubernetes`, apontando para o próprio hub |

E no values do cluster:

```yaml
provision:
  credentials:
    mode: externalSecret
    sourceNamespace: acm-credentials
    sourceSecret: azure-cliente
```

Os dois `ExternalSecret` gerados produzem exatamente os mesmos Secrets do
caminho A, com os mesmos nomes.

### Qual escolher

| | A — `existing` | B — `externalSecret` |
|---|---|---|
| Operador extra | nenhum | External Secrets Operator |
| Passo por cluster | um comando, uma vez | nenhum |
| Rotação do SP | rodar o script de novo | automática (`refreshInterval`) |
| Falha se o operador não existir | — | **quebra tudo, inclusive o Namespace** |

Nos dois casos nenhum segredo passa pelo Git.

> Existe ainda um terceiro caminho, não implementado aqui: uma `Policy` do ACM
> com *hub templates* (`{{hub fromSecret ... hub}}`) materializando os Secrets
> no `local-cluster`. Dispensa o ESO e mantém tudo em GitOps, mas depende da
> versão do ACM (desde a 2.9 os hub templates só enxergam objetos do mesmo
> namespace da Policy) e guarda o valor resolvido na Policy replicada. Se
> preferir esse caminho, peça que eu monte.

## 1.5 Escolher a versão do OpenShift

```bash
oc get clusterimageset | grep 4.18
```

O nome que aparecer (ex.: `img4.18.20-multi-appsub`) vai em `provision.imageSetRef`.

## 1.6 Dar ao ArgoCD permissão sobre as APIs do ACM e do Hive

Por padrão a ServiceAccount do ArgoCD **não** tem RBAC para `ManagedClusterSet`,
`Channel`, `ClusterDeployment` e companhia. Sem este passo, a primeira
sincronização falha com mensagens do tipo:

```
channels.apps.open-cluster-management.io is forbidden: User
  "system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller"
  cannot create resource "channels" in namespace "cluster-gitops-repo"

managedclustersets/bind.apps "global-clusters" is forbidden: user ... is not
  allowed to bind cluster set "global-clusters"

managedclustersets.cluster.open-cluster-management.io "global-clusters" is
  forbidden: User ... cannot patch resource "managedclustersets" at the cluster scope
```

Aplique como **cluster-admin**:

```bash
oc apply -f argocd/00-rbac-acm.yaml
```

Isso cria o `ClusterRole` **`openshift-gitops-acm-manager`** e o vincula às
ServiceAccounts `openshift-gitops-argocd-application-controller` (escrita) e
`openshift-gitops-argocd-server` (leitura, para a árvore de recursos na UI).

> **Por que este arquivo não está em `bootstrap/`**
>
> O Kubernetes impede escalonamento de privilégio: uma ServiceAccount não pode
> criar um `ClusterRole` com permissões que ela mesma não tem. Se o ArgoCD
> tentasse aplicar este manifesto, seria negado. Por isso ele fica fora do que o
> ArgoCD sincroniza.

Confirme antes de seguir:

```bash
./docs/cliente/scripts/verificar-rbac-acm.sh
```

Todas as linhas precisam sair `OK`.

> **Não use `oc auth can-i` para os subrecursos.** Três das permissões são
> subrecursos virtuais (`managedclusters/accept`, `managedclustersets/bind`,
> `managedclustersets/join`) que só existem dentro da `SubjectAccessReview` que
> os webhooks do ACM montam — não estão na API de discovery.
>
> ```bash
> # ISTO NÃO FUNCIONA e vai responder "no" mesmo com a permissão concedida:
> oc auth can-i update managedclusters.register.open-cluster-management.io/accept --as="$SA"
> ```
>
> O `kubectl` interpreta o que vem depois da barra como **nome** do objeto, não
> como subrecurso. E com `--subresource=accept` o restmapper resolve
> `managedclusters` para o grupo real `cluster.open-cluster-management.io`, nunca
> para `register.open-cluster-management.io`, que é sintético. O script acima
> monta a `SubjectAccessReview` exatamente como o webhook.

Para os recursos normais, o `oc auth can-i` funciona:

```bash
SA=system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller

oc auth can-i patch  managedclustersets.cluster.open-cluster-management.io          --as="$SA"
oc auth can-i create channels.apps.open-cluster-management.io -n cluster-gitops-repo --as="$SA"
oc auth can-i create clusterdeployments.hive.openshift.io -n default                --as="$SA"
```

### Se preferir o caminho curto

Alguns ambientes simplesmente dão `cluster-admin` ao ArgoCD:

```bash
oc adm policy add-cluster-role-to-user cluster-admin \
  -z openshift-gitops-argocd-application-controller -n openshift-gitops
```

Funciona, mas dá ao ArgoCD poder total sobre o hub. O `ClusterRole` acima cobre
exatamente o que este repositório usa — prefira ele.

### Se o `can-i` continuar dando `no` depois de aplicar

O operador do OpenShift GitOps só concede permissões de escopo de cluster às
instâncias listadas em `ARGOCD_CLUSTER_CONFIG_NAMESPACES`:

```bash
oc get subscription -n openshift-operators openshift-gitops-operator \
  -o jsonpath='{.spec.config.env}' | python3 -m json.tool
```

`openshift-gitops` precisa constar da lista. Se não constar, o `ClusterRoleBinding`
acima pode ser sobrescrito pelo operador — inclua o namespace e aguarde o
reinício do controlador.

## 1.7 Aplicar o root — uma única vez

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
