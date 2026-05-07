# Repositório de Infraestrutura de cluster gerenciados pelo Red Hat ACM através de GitOps.

Neste repositório está a definição de um OpenShift GitOps para importação e orquestração de clusters no Red Hat Advanced Cluster Management for Kubernetes.

<!-- readme-tree start -->
```
.
├── .github
│   └── workflows
│       └── readme-tree.yaml
├── .gitignore
├── README.md
├── argocd
│   ├── root-apps.yaml
│   └── root-clusters.yaml
├── bootstrap
│   ├── 00-namespaces.yaml
│   ├── app-set-import.yaml
│   ├── channel.yaml
│   ├── cluster-set-binding.yaml
│   ├── cluster-set.yaml
│   └── main-placement.yaml
├── charts
│   ├── cluster-deploy
│   │   └── templates
│   │       ├── addon-config.yaml
│   │       ├── cluster-provision.yaml
│   │       └── managed-cluster.yaml
│   └── import-cluster
│       ├── Chart.yaml
│       └── templates
│           ├── 00-namespace.yaml
│           ├── 01-external-secret-kubeconfig.yaml
│           ├── 02-managed-cluster.yaml
│           └── placement.yaml
├── clusters
│   └── aro-cluster-teste
│       ├── rosahcp-qa
│       │   └── values.yaml
│       └── values.yaml
├── gitops-workflow.md
├── policies
│   ├── enforce-gitops-labels.yaml
│   └── pci-compliance-policy.yaml
├── tree.bak
└── workloads
    ├── checkout-frontend-api-appset.yaml
    └── pagamentos-api-appset.yaml

15 directories, 27 files
```
<!-- readme-tree end -->
