# 4. Troubleshooting

## Operator recusado: "AllNamespaces InstallModeType not supported"

Um `OperatorGroup` **sem** `spec.targetNamespaces` significa modo
**AllNamespaces**. Operadores que só suportam `OwnNamespace` são recusados pelo
OLM com essa mensagem, e a `Subscription` fica sem CSV.

Era o caso do **ExternalDNS Operator** (o cert-manager já vinha com
`targetNamespaces` e por isso subia normalmente). Corrigido no chart:

```yaml
spec:
  targetNamespaces:
    - external-dns-operator
  upgradeStrategy: Default
```

O escopo restrito não limita nada aqui: os operandos e os Secrets `azure.json`
ficam todos em `external-dns-operator`, e o CR `ExternalDNS` é **cluster-scoped**.

Verificar:

```bash
oc get operatorgroup -A -o custom-columns=\
NS:.metadata.namespace,NOME:.metadata.name,ALVOS:.spec.targetNamespaces

oc get subscription -n external-dns-operator -o yaml | grep -A10 conditions
oc get csv -n external-dns-operator
```

Se a `Subscription` já estiver travada, o OperatorGroup corrigido não é aplicado
sozinho — remova a `Subscription` para o OLM reavaliar:

```bash
oc delete subscription external-dns-operator -n external-dns-operator
# o ArgoCD recria na próxima sincronização
```

Ao instalar um operador novo (`05-estender.md`, 5.1), consulte os install modes
suportados antes de decidir o escopo:

```bash
oc get packagemanifest <pacote> -n openshift-marketplace \
  -o jsonpath='{range .status.channels[*].currentCSVDesc.installModes[*]}{.type}={.supported}{"\n"}{end}'
```

## "could not unmarshal InstallConfig: error converting YAML to JSON"

O `install-config.yaml` gerado saiu com YAML inválido. Veja exatamente o que o
chart produziu, com numeração de linha para casar com a mensagem de erro:

```bash
helm template x charts/azure-ipi-cluster -f clusters/<cluster>/values.yaml \
  | python3 -c '
import sys, yaml
for d in yaml.safe_load_all(sys.stdin):
    if d and d.get("kind") == "Secret" and "install-config.yaml" in d.get("stringData", {}):
        ic = d["stringData"]["install-config.yaml"]
        for i, l in enumerate(ic.split("\n"), 1):
            print("%3d| %s" % (i, l))
        yaml.safe_load(ic)
        print(">>> install-config e YAML valido")
'
```

### Causa mais comum: lista onde o chart espera escalar

`did not find expected ',' or ']'` é o parser topando com um `[`. Acontecia
quando `clusterNetwork`, `machineNetwork` ou `serviceNetwork` eram preenchidos no
formato nativo do install-config (lista) em vez de escalar — o Go interpolava a
estrutura como texto e produzia `- cidr: [map[cidr:10.0.0.0/16]]`.

**Os dois formatos passaram a funcionar**, então isto não deve mais ocorrer:

```yaml
# forma curta
networking:
  clusterNetwork: "10.128.0.0/14"
  hostPrefix: 23
  machineNetwork: "10.0.0.0/16"
  serviceNetwork: "172.30.0.0/16"

# forma do install-config -- equivalente
networking:
  clusterNetwork:
    - cidr: 10.128.0.0/14
      hostPrefix: 23
  machineNetwork:
    - cidr: 10.0.0.0/16
  serviceNetwork:
    - 172.30.0.0/16
```

Se ainda falhar, o comando acima aponta a linha. Suspeitos: valor com `:` ou `#`
sem aspas, ou uma tabulação no lugar de espaços no `values.yaml`.

### Depois de corrigir

O Hive não relê o Secret de install-config sozinho num provisionamento que já
falhou. Siga o roteiro de recriação em
[2.8](02-provisionar-cluster.md#28-descomissionar-um-cluster): pausar o ArgoCD,
apagar o `ClusterDeployment`, esperar o deprovision, e só então recriar.

## `clusterdeploymentvalidators` — "Required value: must specify secrets for Azure access"

```
admission webhook "clusterdeploymentvalidators.admission.hive.openshift.io" denied the request:
ClusterDeployment "kildes9002" is invalid:
  spec.platform.azure.credentialsSecretRef.name: Required value: must specify secrets for Azure access
  spec.provisioning.sshPrivateKeySecretRef.name: Required value: must specify a name for the ssh private key secret
```

**Não é sobre o conteúdo do Secret.** É sobre o manifesto: o chart renderizou os
dois `name:` **vazios**, e o Hive recusa `...SecretRef` presente sem nome.

```yaml
credentialsSecretRef:
  name: ""          # <- é disto que o webhook reclama
```

Verifique o que o chart produz:

```bash
helm template x charts/azure-ipi-cluster -f clusters/<cluster>/values.yaml \
  | grep -A2 -E 'credentialsSecretRef|sshPrivateKeySecretRef|pullSecretRef'
```

Deve sair `<cluster>-azure-creds` e `<cluster>-pull-secret`. Se sair vazio:

| Causa | Como confirmar |
|---|---|
| `clusterName` vazio ou ausente no values | `grep '^clusterName:' clusters/<cluster>/values.yaml` |
| Bloco `provision.credentials` ausente (values de uma versão anterior) | `grep -A3 '  credentials:' clusters/<cluster>/values.yaml` |
| **O ArgoCD está renderizando um chart mais antigo que o values** | veja abaixo |

O terceiro é o mais traiçoeiro: se o `helm template` local acerta e o ArgoCD
erra, os dois estão em revisões diferentes. Charts anteriores liam
`provision.credentialsSecret`, chave que não existe mais — e uma chave inexistente
renderiza como string vazia, sem erro.

```bash
oc get applications.argoproj.io <app> -n openshift-gitops \
  -o jsonpath='revision desejada: {.spec.source.targetRevision}{"\n"}revision sincronizada: {.status.sync.revision}{"\n"}'
git log --oneline -1 origin/cliente
```

Se a revisão sincronizada for antiga, force o refresh:

```bash
oc annotate applications.argoproj.io <app> -n openshift-gitops \
  argocd.argoproj.io/refresh=hard --overwrite
```

O chart agora **falha na renderização** com mensagem explícita nesse caso, em vez
de emitir vazio e deixar o webhook do Hive reclamar de longe.

### E se a Credential não tiver chave SSH

O webhook também recusa `sshPrivateKeySecretRef` presente com nome vazio. Se você
não tem (ou não quer) acesso SSH aos nós, omita o bloco inteiro:

```yaml
provision:
  credentials:
    sshPrivateKey: false
```

### `copySshKey` × `sshPrivateKey`

Confusão comum, porque os nomes se parecem:

| Valor | Vale para | O que faz |
|---|---|---|
| `copySshKey` | **só** `mode: externalSecret` | inclui `ssh-privatekey` no `ExternalSecret` gerado. **Ignorado** em `mode: existing` |
| `sshPrivateKey` | os **dois** modos | emite ou omite o bloco `sshPrivateKeySecretRef` no `ClusterDeployment` |

Em `mode: existing`, quem copia a chave é o `preparar-credenciais.sh`. Confirme
que ela chegou:

```bash
oc get secret <cluster>-azure-creds -n <cluster> \
  -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'
```

Devem aparecer `osServicePrincipal.json` e `ssh-privatekey`. Se a segunda não
estiver lá, a Credential do ACM não tem chave SSH — use `sshPrivateKey: false`
ou adicione a chave à Credential no console do ACM.

## O namespace é destruído exatamente quando eu sincronizo

Sintoma preciso: o namespace fica de pé por horas, com as credenciais dentro; no
instante em que a Application sincroniza, ele começa a ser destruído e o
provisionamento não anda.

**Não é o ArgoCD.** Um sync manual só executa `apply`; ele não emite `delete`
para um objeto que está no estado desejado. Quem apaga é um **controlador
reagindo** a algo que o sync criou.

### O suspeito: o `ManagedCluster`

No ACM, o namespace de mesmo nome do cluster **pertence ao ciclo de vida do
`ManagedCluster`**. O `managedcluster-import-controller` é dono dele e o apaga
quando o `ManagedCluster` é rejeitado, perde `hubAcceptsClient`, ou entra em
detach. O chart cria o `ManagedCluster` na wave 2 — depois do Namespace (`-5`) e
do `ClusterDeployment` (`0`). Daí a sequência observada.

A causa mais comum de rejeição neste repo é RBAC: sem `update` em
`managedclusters/accept` (grupo sintético `register.open-cluster-management.io`),
o webhook recusa `hubAcceptsClient: true`.

```bash
./docs/cliente/scripts/verificar-rbac-acm.sh
```

### Bissecar em um sync

`provision.acmImport.enabled: false` faz o chart emitir **só os objetos do
Hive**, deixando o namespace fora do alcance do controlador do ACM:

```yaml
provision:
  acmImport:
    enabled: false
```

| Emitido | `acmImport: true` | `acmImport: false` |
|---|---|---|
| `Namespace`, `Secret`, `ClusterDeployment`, `MachinePool` | sim | sim |
| `ManagedCluster`, `KlusterletAddonConfig` | sim | **não** |

Commite, sincronize e observe:

```bash
oc get namespace <cluster> -w
```

| Resultado | Conclusão |
|---|---|
| Namespace **sobrevive** e o Hive começa a provisionar | Confirmado: era o ACM reagindo ao `ManagedCluster`. Corrija o RBAC e volte `acmImport` para `true`. |
| Namespace **ainda é destruído** | Não é o ACM. Veja quem emitiu o delete, abaixo. |

> Lembre de voltar `acmImport` para `true` depois. Sem o `ManagedCluster` o
> cluster não é importado no ACM nem registrado no ArgoCD, e nenhuma Application
> de day-2 encontra destino.

### Ver quem emitiu o delete

```bash
# eventos do namespace e do ManagedCluster, em ordem
oc get events -A --sort-by=.lastTimestamp \
  | grep -Ei '<cluster>|managedcluster' | tail -30

# o que o ACM diz do ManagedCluster
oc get managedcluster <cluster> -o yaml | grep -A30 'conditions:'

# logs do controlador que é dono do namespace
oc logs -n multicluster-engine -l app=managedcluster-import-controller-v2 --tail=100 \
  | grep -i '<cluster>'
```

## Isolar o provisionamento do bundle (diagnóstico)

Quando não se consegue determinar quem está mexendo no namespace, vale eliminar
camadas. `argocd/provision-standalone.yaml` substitui a cadeia

```
ApplicationSet cliente-clusters -> bundle-<cluster> -> provision-<cluster>
```

por **uma** Application aplicada à mão, que por construção **não consegue apagar
nada**: sem `syncPolicy.automated`, sem `prune`, sem `selfHeal` e sem
`resources-finalizer`.

```bash
# 1. desligue a esteira normal, para as duas não brigarem pelos mesmos objetos
oc get applications.argoproj.io -n openshift-gitops \
  -o custom-columns=NOME:.metadata.name,FINALIZERS:.metadata.finalizers
#    se alguma provision-* tiver resources-finalizer, remova ANTES de apagar,
#    senão a deleção cascateia e o Hive destrói o cluster na Azure
oc delete applicationsets.argoproj.io cliente-clusters -n openshift-gitops --ignore-not-found
oc delete applications.argoproj.io bundle-<cluster> provision-<cluster> \
  -n openshift-gitops --ignore-not-found

# 2. recrie as credenciais (o passo 1 pode ter levado o namespace junto)
./docs/cliente/scripts/preparar-credenciais.sh <cluster>

# 3. aplique a Application avulsa
sed 's/<CLUSTER>/<cluster>/g' argocd/provision-standalone.yaml | oc apply -f -

# 4. sincronize MANUALMENTE (pela console, ou:)
oc patch applications.argoproj.io provision-standalone-<cluster> -n openshift-gitops \
  --type=merge -p '{"operation":{"sync":{"revision":"cliente"}}}'

# 5. acompanhe
oc get applications.argoproj.io provision-standalone-<cluster> -n openshift-gitops \
  -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}'
oc get namespace <cluster> -w
```

### Como ler o resultado

| O que acontece | Conclusão |
|---|---|
| Namespace criado e **permanece** | O culpado estava na cadeia acima. O suspeito é o `prune` do bundle quando o chart renderiza vazio — ou seja, `provision.enabled: false` no values. |
| Namespace **continua sumindo** | Não é o bundle nem o ApplicationSet. Procure fora do ArgoCD: outro operador, ou uma `Policy` do ACM com `remediationAction: enforce` e `complianceType: mustnothave`. |
| Nada é aplicado, sem erro | O chart renderizou vazio: `provision.enabled` continua `false`. Confirme com `helm template x charts/azure-ipi-cluster -f clusters/<cluster>/values.yaml` |
| Erro de comparação | A mensagem do passo 5 diz qual. `no matches for kind ExternalSecret` = `mode: externalSecret` sem o ESO. |

Se o namespace continuar sumindo, veja quem o apagou:

```bash
oc get events -A --field-selector involvedObject.name=<cluster> --sort-by=.lastTimestamp
oc get policies.policy.open-cluster-management.io -A
```

### Voltar ao normal

```bash
oc delete applications.argoproj.io provision-standalone-<cluster> -n openshift-gitops
oc apply -f argocd/root-cliente.yaml
```

## `oc get application` diz NotFound, mas a console mostra o objeto

O nome curto `application` é **ambíguo** neste cluster. O ACM instala o CRD
`applications.app.k8s.io` (SIG Apps), e o OpenShift GitOps instala
`applications.argoproj.io`. Quando há empate, o `oc` resolve pela ordem do
discovery — e costuma cair no `app.k8s.io`:

```
Error from server (NotFound): applications.app.k8s.io "provision-x" not found
```

O objeto existe; você consultou o recurso errado. Use sempre o nome qualificado:

```bash
oc get applications.argoproj.io -A
oc get applicationsets.argoproj.io -A
oc delete applications.argoproj.io <nome> -n openshift-gitops
```

Conferir a ambiguidade:

```bash
oc api-resources | grep -i '^application'
```

Todos os comandos e scripts deste repositório usam o nome qualificado por causa
disso.

## Apaguei a Application raiz e nada foi embora

Comportamento esperado, não defeito. O ArgoCD só faz **deleção em cascata**
quando a Application tem o finalizer `resources-finalizer.argocd.argoproj.io`.
Nenhuma Application desta esteira tem — de propósito: a cascata da
`provision-<cluster>` destruiria o `ClusterDeployment`, e o Hive deprovisionaria
o cluster na Azure.

Sem o finalizer, apagar uma Application é uma deleção **não-cascata**: some o
objeto `Application`, ficam todos os recursos que ela gerenciava.

E há um agravante: o **`ApplicationSet cliente-clusters` continua vivo**. Ele é
quem gera os `bundle-<cluster>`, então recria tudo em segundos. Por isso a ordem
importa — o gerador tem que morrer primeiro.

### Limpeza ordenada

```bash
./docs/cliente/scripts/limpar-argocd.sh              # só lista (dry-run)
./docs/cliente/scripts/limpar-argocd.sh --confirmar  # executa
```

A ordem que ele segue:

| # | O quê | Por que nessa ordem |
|---|---|---|
| 1 | `ApplicationSet cliente-clusters` | senão ele recria os `bundle-*` |
| 2 | `provision-*`, `operators-*`, `certs-*`, `ingress-*`, `dns-*` | filhas antes dos pais |
| 3 | `bundle-*` | |
| 4 | `Application cliente-bootstrap` | a raiz |
| 5 | `GitOpsCluster`, bindings, placements, `Channel`, `ClusterSecretStore` | o que vinha de `bootstrap/` |

**O que o script deliberadamente não toca:** `ClusterDeployment`,
`ManagedCluster`, `MachinePool`, `ManagedClusterSet` e os namespaces dos
clusters. Apagar um `ClusterDeployment` faz o Hive **destruir o cluster na
Azure**, e isso nunca deve ser efeito colateral de "resetar o ArgoCD". Os
clusters continuam de pé e são readotados quando você reaplica o root.

Para descomissionar de verdade, é o procedimento explícito de
[2.8](02-provisionar-cluster.md#28-descomissionar-um-cluster).

### Recomeçar

```bash
oc apply -f argocd/00-rbac-acm.yaml
oc apply -f argocd/root-cliente.yaml
```

### Se uma Application ficar presa

Quase sempre é finalizer de uma versão anterior do chart. **Confira antes de
forçar:**

```bash
oc get applications.argoproj.io <nome> -n openshift-gitops -o jsonpath='{.metadata.finalizers}{"\n"}'
```

Se aparecer `resources-finalizer.argocd.argoproj.io`, remover o finalizer faz o
objeto sumir **sem** disparar cascata — que é justamente o que você quer aqui:

```bash
oc patch applications.argoproj.io <nome> -n openshift-gitops \
  --type=merge -p '{"metadata":{"finalizers":null}}'
```

> Não faça isso em uma Application que você pretende manter: sem o finalizer o
> ArgoCD perde o vínculo de limpeza dela.

## "Resource /Namespace/&lt;cluster&gt; is missing, it might have been deleted"

Essa mensagem do ArgoCD significa **"declarado no Git, ausente no cluster"**. Ela
não diz se o objeto foi apagado ou se nunca chegou a ser criado — e os dois casos
têm causas bem diferentes. Descubra qual é:

```bash
# existe? está terminando?
oc get namespace <cluster> -o jsonpath='{.status.phase} {.metadata.deletionTimestamp}{"\n"}' 2>&1

# alguém apagou? (o evento fica ~1h)
oc get events -A --field-selector reason=Killing,involvedObject.name=<cluster> 2>/dev/null

# o ArgoCD registrou prune/delete no histórico?
oc get applications.argoproj.io provision-<cluster> -n openshift-gitops \
  -o jsonpath='{.status.operationState.message}{"\n"}'
```

### Se nunca foi criado

A sincronização está falhando antes de chegar na wave `-5`. Rode o diagnóstico —
as causas mais comuns são `mode: externalSecret` sem o ESO, `provision.enabled:
false` e `<PREENCHER>` restante:

```bash
./docs/cliente/scripts/diagnosticar.sh <cluster>
```

### Se foi apagado — era este defeito, corrigido agora

Até o commit anterior, a Application `provision-<cluster>` carregava
`resources-finalizer.argocd.argoproj.io`. A cadeia era:

1. `bundle-<cluster>` sincroniza com `prune: true`;
2. se o bundle deixasse de emitir `provision-<cluster>` — `provision.enabled`
   voltando a `false`, uma edição no values, um erro de renderização — o ArgoCD
   **prunava** essa Application;
3. apagar uma Application **com** `resources-finalizer` dispara **deleção em
   cascata** de tudo que ela gerencia: Namespace, ClusterDeployment, MachinePool,
   ManagedCluster;
4. o Hive, ao ver o `ClusterDeployment` sumir, roda um job de **deprovision** que
   destrói o cluster na Azure.

O `Prune=false` que o Namespace já tinha **não protege disso**. São duas opções
diferentes, e essa é a distinção que faltava:

| Sync option | Protege de |
|---|---|
| `Prune=false` | remoção quando o objeto sai do estado desejado, **durante um sync** |
| `Delete=false` | remoção na **deleção em cascata** da Application |

**Correção aplicada:**

- `resources-finalizer` removido de `provision-<cluster>`. O pior caso agora é
  orfandade — a Application some, o cluster continua de pé — o que se recupera
  reaplicando o values. Antes, o pior caso era perder o cluster.
- `Prune=false,Delete=false` em Namespace, ClusterDeployment, MachinePool,
  ManagedCluster e KlusterletAddonConfig.
- Novo `provision.preserveOnDelete`, que passa `spec.preserveOnDelete: true` ao
  `ClusterDeployment`: mesmo apagado, o Hive não destrói a infraestrutura na
  Azure. Camada extra, opcional.

Se o namespace já foi destruído, recrie as credenciais e deixe o ArgoCD refazer:

```bash
./docs/cliente/scripts/preparar-credenciais.sh <cluster>
oc annotate applications.argoproj.io provision-<cluster> -n openshift-gitops \
  argocd.argoproj.io/refresh=hard --overwrite
```

Se o cluster chegou a existir na Azure e foi deprovisionado, não há o que
recuperar — o provisionamento recomeça do zero.

### Se o namespace está preso em `Terminating`

```bash
oc get namespace <cluster> -o jsonpath='{.spec.finalizers}{"\n"}'
oc api-resources --verbs=list --namespaced -o name \
  | xargs -n1 oc get -n <cluster> --no-headers --ignore-not-found 2>/dev/null | head
```

Quase sempre é um `ClusterDeployment` com o finalizer do Hive esperando o job de
deprovision terminar. Acompanhe antes de forçar:

```bash
oc logs -n <cluster> -l hive.openshift.io/job-type=deprovision -f
```

## Comecei por aqui: o cluster não sai do lugar

```bash
./docs/cliente/scripts/diagnosticar.sh <nome-do-cluster>
```

Percorre a cadeia inteira e diz onde ela parou:

```
ApplicationSet -> bundle-<cluster> -> provision-<cluster> -> Namespace
  -> ExternalSecrets -> ClusterDeployment -> ManagedCluster -> registro no ArgoCD
```

As causas que respondem pela maioria dos "não cria nem o namespace", em ordem
de frequência:

### 1. `mode: externalSecret` sem o External Secrets Operator

```bash
oc get crd externalsecrets.external-secrets.io
```

Se não existir e o values estiver com `mode: externalSecret`, **é esta a causa**.
O ArgoCD não consegue nem comparar o estado desejado:

```
Failed to compare desired state to live state: ...
  no matches for kind "ExternalSecret" in version "external-secrets.io/v1"
```

A Application inteira vai a `ComparisonError` e **nada** é aplicado — nem o
`Namespace`, que está no mesmo chart. Daí o "fica parado e não cria nem o
namespace".

Correção:

```yaml
provision:
  credentials:
    mode: existing
```

```bash
./docs/cliente/scripts/preparar-credenciais.sh <cluster>
git commit -am "credenciais em modo existing" && git push origin cliente
```

### 2. `provision.enabled` continua `false`

De longe a mais comum. Com o interruptor em `false` o chart **não emite objeto
nenhum** — nem a Application filha, nem o Namespace. E não há erro: o
`bundle-<cluster>` fica verde, com zero recursos, o que parece sucesso.

```bash
grep -A1 '^provision:' clusters/<cluster>/values.yaml
```

```yaml
provision:
  enabled: true      # <-- sem isto, nada acontece
```

Confirme sem sair da sua máquina — saída vazia significa que nada seria aplicado:

```bash
helm template x charts/cluster-bundle -f clusters/<cluster>/values.yaml
```

### 3. Sobrou algum `<PREENCHER>`

Aí a renderização **falha de propósito**, e o Namespace faz parte do mesmo chart
— por isso nem ele é criado:

```
Cluster "meu-cluster-01": 6 valor(es) ainda por preencher em clusters/meu-cluster-01/values.yaml:
  - provision.azure.baseDomainResourceGroupName
  - provision.azure.computeSubnet
  - provision.azure.controlPlaneSubnet
  - provision.azure.networkResourceGroupName
  - provision.credentials.sourceSecret
  - provision.networking.machineNetwork
```

Na interface do ArgoCD isso aparece como `ComparisonError` em
`provision-<cluster>`, e a mensagem fica escondida em `.status.conditions`:

```bash
oc get applications.argoproj.io provision-<cluster> -n openshift-gitops \
  -o jsonpath='{.status.conditions}' | python3 -m json.tool
```

Mais rápido é reproduzir localmente:

```bash
helm template x charts/azure-ipi-cluster -f clusters/<cluster>/values.yaml
```

### 4. O nome do diretório não bate com `clusterName`

O ApplicationSet nomeia a Application pelo **diretório** (`bundle-{{path.basename}}`),
mas os charts usam `clusterName` para namespace e objetos. Se divergirem, você
procura um namespace com um nome e ele é criado com outro.

```bash
basename $(dirname clusters/<cluster>/values.yaml)
grep '^clusterName:' clusters/<cluster>/values.yaml
```

### 5. O commit não está na branch que o generator lê

```bash
oc get applicationsets.argoproj.io cliente-clusters -n openshift-gitops \
  -o jsonpath='{.spec.generators[0].git.revision}{"\n"}'
git log --oneline -1 origin/cliente
```

O generator lê `clusters/*/values.yaml` da branch `cliente`. Um commit em `main`
não é enxergado.

### 6. RBAC

```bash
oc auth can-i create namespaces \
  --as=system:serviceaccount:openshift-gitops:openshift-gitops-argocd-application-controller
```

Se der `no`, é a seção abaixo.

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
oc annotate applications.argoproj.io cliente-bootstrap -n openshift-gitops \
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
    sandbox: non-pro       # 2. mapeie o env novo
# ou
clusterSet: "non-pro"      # 3. force o set, ignorando o mapa
```

## O ApplicationSet não gerou nada

```bash
oc get applicationsets.argoproj.io cliente-clusters -n openshift-gitops -o yaml | grep -A20 status
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

## O ClusterDeployment não acha as credenciais (`mode: existing`)

```bash
oc get secret -n <cluster> | grep -E 'azure-creds|pull-secret'
oc get clusterdeployment <cluster> -n <cluster> -o yaml | grep -A20 conditions
```

Se os Secrets não estiverem lá, rode o preparo — é idempotente:

```bash
./docs/cliente/scripts/preparar-credenciais.sh <cluster>
```

O Hive só lê Secrets do namespace do `ClusterDeployment`; um Secret na
namespace da Credential compartilhada não serve.

Rodar de novo também é como se propaga a **rotação do Service Principal**: o
script sobrescreve os Secrets a partir da Credential atual do ACM.

## As credenciais não aparecem no namespace do cluster (`mode: externalSecret`)

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
oc get applications.argoproj.io -n openshift-gitops | grep -E 'bundle-|provision-|operators-|certs-|ingress-|dns-'
oc get clusterdeployment -A
oc get managedcluster

# Cluster gerenciado
oc get csv -A | grep -E 'cert-manager|external-dns'
oc get clusterissuer
oc get certificate -A
oc get ingresscontroller -n openshift-ingress-operator
oc get externaldns
```
