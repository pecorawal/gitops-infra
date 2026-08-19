# 2. Provisionar o cluster

## 2.1 Criar o diretório do cluster

O nome do diretório **precisa** ser igual ao valor de `clusterName`.

```bash
cp -r clusters/azr-cliente-dev-01 clusters/azr-cliente-prod-01
$EDITOR clusters/azr-cliente-prod-01/values.yaml
```

## 2.2 Preencher o bloco `provision`

Todo campo `<PREENCHER>` precisa de valor. Os que costumam dar trabalho:

| Campo | Onde achar |
|---|---|
| `provision.credentials.sourceSecret` | `oc get secret -A -l cluster.open-cluster-management.io/type=azr` |
| `provision.imageSetRef` | `oc get clusterimageset` |
| `provision.azure.baseDomainResourceGroupName` | RG da Azure DNS Zone pública |
| `provision.azure.networkResourceGroupName` | `az network vnet show -n <vnet> -g <rg> --query resourceGroup -o tsv` |
| `provision.azure.controlPlaneSubnet` / `computeSubnet` | `az network vnet subnet list --vnet-name <vnet> -g <rg> -o table` |
| `provision.networking.machineNetwork` | `az network vnet show -n <vnet> -g <rg> --query addressSpace.addressPrefixes -o tsv` |

Sobre a topologia escolhida:

- `publish: Internal` — API e ingress default só respondem dentro da VNet.
  Para acessar o cluster você precisa estar na VNet (VPN, ExpressRoute ou bastion).
- `outboundType: UserDefinedRouting` — a saída para internet passa pela sua rota.
  Use `Loadbalancer` se a subnet não tiver UDR configurado.

## 2.3 Escolher o ManagedClusterSet pelo `env`

Os ManagedClusterSets **`pro`** e **`non-pro`** já existem no ACM. Este
repositório **não os cria** — de propósito, para que um `prune` do ArgoCD nunca
possa apagar um agrupamento de clusters de produção. O que o `values.yaml`
decide é em qual deles o cluster entra, a partir de `labels.env`:

```yaml
clusterSets:
  default: non-pro           # usado quando labels.env não consta no mapa
  byEnv:
    prod: pro                # <ambiente>: <nome do ManagedClusterSet no ACM>
    pro: pro
    non-prod: non-pro
    non-pro: non-pro
    dev: non-pro
    qa: non-pro
    hml: non-pro

clusterSet: ""               # escape hatch: preenchido, ignora o mapeamento

labels:
  env: "dev"                 # <-- é isto que decide
```

À **esquerda** do mapa fica o valor de `labels.env` (o ambiente); à **direita**,
o nome do `ManagedClusterSet` como ele existe no ACM. Os dois não precisam
coincidir — aqui `env: prod` leva ao set chamado `pro`.

Resolução, em ordem:

| # | Condição | Resultado |
|---|---|---|
| 1 | `clusterSet` preenchido | usa esse valor, ignora o resto |
| 2 | `labels.env` consta em `clusterSets.byEnv` | usa o mapeamento |
| 3 | caso contrário | usa `clusterSets.default` |
| 4 | nada resolveu | **a renderização falha** |

O passo 4 é deliberado. Um `ManagedCluster` sem a label de clusterset não entra
em nenhuma `Placement`, logo não é registrado no ArgoCD e todo o day-2 fica sem
destino — um erro silencioso que só apareceria 40 minutos depois, com o cluster
já provisionado e cobrando na Azure. Melhor falhar no `helm template`.

Conferir antes de commitar:

```bash
helm template t charts/azure-ipi-cluster -f clusters/<cluster>/values.yaml \
  --set provision.enabled=true | grep clusterset
```

E depois, no hub:

```bash
oc get managedcluster --show-labels | grep clusterset
oc get managedclusterset
```

### Se os nomes dos sets forem outros

```bash
oc get managedclusterset
```

Se o seu ACM usa nomes diferentes de `pro` / `non-pro`, mude em **três**
lugares:

1. `clusterSets.byEnv` e `clusterSets.default` em `clusters/<cluster>/values.yaml`
2. `bootstrap/03-cluster-set-bindings.yaml`, que vincula os sets ao namespace
   `openshift-gitops`
3. `bootstrap/04-placements-por-clusterset.yaml`, no campo `spec.clusterSets`

O vínculo é obrigatório: sem o `ManagedClusterSetBinding`, a `Placement`
`all-managed-clusters` não enxerga os clusters do set, o `GitOpsCluster` não os
registra no ArgoCD e nenhuma Application de day-2 encontra destino.

> Também são criadas as Placements `pro-clusters` e `non-pro-clusters`
> (`bootstrap/04-placements-por-clusterset.yaml`), úteis para segmentar ACM
> Policies e ApplicationSets de workload por ambiente. A Placement
> `all-managed-clusters` continua cobrindo os dois sets — é ela que o
> `GitOpsCluster` consome.

## 2.4 Ligar o interruptor e commitar

```yaml
provision:
  enabled: true      # <-- aqui
```

```bash
git add clusters/azr-cliente-prod-01/values.yaml
git commit -m "novo cluster azr-cliente-prod-01"
git push origin cliente
```

**Não é preciso criar o namespace nem copiar credencial.** O chart cria o
namespace e dois `ExternalSecret` que materializam a Credential compartilhada do
ACM neste namespace, já nos formatos que o Hive exige — ver
[1.4](01-pre-requisitos.md#14-liberar-a-cópia-automática-da-credential).

> Se você deixar algum `<PREENCHER>` para trás, o `helm template` falha listando
> exatamente quais campos faltam, antes de qualquer coisa ser aplicada.

Vale rodar **antes** de commitar — pega os dois erros mais comuns sem envolver o
cluster:

```bash
./docs/cliente/scripts/diagnosticar.sh <nome-do-cluster>
```

## 2.5 O que acontece

1. O `ApplicationSet` detecta o novo `values.yaml` e cria `bundle-azr-cliente-prod-01`.
2. O bundle emite `provision-azr-cliente-prod-01`.
3. Essa Application aplica no hub, em ordem de wave:
   - o Namespace do cluster (`-5`);
   - os dois `ExternalSecret` que copiam a Credential do ACM (`-3`);
   - o Secret `<cluster>-install-config` (`-1`) — o manifesto do `openshift-install`;
   - o `ClusterDeployment` (`0`) — dispara o Hive;
   - o `MachinePool` de workers (`1`);
   - o `ManagedCluster` e o `KlusterletAddonConfig` (`2`).
4. O Hive sobe um Job de instalação e roda o `openshift-install` (~40 min).
5. Terminado, o ACM importa o cluster automaticamente (não há kubeconfig manual —
   isso só existe para clusters *importados*, em `charts/import-cluster`).
6. O `GitOpsCluster` vê a label `apps.open-cluster-management.io/replicate-to-argocd=true`
   e registra o cluster como destino no ArgoCD.

## 2.6 Acompanhar

```bash
export CLUSTER=azr-cliente-prod-01

# as credenciais foram materializadas?
oc get externalsecret,secret -n "$CLUSTER"

# estado geral
oc get clusterdeployment -n "$CLUSTER" -w

# logs do instalador
oc logs -f -n "$CLUSTER" -l hive.openshift.io/job-type=provision -c hive

# importação no ACM
oc get managedcluster "$CLUSTER"

# registro no ArgoCD (é isto que habilita o day-2)
oc get secret -n openshift-gitops -l argocd.argoproj.io/secret-type=cluster
```

`PROVISIONSTATUS` deve chegar a `Provisioned` e o `ManagedCluster` a
`JOINED=True / AVAILABLE=True`.

## 2.7 Credenciais do cluster novo

```bash
oc get secret -n "$CLUSTER" "${CLUSTER}-admin-password" \
  -o jsonpath='{.data.password}' | base64 -d; echo
oc get secret -n "$CLUSTER" "${CLUSTER}-admin-kubeconfig" \
  -o jsonpath='{.data.kubeconfig}' | base64 -d > ~/.kube/"$CLUSTER"
```

## 2.8 Escalar depois

Mude `provision.compute.replicas` e commite — o Hive reconcilia o `MachinePool`.

➡️ [3. Day-2: ingress, DNS e certificados](03-day2-ingress-dns-certs.md)
