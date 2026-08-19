# 4. Troubleshooting

## "one or more synchronization tasks completed unsuccessfully" — `is forbidden`

O sintoma mais comum logo depois de aplicar `root-cliente.yaml`:

```
channels.apps.open-cluster-management.io is forbidden: User
  "system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller"
  cannot create resource "channels" in namespace "cluster-gitops-repo"

managedclustersets/bind.apps "global-clusters" is forbidden: user ... is not
  allowed to bind cluster set "global-clusters"

managedclustersets.cluster.open-cluster-management.io "global-clusters" is
  forbidden: User ... cannot patch resource "managedclustersets" at the cluster scope
```

**Causa:** o passo [1.6](01-pre-requisitos.md#16-dar-ao-argocd-permissão-sobre-as-apis-do-acm-e-do-hive)
não foi executado. A ServiceAccount do ArgoCD não tem RBAC para as APIs do ACM.

**Correção:**

```bash
oc apply -f argocd/00-rbac-acm.yaml
```

Depois force a re-sincronização (o ArgoCD já está tentando de novo com backoff,
mas isso acelera):

```bash
oc annotate application cliente-bootstrap -n openshift-gitops \
  argocd.argoproj.io/refresh=hard --overwrite
```

Note que os três erros são de naturezas diferentes e todos são cobertos pelo
mesmo `ClusterRole`:

| Erro | Regra que resolve |
|---|---|
| `cannot create resource "channels"` | `apiGroups: [apps.open-cluster-management.io]` |
| `not allowed to bind cluster set` | `resources: [managedclustersets/bind]`, verbo `create` |
| `cannot patch resource "managedclustersets"` | `resources: [managedclustersets]`, verbo `patch` |

O segundo não é um erro de RBAC comum: quem nega é o webhook
`managedclustersetbindingvalidators`, que faz um `SubjectAccessReview` no
subrecurso virtual `managedclustersets/bind`. Dar `patch` em `managedclustersets`
**não** basta — a regra do subrecurso é obrigatória.

### "managedclusters/accept continua sem update" — provavelmente é o comando

Se você checou com:

```bash
oc auth can-i update managedclusters.register.open-cluster-management.io/accept --as="$SA"
```

o `no` é **falso negativo**. Esse comando não checa o que você pensa:

1. o `kubectl` trata o que vem depois da `/` como **nome do objeto**, não como
   subrecurso — a checagem vira "posso dar update no ManagedCluster chamado
   `accept`?", que o `ClusterRole` de fato não permite;
2. com `--subresource=accept`, o restmapper resolve `managedclusters` para o
   grupo real `cluster.open-cluster-management.io` — mas o webhook checa o grupo
   **`register.open-cluster-management.io`**, que é sintético e não existe na API
   de discovery.

Use o script, que monta a `SubjectAccessReview` igual ao webhook:

```bash
./docs/cliente/scripts/verificar-rbac-acm.sh
```

Ou, na mão:

```bash
oc create -f - -o jsonpath='{.status.allowed}{"\n"}' <<'YAML'
apiVersion: authorization.k8s.io/v1
kind: SubjectAccessReview
spec:
  user: system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller
  groups:
    - system:serviceaccounts
    - system:serviceaccounts:openshift-gitops
    - system:authenticated
  resourceAttributes:
    group: register.open-cluster-management.io
    resource: managedclusters
    subresource: accept
    verb: update
YAML
```

Precisa imprimir `true`.

As três checagens que **só** funcionam por `SubjectAccessReview`:

| Grupo | Recurso | Subrecurso | Verbo | Exigido por |
|---|---|---|---|---|
| `register.open-cluster-management.io` | `managedclusters` | `accept` | `update` | `hubAcceptsClient: true` |
| `cluster.open-cluster-management.io` | `managedclustersets` | `bind` | `create` | `ManagedClusterSetBinding` |
| `cluster.open-cluster-management.io` | `managedclustersets` | `join` | `create` | label `clusterset` no `ManagedCluster` |

(Atributos conferidos em `open-cluster-management-io/ocm`,
`pkg/registration/webhook/v1/managedcluster_validating.go` e
`pkg/registration/webhook/v1beta2/managedclustersetbinding_validating.go`.)

Se a `SubjectAccessReview` realmente retornar `false`, aí sim é RBAC:

### O erro persiste depois de aplicar o RBAC

```bash
SA=system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller
oc auth can-i create managedclustersets.cluster.open-cluster-management.io/bind --as="$SA"
oc get clusterrolebinding openshift-gitops-acm-manager -o yaml
```

Se o `can-i` responde `no` com o binding presente, verifique
`ARGOCD_CLUSTER_CONFIG_NAMESPACES` no Subscription do operador — instâncias fora
dessa lista não recebem permissões de escopo de cluster e o operador pode
reconciliar por cima do binding.

### O `Channel` é mesmo necessário?

`bootstrap/channel.yaml` pertence ao modelo de aplicação por *subscription* do
ACM e **não é consumido por nada** neste fluxo, que é todo ArgoCD. Se você não
usa o modelo de subscription do ACM, pode remover `bootstrap/channel.yaml` e
`bootstrap/00-namespaces.yaml` da branch — um erro a menos e uma permissão a
menos. Foram mantidos por virem do fluxo original em `main`.


## As Applications de day-2 estão em erro "Cluster not found"

**Esperado** enquanto o cluster não terminou de ser provisionado e registrado.
Cada Application filha tem `retry` (5 tentativas, backoff até 10m) e se resolve
sozinha. Se persistir depois do cluster estar `Available`:

```bash
oc get gitopscluster -n openshift-gitops
oc get managedcluster <cluster> --show-labels | grep replicate-to-argocd
oc get secret -n openshift-gitops -l argocd.argoproj.io/secret-type=cluster
```

Sem `apps.open-cluster-management.io/replicate-to-argocd=true` no `ManagedCluster`,
o `GitOpsCluster` não cria o Secret e o ArgoCD não enxerga o cluster.

## O cluster subiu mas nunca aparece no ArgoCD (clusterset)

Depois de `GitOpsCluster` e label `replicate-to-argocd`, o terceiro motivo é o
`ManagedClusterSet`:

```bash
oc get managedcluster <cluster> --show-labels | tr ',' '\n' | grep clusterset
oc get managedclustersetbinding -n openshift-gitops
oc get placementdecision -n openshift-gitops -l cluster.open-cluster-management.io/placement=all-managed-clusters -o yaml
```

| Situação | Causa |
|---|---|
| label `clusterset` ausente | `helm template` foi renderizado antes do mapeamento existir |
| label aponta para um set inexistente | nome errado em `clusterSets.byEnv` — confira com `oc get managedclusterset` |
| set existe, mas sem `ManagedClusterSetBinding` em `openshift-gitops` | falta aplicar `bootstrap/03-cluster-set-bindings.yaml` |
| `PlacementDecision` vazia | a Placement não enxerga o set: é sempre um dos dois casos acima |

Uma Placement sem `spec.clusterSets` seleciona a partir de **todos** os sets
vinculados ao seu namespace. Se o binding não existe, o set é invisível para ela
— e o cluster nunca vira destino no ArgoCD.

## O `helm template` falha com "ManagedClusterSet indefinido"

```
ManagedClusterSet indefinido para o cluster "azr-cliente-prod-01".
  labels.env = "sandbox"
  clusterSets.byEnv nao tem essa chave e clusterSets.default esta vazio.
```

É proposital: sem clusterset o cluster seria provisionado e ficaria órfão do
ArgoCD. Escolha uma saída:

```yaml
labels:
  env: "prod"              # 1. use um env já mapeado
# ou
clusterSets:
  byEnv:
    sandbox: non-prod      # 2. mapeie o env novo
# ou
clusterSet: "non-prod"     # 3. force o set, ignorando o mapa
```

## O ApplicationSet não gerou nada

```bash
oc get applicationset cliente-clusters -n openshift-gitops -o yaml | grep -A20 status
oc logs -n openshift-gitops deploy/openshift-gitops-applicationset-controller
```

Confira: o arquivo é exatamente `clusters/<nome>/values.yaml`, o `revision` do
generator é `cliente` e a branch foi empurrada.

## Nada é aplicado mesmo com o bundle sincronizado

Provavelmente todos os `enabled` continuam `false`. Confirme localmente:

```bash
helm template x charts/cluster-bundle -f clusters/<cluster>/values.yaml
```

Saída vazia = nenhuma camada habilitada.

## As credenciais não aparecem no namespace do cluster

```bash
oc get externalsecret -n <cluster>
oc describe externalsecret <cluster>-azure-creds -n <cluster>
oc get clustersecretstore acm-credentials-hub -o yaml | grep -A5 conditions
oc logs -n <ns-do-eso> deploy/external-secrets -f
```

| `STATUS` do ExternalSecret | Causa |
|---|---|
| `SecretSyncedError` + `key not found` | `sourceSecret` não existe, ou está noutro namespace |
| `SecretSyncedError` + `forbidden` | o `Role` do passo 1.4 não cobre o namespace certo |
| `InvalidProviderConfig` no store | `remoteNamespace` / `caProvider.namespace` divergem do namespace real |
| nada acontece, sem evento | ESO não instalado: `oc get crd externalsecrets.external-secrets.io` |

Os quatro pontos `# <<< NAMESPACE` de `bootstrap/05-acm-credentials-store.yaml`
precisam apontar todos para o **mesmo** namespace, e ele precisa ser igual a
`provision.credentials.sourceNamespace` do values do cluster.

Confirme as chaves da Credential de origem — os nomes têm que bater com o que o
template espera (`osServicePrincipal.json`, `pullSecret`, `ssh-privatekey`):

```bash
oc get secret <credential> -n <ns> -o jsonpath='{.data}' | python3 -m json.tool | grep '":'
```

Se a Credential não tiver `ssh-privatekey`, use `copySshKey: false`.

## O ClusterDeployment reclama de secret ausente logo no início

Normal e transitório. O ArgoCD aplica o `ExternalSecret` (wave -3) e o
`ClusterDeployment` (wave 0) em sequência, mas quem materializa o Secret é o ESO,
de forma assíncrona. O Hive reconcilia sozinho assim que o Secret aparece —
questão de segundos. Só investigue se persistir:

```bash
oc get secret -n <cluster> | grep -E 'azure-creds|pull-secret'
```

## O provisionamento falha

```bash
oc get clusterdeployment <cluster> -n <cluster> -o yaml | grep -A30 conditions
oc get pods -n <cluster>
oc logs -n <cluster> -l hive.openshift.io/job-type=provision -c hive
```

Causas frequentes:

| Sintoma | Causa |
|---|---|
| `AuthenticationFailure` | Service Principal sem papel `Contributor`, ou secret expirado |
| erro de quota | cota de vCPU insuficiente na região |
| `subnet not found` | `controlPlaneSubnet`/`computeSubnet` errados, ou VNet noutro RG |
| timeout de bootstrap | `outboundType: UserDefinedRouting` sem rota de saída na subnet |
| `pull secret` inválido | passo 1.4 não executado, ou Secret sem `.dockerconfigjson` |

Para recomeçar do zero: `provision.enabled: false`, commite, espere o Hive limpar,
corrija os valores e volte para `true`.

## O ArgoCD fica revertendo o ClusterDeployment

O Hive escreve em `spec.installed` e `spec.clusterMetadata`. A Application de
provisionamento já traz `ignoreDifferences` para esses campos. Se apareceu campo
novo, adicione em `charts/cluster-bundle/templates/00-provision-app.yaml`.

## O Certificate fica em `False / DoesNotExist`

```bash
oc describe certificate <nome> -n <namespace>
oc get challenges -A
oc logs -n cert-manager deploy/cert-manager -f
```

- **Challenge parado em `pending`** — o Service Principal não tem
  `DNS Zone Contributor` na zona pública, ou `azuredns-config` está errado.
- **Wildcard privado (`*.pri.cgibs.gov.br`) falhando** — confirme que o
  subdomínio não está delegado publicamente:

  ```bash
  dig +short NS pri.cgibs.gov.br     # não deve retornar nada
  dig +short TXT _acme-challenge.pri.cgibs.gov.br
  ```

  O TXT precisa ser gravado na zona **pública** `cgibs.gov.br`. Se
  `pri.cgibs.gov.br` estiver delegado a outro servidor, o Let's Encrypt procura o
  TXT lá e não encontra.
- **`propagation check failed`** — em cluster privado, o cert-manager pode não
  alcançar os NS autoritativos. Configure nameservers recursivos no operator:

  ```bash
  oc patch certmanager cluster --type=merge -p \
    '{"spec":{"controllerConfig":{"overrideArgs":[
       "--dns01-recursive-nameservers=8.8.8.8:53",
       "--dns01-recursive-nameservers-only"]}}}'
  ```

- **Cota do Let's Encrypt** — 50 certificados por domínio por semana. Use o
  servidor de staging enquanto testa.

## O IngressController fica `Degraded`

```bash
oc get ingresscontroller <nome> -n openshift-ingress-operator -o yaml | grep -A30 conditions
oc get svc -n openshift-ingress
```

- **`SecretNotFound`** — o `Certificate` ainda não emitiu. É transitório: o
  IngressController se recupera sozinho quando o Secret aparece em `openshift-ingress`.
- **LB sem IP** — na Azure, o Internal LB precisa de subnet com espaço livre;
  confira também as quotas de Public IP para o LB externo.

## Uma Route foi para o router errado

```bash
oc get route <rota> -n <ns> -o jsonpath='{.status.ingress[*].routerName}'; echo
oc get route <rota> -n <ns> --show-labels
```

| `routerName` observado | Causa |
|---|---|
| `default` (esperava `private`) | label `ingress-type` ausente ou com valor errado |
| `default` **e** `private` | `ingress.default.isolateByLabel` está `false` |
| nenhum | o `domain` do IngressController não bate com o host da rota |

Lembre que `NotIn` casa também com Routes **sem** a label — por isso o que não
tiver `ingress-type: public|private` vai parar no `default`. É o comportamento
desejado, mas explica rotas "sumindo" para o default.

## Uma Route criada a partir de um Ingress não muda de router

A Route gerada recebe as labels do Ingress **na criação**. Alterações posteriores
só são reconciliadas com a anotação:

```yaml
annotations:
  route.openshift.io/reconcile-labels: "true"
```

Sem ela, trocar `ingress-type` no Ingress não move a Route. Verifique a Route
gerada, não o Ingress:

```bash
oc get route -n <ns> --show-labels
```

## O registro DNS não aparece na Azure

```bash
oc get externaldns <nome> -o yaml | grep -A20 status
oc logs -n external-dns-operator deploy/external-dns-<nome> -f
```

- **`Zone not found`** — o resource ID em `zoneId` está errado. Confirme com
  `az network private-dns zone show ... --query id -o tsv`.
- **`AuthorizationFailed`** — falta `Private DNS Zone Contributor` no SP.
- **Nenhuma rota processada** — `routerName` não bate com o nome do
  IngressController, ou o `domain` do filtro não corresponde ao host das rotas.

## Comandos de diagnóstico rápido

```bash
# Hub
oc get applications -n openshift-gitops | grep -E 'bundle-|provision-|operators-|certs-|ingress-|dns-'
oc get clusterdeployment -A
oc get managedcluster

# Cluster gerenciado
oc get csv -A | grep -E 'cert-manager|external-dns'
oc get clusterissuer
oc get certificate -A
oc get ingresscontroller -n openshift-ingress-operator
oc get externaldns
```
