# Repositório de Infraestrutura de cluster gerenciados pelo Red Hat ACM através de GitOps.

Neste repositório está a definição de um OpenShift GitOps para importação e orquestração de clusters no Red Hat Advanced Cluster Management for Kubernetes.

## Branch `cliente` — provisionamento de OpenShift IPI na Azure

Esta branch entrega o fluxo completo, dirigido por **um único `values.yaml` por cluster**:

1. **Provisionamento** — cluster OpenShift IPI na Azure (BYO VNet, privado) via Hive/ACM
2. **IngressControllers** — um privado (LB interno) e um público (LB externo), com admissão de rota por label
3. **ExternalDNS** — uma instância para a Azure Private DNS Zone e outra para a Azure DNS Zone pública
4. **cert-manager** — ClusterIssuers (ACME/Azure DNS e CA interna) e os certificados dos ingress e das aplicações

```bash
oc apply -f argocd/root-cliente.yaml      # uma única vez
cp -r clusters/azr-cliente-dev-01 clusters/<seu-cluster>
# preencher os <PREENCHER>, virar os enabled: true, commitar
```

📖 **Guia completo: [`docs/cliente/`](docs/cliente/00-visao-geral.md)**

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

<!-- readme-tree start -->
```
.
├── .github
│   └── workflows
│       └── readme-tree.yaml
├── argocd
│   ├── root-apps.yaml
│   ├── root-cliente.yaml
│   └── root-clusters.yaml
├── bootstrap
│   ├── 00-namespaces.yaml
│   ├── 01-gitops-cluster.yaml
│   ├── 02-appset-cliente.yaml
│   ├── app-set-import.yaml
│   ├── channel.yaml
│   ├── cluster-set-binding.yaml
│   ├── cluster-set.yaml
│   └── main-placement.yaml
├── charts
│   ├── azure-ipi-cluster
│   │   ├── templates
│   │   │   ├── 00-namespace.yaml
│   │   │   ├── 01-install-config-secret.yaml
│   │   │   ├── 02-clusterdeployment.yaml
│   │   │   ├── 03-machinepool-worker.yaml
│   │   │   ├── 04-managedcluster.yaml
│   │   │   ├── 05-klusterletaddonconfig.yaml
│   │   │   └── _installconfig.tpl
│   │   ├── Chart.yaml
│   │   └── values.yaml
│   ├── cert-manager-config
│   │   ├── templates
│   │   │   ├── 10-clusterissuer-selfsigned.yaml
│   │   │   ├── 11-clusterissuer-internal-ca.yaml
│   │   │   ├── 12-clusterissuer-letsencrypt.yaml
│   │   │   ├── 20-certificate-ingress-private.yaml
│   │   │   ├── 21-certificate-ingress-public.yaml
│   │   │   └── 30-certificates-apps.yaml
│   │   ├── Chart.yaml
│   │   └── values.yaml
│   ├── cluster-bundle
│   │   ├── templates
│   │   │   ├── 00-provision-app.yaml
│   │   │   ├── 10-operators-app.yaml
│   │   │   ├── 20-cert-manager-app.yaml
│   │   │   ├── 30-ingress-app.yaml
│   │   │   ├── 40-external-dns-app.yaml
│   │   │   └── _helpers.tpl
│   │   ├── Chart.yaml
│   │   └── values.yaml
│   ├── cluster-operators
│   │   ├── templates
│   │   │   ├── 00-namespaces.yaml
│   │   │   ├── 10-cert-manager-operator.yaml
│   │   │   └── 20-external-dns-operator.yaml
│   │   ├── Chart.yaml
│   │   └── values.yaml
│   ├── external-dns-config
│   │   ├── templates
│   │   │   ├── 00-azure-config-secret.yaml
│   │   │   ├── 10-externaldns-private.yaml
│   │   │   ├── 20-externaldns-public.yaml
│   │   │   └── _externaldns.tpl
│   │   ├── Chart.yaml
│   │   └── values.yaml
│   ├── import-cluster
│   │   ├── templates
│   │   │   ├── 00-namespace.yaml
│   │   │   ├── 01-external-secret-kubeconfig.yaml
│   │   │   ├── 02-managed-cluster.yaml
│   │   │   └── placement.yaml
│   │   └── Chart.yaml
│   └── ingress-controllers
│       ├── templates
│       │   ├── 00-default-route-selector.yaml
│       │   ├── 10-ingresscontroller-private.yaml
│       │   ├── 20-ingresscontroller-public.yaml
│       │   └── _ingresscontroller.tpl
│       ├── Chart.yaml
│       └── values.yaml
├── clusters
│   └── azr-cliente-dev-01
│       └── values.yaml
├── docs
│   └── cliente
│       ├── scripts
│       │   └── criar-secrets-day2.sh
│       ├── 00-visao-geral.md
│       ├── 01-pre-requisitos.md
│       ├── 02-provisionar-cluster.md
│       ├── 03-day2-ingress-dns-certs.md
│       └── 04-troubleshooting.md
├── imports
│   └── rosaqa
│       └── values.yaml
├── policies
│   ├── enforce-gitops-labels.yaml
│   └── pci-compliance-policy.yaml
├── workloads
│   ├── checkout-frontend-api-appset.yaml
│   └── pagamentos-api-appset.yaml
├── .gitignore
├── README.md
└── gitops-workflow.md

28 directories, 74 files
```
<!-- readme-tree end -->
