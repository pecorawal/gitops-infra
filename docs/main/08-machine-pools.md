# 8. Machine pools adicionais: novos tipos de máquina no cluster

Este documento responde: **"o cluster já tem os workers padrão; como eu crio um
grupo novo de máquinas — outro tamanho de VM, nós de infra, nós isolados — e
decido se ele escala sozinho?"**

A resposta curta: uma entrada em `machinePools.pools` no
`clusters/<cluster>/values.yaml`. Mais nada.

## 8.1 Como funciona

Num cluster provisionado pelo ACM, **quem manda nos MachineSets do cluster
gerenciado é o `MachinePool` do Hive, no hub**. É a mesma regra do pool worker
(ver [troubleshooting](04-troubleshooting.md#o-autoscaling-não-cria-nada-application-existe-cluster-não-escala)).
Por isso um grupo novo de máquinas não se cria aplicando `MachineSet` no spoke:
declara-se mais um `MachinePool`, e o Hive gera e reconcilia os MachineSets.

```
clusters/<cluster>/values.yaml
  machinePools.pools[]
        │
        └─► Application machinepools-<cluster>   (wave 5)   → charts/machine-pools  [HUB]
              │
              └─► MachinePool <cluster>-<pool>           namespace <cluster>, no hub
                    │  Hive
                    ▼
                  MachineSet <infraID>-<pool>-<região><zona>   um por zona   [SPOKE]
                    │
                    ├─► Machine → VM na Azure → Node (com as labels e taints do pool)
                    │
                    └─► MachineAutoscaler             só com autoscaling.enabled; criado pelo Hive
                          ▲
                          └── ClusterAutoscaler "default"   Application autoscale-<cluster> (wave 60)
```

| O quê | Onde fica | Quem cria |
|---|---|---|
| `MachinePool <cluster>-<pool>` | hub, namespace `<cluster>` | este chart |
| `MachineSet <infraID>-<pool>-<região><zona>` | spoke, `openshift-machine-api` | Hive |
| `MachineAutoscaler` (um por MachineSet) | spoke, `openshift-machine-api` | Hive, a partir de `spec.autoscaling` |
| `ClusterAutoscaler default` | spoke | Application `autoscale-<cluster>` |

O pool **worker** padrão não muda: continua em `provision.compute` e
`provision.machinePool`, gerenciado por `provision-<cluster>`.

## 8.2 O que o pool herda

Para não repetir (e não divergir), o pool adicional herda do bloco `provision`:

| Campo do MachinePool | Vem de | Pode sobrescrever no pool? |
|---|---|---|
| `networkResourceGroupName`, `virtualNetwork`, `computeSubnet` | `provision.azure` | não — mesma rede dos workers |
| `outboundType` | `provision.azure.outboundType` | não |
| `zones` | `provision.compute.zones` | sim, `zones:` |
| `osDisk.diskSizeGB`, `osDisk.diskType` | `provision.compute.osDisk` | sim, campo a campo |

A rede herdada não é detalhe: sem ela o Hive monta o MachineSet com a VNet que o
instalador **criaria** (`<infraID>-vnet`), e cada máquina falha com
`ResourceNotFound` — o mesmo problema descrito em
[troubleshooting](04-troubleshooting.md#máquina-nova-falha-com-resourcenotfound-virtualnetworksinfraid-vnet).

## 8.3 Criar um pool

### Passo 1 — cota da Azure

Cada família de VM tem cota própria de vCPU por região. Sem cota, o MachineSet é
criado e as máquinas ficam em `Failed` — nada falha no ArgoCD.

```bash
az vm list-usage -l <região> -o table | grep -i -E 'Family|Total Regional'
# ex: Standard ESv5 Family vCPUs   16   100
```

Conta mínima: `vCPUs da VM × maxReplicas` (ou `× replicas`).

### Passo 2 — o values

```yaml
machinePools:
  enabled: true
  pools:
    # tamanho fixo
    - name: infra
      type: Standard_D8s_v3
      osDisk:
        diskSizeGB: 256
      replicas: 3
      labels:
        node-role.kubernetes.io/infra: ""
      taints:
        - key: node-role.kubernetes.io/infra
          value: reserved
          effect: NoSchedule

    # escala sob demanda, a partir de zero
    - name: highmem
      type: Standard_E16s_v5
      autoscaling:
        enabled: true
        minReplicas: 0
        maxReplicas: 4
      labels:
        workload-type: highmem
      taints:
        - key: workload-type
          value: highmem
          effect: NoSchedule
```

| Campo | Obrigatório | Observação |
|---|---|---|
| `name` | sim | minúsculas, números e `-`; diferente do pool worker; **imutável** |
| `type` | sim | tamanho da VM; **imutável** |
| `replicas` | sim, sem autoscaling | `0` vale (pool vazio); ignorado com autoscaling |
| `autoscaling.enabled/minReplicas/maxReplicas` | não | min/max são **totais** do pool |
| `osDisk`, `zones` | não | herdados do worker; **imutáveis** |
| `labels` | não | vão para os **nós** |
| `taints` | não | `effect`: `NoSchedule`, `PreferNoSchedule` ou `NoExecute` |

### Passo 3 — validar antes de commitar

```bash
helm template <cluster> charts/machine-pools -f clusters/<cluster>/values.yaml
./docs/main/scripts/verificar-values.sh <cluster>
```

### Passo 4 — commitar e acompanhar

```bash
# HUB
oc get machinepools.hive.openshift.io -n <cluster>
oc get machinepools.hive.openshift.io <cluster>-<pool> -n <cluster> \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
oc get machinepools.hive.openshift.io <cluster>-<pool> -n <cluster> \
  -o jsonpath='{range .status.machineSets[*]}{.name} {.replicas}/{.readyReplicas} min={.minReplicas} max={.maxReplicas}{"\n"}{end}'

# SPOKE -- o Hive marca os MachineSets do pool com hive.openshift.io/machine-pool
oc get machineset -n openshift-machine-api -l hive.openshift.io/machine-pool=<pool>
oc get machines -n openshift-machine-api -o wide | grep -- -<pool>-
oc get nodes -l <label-do-pool>
```

A VM leva de 5 a 10 minutos até virar `Node` `Ready`.

> Não filtre as Machines por `machine.openshift.io/cluster-api-machine-type`: o
> Hive gera todo pool com o papel `worker`, então essa label vale `worker` em
> todos eles. O que distingue o pool é o nome do MachineSet e a label
> `hive.openshift.io/machine-pool`.

## 8.4 Autoscaling por pool

Basta `autoscaling.enabled: true` **no pool**. O bundle percebe e emite a
Application `autoscale-<cluster>` com o `ClusterAutoscaler` global — mesmo com o
bloco `autoscaling` (do worker) desligado. Cada chave liga uma coisa só:

| Interruptor | Efeito |
|---|---|
| `autoscaling.enabled` | autoscaling do pool **worker** + `ClusterAutoscaler` global |
| `machinePools.pools[].autoscaling.enabled` | autoscaling **daquele pool** + `ClusterAutoscaler` global |

Regras que valem igual para o worker:

- **`replicas` e `autoscaling` são mutuamente exclusivos** — o webhook do Hive
  recusa os dois. Com autoscaling, `replicas` é ignorado pelo chart.
- **min/max são totais do pool**, repartidos entre os MachineSets (um por zona).
  `minReplicas` precisa ser `0` ou `>=` número de zonas — o chart barra o resto.
- **`autoscaling.clusterAutoscaler.maxNodesTotal` conta todos os nós** do cluster:
  masters, workers e todos os pools. Chegou no teto, nenhum pool escala mais.
  Some os `maxReplicas` antes de ligar.
- **O autoscaler só sobe nó para pod `Pending` que caberia nele.** Com taint no
  pool, só os pods com a toleration contam — é o que mantém um pool caro (GPU,
  memória) parado em zero. Sem taint, o pool entra na disputa por **qualquer**
  pod pendente do cluster, junto com os workers.

```bash
# SPOKE
oc get clusterautoscaler default
oc get machineautoscaler -n openshift-machine-api | grep -- -<pool>-
oc -n openshift-machine-api logs deploy/cluster-autoscaler-default --tail=50
```

## 8.5 Levar as cargas para o pool

Pool com taint só recebe pod que tolera a taint **e** pede o nó:

```yaml
spec:
  nodeSelector:
    workload-type: highmem
  tolerations:
    - key: workload-type
      operator: Equal
      value: highmem
      effect: NoSchedule
```

Só a `toleration` **permite** o pod no pool, mas não o **obriga** a ir para lá.
Só o `nodeSelector`, sem a toleration, deixa o pod `Pending` para sempre.

Pool **sem** taint recebe qualquer pod do cluster, como um worker a mais.

> **Nós de infra.** Label `node-role.kubernetes.io/infra` e taint `reserved`
> seguem a convenção da documentação do OpenShift. Mover router, registry e
> monitoring para eles é configuração de cada componente (`nodePlacement` do
> IngressController, `config.imageregistry`, `cluster-monitoring-config`), feita
> nas camadas próprias, não neste chart.

## 8.6 Alterar um pool

| Campo | Mutável? | Como mudar |
|---|---|---|
| `replicas`, `autoscaling` | sim | edite e commite |
| `labels`, `taints` | sim | edite e commite — o Hive reaplica nos nós continuamente |
| `type`, `osDisk`, `zones` | **não** | pool novo com outro nome (abaixo) |
| `name` | **não** | pool novo com outro nome (abaixo) |

`spec.platform` do MachinePool é imutável: o webhook do Hive responde
`field is immutable`, a Application fica `OutOfSync` com erro, e nada muda no
cluster. Para trocar o tipo de VM:

1. acrescente um pool com nome novo (`highmem` → `highmem-v2`) e o tipo novo,
   commite e espere os nós ficarem `Ready`;
2. mova as cargas (os dois pools podem ter a mesma label e taint — os pods
   passam a caber nos dois);
3. remova o pool antigo, como abaixo.

## 8.7 Remover um pool

Tirar o pool da lista **não apaga nada**: o MachinePool leva
`Prune=false,Delete=false`. É de propósito — apagar um MachinePool faz o Hive
remover os MachineSets e **drenar os nós**, e isso não pode ser efeito colateral
de uma edição no values.

A ordem importa:

```bash
# 1. garanta que as cargas cabem em outro lugar (nodeSelector/tolerations)

# 2. tire a entrada de machinePools.pools e commite
#    a Application machinepools-<cluster> mostra o MachinePool como "requires pruning"

# 3. HUB -- só então apague
oc delete machinepools.hive.openshift.io <cluster>-<pool> -n <cluster>

# 4. SPOKE -- acompanhe a drenagem
oc get machines -n openshift-machine-api -w | grep -- -<pool>-
```

Se inverter os passos 2 e 3, o ArgoCD recria o MachinePool no próximo sync.

Para tirar o último pool, deixe também `machinePools.enabled: false`: a
Application some e o MachinePool continua no hub até o `oc delete`.

## 8.8 O que o chart barra no render

Todos viram erro na Application, antes de qualquer objeto ser aplicado:

| Erro | Por que barrar |
|---|---|
| `enabled: true` com `pools` vazio | nada seria criado, sem erro nenhum |
| placeholder `<MAIUSCULAS>` no pool | VM com nome literal de placeholder |
| rede de `provision.azure` vazia/placeholder | máquinas fora da VNet (`ResourceNotFound`) |
| `name` inválido, repetido ou igual ao worker | mesmo MachinePool disputado por duas Applications |
| nome da VM passaria de 64 caracteres | `InvalidParameter` da Azure, Machine em `Failed` |
| sem `type`, sem disco resolvido | webhook do Hive recusa |
| sem `replicas` e sem `autoscaling` | tamanho do pool implícito |
| `minReplicas > maxReplicas`, `0 < minReplicas < zonas` | webhook/Hive recusam |
| taint sem `key` ou com `effect` inválido | pool subiria **sem** a taint, aberto a qualquer pod |

> **Tamanho do nome.** A VM recebe o nome da Machine,
> `<infraID>-<pool>-<região><zona>-<xxxxx>`, e VM Linux na Azure aceita até 64
> caracteres. O `infraID` é o `clusterName` truncado em 21 + 6. Para
> `azr-main-dev-01` em `brazilsouth`, sobram **20 caracteres** para o nome do
> pool.

## 8.9 Problemas comuns

| Sintoma | Causa provável | Onde olhar |
|---|---|---|
| MachinePool existe, nenhum MachineSet no spoke | cluster ainda instalando, ou condição de erro no pool | `status.conditions` do MachinePool (8.3) |
| `field is immutable` no sync | mudou `type`, `osDisk` ou `zones` | pool novo com outro nome (8.6) |
| Machine `Failed` com `QuotaExceeded` / `OperationNotAllowed` | cota da família na região | `oc describe machine <m> -n openshift-machine-api`; `az vm list-usage` |
| Machine `Failed` com `SkuNotAvailable` | tipo de VM indisponível na zona | `az vm list-skus -l <região> --size <tipo> -o table`; ajuste `zones` (pool novo) |
| Machine `Failed` com `ResourceNotFound ... <infraID>-vnet` | rede não chegou ao MachinePool | `oc get machinepool ... -o jsonpath='{.spec.platform.azure}'` |
| Pool com autoscaling nunca sobe de 0 | nenhum pod `Pending` exige esse pool, ou `maxNodesTotal` atingido | logs do `cluster-autoscaler-default` (8.4) |
| Pods não vão para o pool | falta `nodeSelector` ou `toleration` | 8.5 |
| Qualquer pod cai no pool | pool sem taint | acrescente `taints` |
| Application `autoscale-<cluster>` não aparece | `machinePools.enabled` false, ou nenhum pool com `autoscaling.enabled: true` | `oc get cm bundle-<cluster>-info -n openshift-gitops -o yaml` |
