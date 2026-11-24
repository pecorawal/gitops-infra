# Branch `devops` — esteira Pipelines + esteira GitOps com dois clusters

Demo de **DevOps simples**: o desenvolvedor faz commit, o **OpenShift Pipelines no hub** testa e constrói a
imagem, publica no **Quay do cluster gerenciado** e grava a nova tag no Git; o **Argo CD do hub**, que conhece o
cluster gerenciado graças ao **ACM**, implanta lá. Ninguém roda `oc` no cluster de destino.

📖 **[Guion de la demo (ES)](docs/guion-demo.md)** · **[Métricas DORA](docs/kpis-devops.md)**

```
 desarrollador                 HUB  (ACM + OpenShift GitOps + OpenShift Pipelines)
     │ git push            ┌──────────────────────────────────────────────────────┐
     ▼                     │  Tekton (devops-ci)                                  │
 ┌────────┐   webhook      │   clone → npm test → buildah ──push──┐  update-gitops│
 │ GitHub │ ─────────────▶ │                                      │       │       │
 │ branch │ ◀──────────────┼──────── commit "tag: <sha>" ─────────┼───────┘       │
 │ devops │                │                                      │               │
 └────────┘ ──────────────▶│  Argo CD (openshift-gitops)          │               │
              lee el Git   │   ApplicationSets dev / prod         │               │
                           │  ACM: GitOpsCluster · Policy Quay    │               │
                           └───────────────┬──────────────────────┼───────────────┘
                                           │ despliega            │
                           ┌───────────────▼──────────────────────▼───────────────┐
                           │  CLUSTER GESTIONADO   (label devops=gerenciado)      │
                           │   Quay  ◀── pull ── pagamentos-dev  (auto-sync)       │
                           │         ◀── pull ── pagamentos-prod (sync manual)     │
                           └──────────────────────────────────────────────────────┘
```

```bash
vi devops/config.env                                     # QUAY_HOST, QUAY_ORG, CLUSTER_GERENCIADO, contextos
export QUAY_PUSH_USER=... QUAY_PUSH_TOKEN=... QUAY_PULL_USER=... QUAY_PULL_TOKEN=... GITHUB_TOKEN=...
./devops/scripts/preparar.sh tudo                        # placeholders, label, secrets, apply, webhook
oc create -f devops/pipeline/manual/pipelinerun.yaml     # build inicial → DEV
./devops/demo/etapa.sh promover && ./devops/demo/etapa.sh sync-prod   # PROD inicial

./devops/demo/etapa.sh 00|01|02|03|promover|drift|rollback|status      # a demo
./devops/kpis/coletar-kpis.sh                            # métricas DORA ao vivo
```

| Diretório | Papel | Onde roda |
|---|---|---|
| `app/` | `pagamentos-api` em Node.js sem dependências (página com versão/cor, `/health`, testes `node --test`) | build no hub |
| `pipeline/` | Namespace `devops-ci`, Tasks, Pipeline, Triggers (webhook) — `oc apply -k devops/pipeline` | hub |
| `pipeline/manual/` | PipelineRun manual (build inicial e plano B) | hub |
| `gitops/chart/` | Helm do app (Deployment, Service, Route) | cluster gerenciado |
| `gitops/values-*.yaml` | o que muda por ambiente; `tag:` de DEV é escrita pela pipeline | — |
| `gitops/argocd/` | ApplicationSets `pagamentos-dev` (auto-sync) e `pagamentos-prod` (manual) | hub |
| `argocd/root-devops.yaml` | aplicação raiz que sincroniza `gitops/argocd/` | hub |
| `acm/` | ClusterSetBindings, Placement + GitOpsCluster, Policy de acesso ao Quay (pull secret + CA) | hub → gerenciado |
| `demo/` | `etapa.sh` e as variações de `lib.js` de cada etapa | notebook |
| `kpis/` | coleta das métricas DORA | notebook |
| `scripts/preparar.sh` | preparação D-1 | notebook |

**Requisitos:** OpenShift ≥ 4.16 nos dois clusters; no hub ACM ≥ 2.11, OpenShift GitOps ≥ 1.12 e
OpenShift Pipelines ≥ 1.17 (Tasks `git-clone` e `buildah` em `openshift-pipelines`); Quay no cluster gerenciado
com uma organização, o repositório `pagamentos-api` e dois robot accounts (write e read).

**Próximo passo (fora do escopo desta demo):** a branch `seguranca` mostra como acrescentar o ACS a esta mesma
esteira — gate de imagem no build e admission controller no deploy.
