# 5. Estender: novos operadores, manifestos e camadas

Este documento responde a pergunta prática: **"quero instalar um operador novo /
aplicar um manifesto novo no cluster — onde eu mexo?"**

Antes de escolher, use esta tabela:

| O que você quer | Onde mexer | Precisa de nova Application? |
|---|---|---|
| Instalar um operador via OLM | `charts/cluster-operators/templates/` | Não |
| Ajustar um recurso já gerenciado (IC, ExternalDNS, Certificate) | o chart correspondente | Não |
| Aplicar 1–3 manifestos avulsos, do mesmo domínio de um chart existente | o chart correspondente | Não |
| Uma capacidade nova e independente (logging, storage, backup, service mesh) | **novo chart** + nova Application | Sim |
| Um recurso no **hub** e não no cluster gerenciado | `charts/azure-ipi-cluster/` ou novo chart com destino hub | Depende |
| Uma aplicação de negócio | outro repositório (`workloads/`, `gitops-workloads-helm`) | Não |
| Um Secret que vem de fora do Git | `ExternalSecret` no chart + `ClusterSecretStore` no `bootstrap/` | Não |

Regra prática: **um chart por capacidade**. Se o recurso novo tem ciclo de vida
próprio (pode ser ligado/desligado sem afetar os outros), ele merece chart e
Application próprios.

---

## 5.1 Instalar um operador novo

Exemplo: **Loki / OpenShift Logging**.

### Passo 1 — adicionar o template

Crie `charts/cluster-operators/templates/30-logging-operator.yaml`:

```yaml
{{- if .Values.operators.enabled }}
{{- if .Values.operators.logging.enabled }}
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-logging
  annotations:
    argocd.argoproj.io/sync-wave: "-2"
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-logging
  namespace: openshift-logging
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  targetNamespaces:
    - openshift-logging
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-logging
  namespace: openshift-logging
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  name: cluster-logging
  channel: {{ .Values.operators.logging.channel }}
  source: {{ .Values.operators.logging.source }}
  sourceNamespace: {{ .Values.operators.logging.sourceNamespace }}
  installPlanApproval: {{ .Values.operators.logging.installPlanApproval }}
{{- end }}
{{- end }}
```

As sync-waves internas de `cluster-operators` são sempre as mesmas:
`Namespace: -2` → `OperatorGroup: -1` → `Subscription: 0`.

### Passo 2 — declarar os defaults

Em `charts/cluster-operators/values.yaml`:

```yaml
operators:
  logging:
    enabled: false
    channel: stable-6.2
    source: redhat-operators
    sourceNamespace: openshift-marketplace
    installPlanApproval: Automatic
```

Defaults **sempre `enabled: false`** — quem liga é o values do cluster.

### Passo 3 — expor no values do cluster

Em `clusters/<cluster>/values.yaml`, bloco `operators`:

```yaml
operators:
  enabled: true
  logging:
    enabled: true
    channel: stable-6.2
    source: redhat-operators
```

### Passo 4 — validar antes de commitar

```bash
helm template t charts/cluster-operators -f clusters/<cluster>/values.yaml \
  --set operators.enabled=true --set operators.logging.enabled=true
```

### Passo 5 — descobrir channel e nome do pacote

```bash
# no cluster gerenciado
oc get packagemanifest -n openshift-marketplace | grep -i logging
oc get packagemanifest cluster-logging -n openshift-marketplace \
  -o jsonpath='{range .status.channels[*]}{.name}{"\n"}{end}'
```

---

## 5.2 Adicionar um manifesto a um chart existente

Quando o recurso pertence ao mesmo domínio de um chart que já existe, é só mais
um arquivo em `templates/`.

Exemplo: um terceiro IngressController, para parceiros.

`charts/ingress-controllers/templates/30-ingresscontroller-partner.yaml`:

```yaml
{{- if and .Values.ingress.enabled .Values.ingress.partner.enabled }}
{{ include "ingress-controllers.controller" (dict "ic" .Values.ingress.partner "wave" "0") }}
{{- end }}
```

O helper `ingress-controllers.controller` já cobre scope, routeSelector,
`defaultCertificate` e `dnsManagementPolicy` — basta declarar o bloco
`ingress.partner` no values, no mesmo formato de `private`/`public`.

**Não esqueça:** ao criar um valor novo para a label, adicione-o a
`ingress.default.reservedValues`, senão o IngressController `default` continuará
admitindo essas rotas também.

```yaml
ingress:
  default:
    reservedValues: [public, private, partner]
```

### Convenções ao criar templates

| Convenção | Por quê |
|---|---|
| Prefixo numérico no nome do arquivo (`30-...`) | ordem de leitura previsível |
| `{{- if .Values.<bloco>.enabled }}` em volta de tudo | o interruptor é o contrato do repo |
| `argocd.argoproj.io/sync-wave` em cada objeto | ordena dentro da Application |
| `SkipDryRunOnMissingResource=true` em CR de operador | o CRD só existe depois do operador subir |
| `ServerSideApply=true` ao alterar objeto de terceiros | não sequestra a posse do objeto |
| Comentário em pt-BR explicando o *porquê* | o repo é lido por quem não escreveu |

---

## 5.3 Criar uma camada nova (novo chart + nova Application)

Use quando a capacidade é independente. Exemplo: **backup com OADP**.

### Passo 1 — o chart

```
charts/backup-config/
├── Chart.yaml
├── values.yaml
└── templates/
    ├── 00-namespace.yaml
    └── 10-dataprotectionapplication.yaml
```

`Chart.yaml`:

```yaml
apiVersion: v2
name: backup-config
description: DataProtectionApplication (OADP) no cluster gerenciado
type: application
version: 0.1.0
```

`values.yaml` — só defaults, tudo desligado:

```yaml
backup:
  enabled: false
  storageAccount: ""
  container: ""
```

### Passo 2 — a Application no app-of-apps

`charts/cluster-bundle/templates/50-backup-app.yaml`:

```yaml
{{- if .Values.backup.enabled }}
# WAVE 50 -- SPOKE. Backup/restore com OADP.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: backup-{{ .Values.clusterName }}
  namespace: {{ .Values.global.argoNamespace }}
  annotations:
    argocd.argoproj.io/sync-wave: "50"
spec:
  project: {{ .Values.global.project }}
  source:
    {{- include "bundle.source" (dict "root" . "chart" "backup-config") | nindent 4 }}
  destination:
    name: {{ .Values.clusterName }}      # spoke; use server: https://kubernetes.default.svc para o hub
    namespace: openshift-adp
  {{- include "bundle.syncPolicy" . | nindent 2 }}
{{- end }}
```

Os dois helpers de `charts/cluster-bundle/templates/_helpers.tpl` cuidam do resto:

- **`bundle.source`** — aponta para `charts/<nome>` no mesmo repo/revisão e injeta
  o **mesmo** `clusters/<cluster>/values.yaml`. É por isso que todo chart novo
  enxerga automaticamente os valores do cluster.
- **`bundle.syncPolicy`** — `automated` + `retry` com backoff, necessário porque as
  Applications de spoke nascem apontando para um cluster que ainda não existe.

### Passo 3 — o interruptor no bundle

Em `charts/cluster-bundle/values.yaml`:

```yaml
backup:
  enabled: false
```

### Passo 4 — o bloco no values do cluster

```yaml
# ═══════════════ 6. BACKUP (OADP) ═══════════════
backup:
  enabled: false
  storageAccount: "<PREENCHER>"
  container: "<PREENCHER>"
```

### Passo 5 — escolher a wave

| Wave | Camada |
|---|---|
| 0 | provisionamento (hub) |
| 10 | operators |
| 20 | cert-manager (issuers e certificados) |
| 30 | ingress controllers |
| 40 | external-dns |
| **50+** | **camadas novas** |

Se a camada nova depender de um operador, o operador entra em
`charts/cluster-operators` (wave 10) e os CRs dele na wave nova. Sempre múltiplos
de 10, deixando espaço para inserções futuras.

### Passo 6 — validar

```bash
helm lint charts/backup-config
helm template t charts/backup-config -f clusters/<cluster>/values.yaml --set backup.enabled=true
helm template t charts/cluster-bundle -f clusters/<cluster>/values.yaml --set backup.enabled=true
```

---

## 5.4 Adicionar algo no HUB, não no cluster gerenciado

A diferença está só no `destination` da Application:

```yaml
  destination:
    server: https://kubernetes.default.svc   # HUB
    namespace: <namespace>
```

contra:

```yaml
  destination:
    name: {{ .Values.clusterName }}          # CLUSTER GERENCIADO (spoke)
    namespace: <namespace>
```

Recursos do hub que valem lembrar: `Policy` do ACM (`policies/`), `Placement`,
`ManagedClusterSet`, `ClusterCurator` (hooks de pré/pós-instalação e upgrade).

Objetos de bootstrap que valem para **todos** os clusters — e não para um só —
vão em `bootstrap/`, não em um chart: eles são aplicados diretamente pela
Application `cliente-bootstrap` com `directory.recurse: true`, sem Helm.

---

## 5.5 Fluxo de trabalho para qualquer mudança

```bash
# 1. branch a partir de cliente
git checkout cliente && git pull
git checkout -b feature/oadp

# 2. editar chart + values

# 3. validar TUDO localmente (nenhum cluster envolvido)
for c in charts/*/; do helm lint "$c"; done

for c in cluster-bundle azure-ipi-cluster cluster-operators \
         cert-manager-config ingress-controllers external-dns-config backup-config; do
  helm template t charts/$c -f clusters/<cluster>/values.yaml >/dev/null \
    && echo "OK $c" || echo "FALHOU $c"
done

# 4. conferir o inventário com tudo ligado
helm template t charts/cluster-bundle -f clusters/<cluster>/values.yaml \
  --set provision.enabled=true --set operators.enabled=true \
  --set certManager.enabled=true --set ingress.enabled=true \
  --set externalDNS.enabled=true --set backup.enabled=true \
  | grep -E '^(kind|  name):'

# 5. o teste do "modo escuta": sem nada ligado, nada é emitido
helm template t charts/cluster-bundle -f clusters/<cluster>/values.yaml | wc -l   # -> 0

# 6. commit e PR
git push -u origin feature/oadp
```

Depois do merge em `cliente`, o ArgoCD sincroniza sozinho. Para forçar:

```bash
oc annotate application bundle-<cluster> -n openshift-gitops \
  argocd.argoproj.io/refresh=hard --overwrite
```

---

## 5.6 Adicionar um ManagedClusterSet novo

Se surgir um terceiro agrupamento (ex.: `dr`), são três lugares:

1. crie o `ManagedClusterSet` no ACM (console ou `oc`) — **não** versione o
   objeto, para que um `prune` não possa apagá-lo;
2. `bootstrap/03-cluster-set-bindings.yaml`: mais um `ManagedClusterSetBinding`
   para `openshift-gitops`;
3. `clusters/<cluster>/values.yaml`: mais uma entrada em `clusterSets.byEnv`.

Opcionalmente, mais uma `Placement` em
`bootstrap/04-placements-por-clusterset.yaml` para segmentar policies e workloads.

## 5.7 Erros comuns ao estender

| Sintoma | Causa |
|---|---|
| `helm template` falha com "ManagedClusterSet indefinido" | `labels.env` não está em `clusterSets.byEnv` e `clusterSets.default` está vazio |
| Cluster provisionado mas invisível no ArgoCD | falta o `ManagedClusterSetBinding` do set em `openshift-gitops` |
| Application nova não aparece | faltou o interruptor em `charts/cluster-bundle/values.yaml`, ou o `if` no template |
| `no matches for kind ... in version ...` | CR aplicado antes do operador; falta `SkipDryRunOnMissingResource=true` ou wave maior |
| ArgoCD fica revertendo o objeto | outro controlador escreve nele; adicione `ignoreDifferences` na Application |
| `values.yaml` não chega ao chart novo | o `bundle.source` já cuida disso; verifique se o chart está em `charts/<nome>` (dois níveis, por causa do `../../`) |
| Rota nova indo para o router errado | valor de label novo não foi adicionado a `ingress.default.reservedValues` |
| Application em `Unknown` / `Cluster not found` | o spoke ainda não foi registrado — ver [troubleshooting](04-troubleshooting.md) |
