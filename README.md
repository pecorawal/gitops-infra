# Repositório de Infraestrutura de cluster gerenciados pelo Red Hat ACM através de GitOps.

Neste repositório está a definição de um OpenShift GitOps para importação e orquestração de clusters no Red Hat Advanced Cluster Management for Kubernetes.

## Branch `cliente` — provisionamento de OpenShift IPI na Azure

Esta branch entrega o fluxo completo, dirigido por **um único `values.yaml` por cluster**:

1. **Provisionamento** — cluster OpenShift IPI na Azure (BYO VNet, privado) via Hive/ACM, a partir de uma **única Credential do ACM** compartilhada por todos os clusters
2. **IngressControllers** — privado (LB interno, `pri.cgibs.gov.br`) e público (LB externo, `cgibs.gov.br`), separados pela label `ingress-type`; o `default` fica reservado às aplicações internas do OpenShift
3. **ExternalDNS** — uma instância para a Azure Private DNS Zone e outra para a Azure DNS Zone pública
4. **cert-manager** — `ClusterIssuer` ACME/DNS01 emitindo os wildcards `*.cgibs.gov.br` e `*.pri.cgibs.gov.br`
5. **NSG rule** — CronJob idempotente que sincroniza a inbound rule do NSG da Azure com o IP público do Load Balancer do IngressController (TCP 80/443 do Internet)

```bash
oc apply -f argocd/00-rbac-acm.yaml       # RBAC do ArgoCD sobre ACM/Hive (cluster-admin)
oc apply -f argocd/root-cliente.yaml      # uma única vez

cp -r clusters/azr-cliente-dev-01 clusters/<seu-cluster>
./docs/cliente/scripts/preparar-credenciais.sh <seu-cluster>   # namespace + credenciais
# preencher os <PREENCHER>, virar os enabled: true, commitar

./docs/cliente/scripts/diagnosticar.sh <seu-cluster>           # se algo não andar
./docs/cliente/scripts/limpar-argocd.sh                        # zerar o ArgoCD (dry-run)
```

📖 **Guia completo: [`docs/cliente/`](docs/cliente/00-visao-geral.md)** — inclui
[como adicionar novos operadores, manifestos e camadas](docs/cliente/05-estender.md).

| Diretório | Papel |
|---|---|
| `clusters/` | um `values.yaml` por cluster **provisionado** (IPI Azure) |
| `imports/` | um `values.yaml` por cluster **importado** (ROSA/ARO/GCP já existente) |
| `charts/cluster-bundle/` | o app-of-apps: emite as Applications de cada camada |
| `charts/azure-ipi-cluster/` | Hive `ClusterDeployment` + `install-config` + ACM (roda no hub) |
| `charts/cluster-operators/` | cert-manager e ExternalDNS Operator (roda no cluster gerenciado) |
| `charts/cert-manager-config/` | ClusterIssuers e Certificates |
| `charts/ingress-controllers/` | IngressController privado e público |
| `charts/external-dns-config/` | instâncias do ExternalDNS por zona |
| `charts/nsg-rule/` | CronJob que sincroniza a inbound rule do NSG com o IP do LB do ingress |
| `charts/cluster-autoscaling/` | ClusterAutoscaler + MachineAutoscaler (autoscaling do pool worker) |

<!-- readme-tree start -->
```
├── .github
│   └── workflows
│       └── readme-tree.yaml
├── .gitignore
├── README.md
├── argocd
│   ├── 00-rbac-acm.yaml
│   ├── provision-standalone.yaml
│   ├── root-apps.yaml
│   ├── root-cliente.yaml
│   └── root-clusters.yaml
├── bootstrap
│   ├── 00-namespaces.yaml
│   ├── 01-gitops-cluster.yaml
│   ├── 02-appset-cliente.yaml
│   ├── 03-cluster-set-bindings.yaml
│   ├── 04-placements-por-clusterset.yaml
│   ├── 05-acm-credentials-store.yaml
│   ├── app-set-import.yaml
│   ├── channel.yaml
│   ├── cluster-set-binding.yaml
│   ├── cluster-set.yaml
│   └── main-placement.yaml
├── charts
│   ├── azure-ipi-cluster
│   │   ├── Chart.yaml
│   │   ├── templates
│   │   │   ├── 00-namespace.yaml
│   │   │   ├── 01-externalsecret-credentials.yaml
│   │   │   ├── 02-install-config-secret.yaml
│   │   │   ├── 03-clusterdeployment.yaml
│   │   │   ├── 04-machinepool-worker.yaml
│   │   │   ├── 05-managedcluster.yaml
│   │   │   ├── 06-klusterletaddonconfig.yaml
│   │   │   ├── _clusterset.tpl
│   │   │   ├── _credentials.tpl
│   │   │   ├── _installconfig.tpl
│   │   │   └── _validate.tpl
│   │   └── values.yaml
│   ├── cert-manager-config
│   │   ├── Chart.yaml
│   │   ├── templates
│   │   │   ├── 10-clusterissuer-selfsigned.yaml
│   │   │   ├── 11-clusterissuer-internal-ca.yaml
│   │   │   ├── 12-clusterissuer-letsencrypt.yaml
│   │   │   ├── 20-certificate-ingress-private.yaml
│   │   │   ├── 21-certificate-ingress-public.yaml
│   │   │   └── 30-certificates-apps.yaml
│   │   └── values.yaml
│   ├── cluster-autoscaling
│   │   ├── Chart.yaml
│   │   ├── templates
│   │   │   ├── 10-clusterautoscaler.yaml
│   │   │   └── 20-machineautoscaler.yaml
│   │   └── values.yaml
│   ├── cluster-bundle
│   │   ├── Chart.yaml
│   │   ├── templates
│   │   │   ├── 00-provision-app.yaml
│   │   │   ├── 10-operators-app.yaml
│   │   │   ├── 20-cert-manager-app.yaml
│   │   │   ├── 30-ingress-app.yaml
│   │   │   ├── 40-external-dns-app.yaml
│   │   │   ├── 50-nsg-app.yaml
│   │   │   ├── 60-autoscaling-app.yaml
│   │   │   └── _helpers.tpl
│   │   └── values.yaml
│   ├── cluster-operators
│   │   ├── Chart.yaml
│   │   ├── templates
│   │   │   ├── 00-namespaces.yaml
│   │   │   ├── 10-cert-manager-operator.yaml
│   │   │   └── 20-external-dns-operator.yaml
│   │   └── values.yaml
│   ├── external-dns-config
│   │   ├── Chart.yaml
│   │   ├── templates
│   │   │   ├── 00-azure-config-secret-private.yaml
│   │   │   ├── 01-azure-config-secret-public.yaml
│   │   │   ├── 10-externaldns-private.yaml
│   │   │   └── 20-externaldns-public.yaml
│   │   └── values.yaml
│   ├── import-cluster
│   │   ├── Chart.yaml
│   │   └── templates
│   │       ├── 00-namespace.yaml
│   │       ├── 01-external-secret-kubeconfig.yaml
│   │       ├── 02-managed-cluster.yaml
│   │       └── placement.yaml
│   ├── ingress-controllers
│   │   ├── Chart.yaml
│   │   ├── templates
│   │   │   ├── 00-default-route-selector.yaml
│   │   │   ├── 10-ingresscontroller-private.yaml
│   │   │   └── 20-ingresscontroller-public.yaml
│   │   └── values.yaml
│   └── nsg-rule
│       ├── Chart.yaml
│       ├── templates
│       │   ├── 00-namespace.yaml
│       │   ├── 10-serviceaccount.yaml
│       │   ├── 11-role.yaml
│       │   ├── 12-rolebinding.yaml
│       │   ├── 20-configmap-script.yaml
│       │   ├── 30-cronjob.yaml
│       │   └── _validate.tpl
│       └── values.yaml
├── clusters
│   └── azr-cliente-dev-01
│       └── values.yaml
├── docs
│   └── cliente
│       ├── 00-visao-geral.md
│       ├── 01-pre-requisitos.md
│       ├── 02-provisionar-cluster.md
│       ├── 03-day2-ingress-dns-certs.md
│       ├── 04-troubleshooting.md
│       ├── 05-estender.md
│       └── scripts
│           ├── criar-secrets-day2.sh
│           ├── diagnosticar.sh
│           ├── limpar-argocd.sh
│           ├── preparar-credenciais.sh
│           └── verificar-rbac-acm.sh
├── gitops-workflow.md
├── imports
│   └── rosaqa
│       └── values.yaml
├── policies
│   ├── enforce-gitops-labels.yaml
│   └── pci-compliance-policy.yaml
└── workloads
    ├── checkout-frontend-api-appset.yaml
    └── pagamentos-api-appset.yaml
```
<!-- readme-tree end -->
