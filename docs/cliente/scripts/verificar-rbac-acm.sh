#!/usr/bin/env bash
# =============================================================================
#  Verifica se a ServiceAccount do ArgoCD tem as permissoes que o ACM exige.
#
#  POR QUE ESTE SCRIPT EXISTE, EM VEZ DE "oc auth can-i"
#  ------------------------------------------------------------------------
#  Duas das permissoes sao SUBRECURSOS VIRTUAIS, checados por webhooks do ACM
#  via SubjectAccessReview -- eles nao existem na API de discovery:
#
#     register.open-cluster-management.io | managedclusters | accept | update
#     cluster.open-cluster-management.io  | managedclustersets | bind | create
#     cluster.open-cluster-management.io  | managedclustersets | join | create
#
#  "oc auth can-i update managedclusters.register.../accept" NAO funciona: o
#  kubectl interpreta o que vem depois da barra como NOME do objeto, nao como
#  subrecurso. E com "--subresource=accept" o restmapper resolve managedclusters
#  para o grupo cluster.open-cluster-management.io, nao para register... -- que
#  e um grupo sintetico, usado apenas na SubjectAccessReview.
#
#  Por isso este script monta a SubjectAccessReview exatamente como os webhooks
#  do OCM montam (pkg/registration/webhook/...).
#
#  Uso (como cluster-admin, no HUB):
#    ./docs/cliente/scripts/verificar-rbac-acm.sh
# =============================================================================
set -uo pipefail

NS="${NS:-openshift-gitops}"
SA_NAME="${SA_NAME:-openshift-gitops-argocd-application-controller}"
USER="system:serviceaccount:${NS}:${SA_NAME}"

echo "ServiceAccount: $USER"
echo

fail=0

sar() { # <descricao> <group> <resource> <subresource> <verb> [namespace]
  local desc="$1" group="$2" res="$3" sub="$4" verb="$5" ns="${6:-}"
  local out
  out=$(oc create -f - -o jsonpath='{.status.allowed}' 2>&1 <<YAML
apiVersion: authorization.k8s.io/v1
kind: SubjectAccessReview
spec:
  user: ${USER}
  groups:
    - system:serviceaccounts
    - system:serviceaccounts:${NS}
    - system:authenticated
  resourceAttributes:
    group: "${group}"
    resource: "${res}"
    subresource: "${sub}"
    verb: "${verb}"
$( [[ -n "$ns" ]] && echo "    namespace: \"${ns}\"" )
YAML
)
  if [[ "$out" == "true" ]]; then
    printf "  \033[32mOK    \033[0m %s\n" "$desc"
  else
    printf "  \033[31mNEGADO\033[0m %s\n" "$desc"
    fail=1
  fi
}

echo "--- subrecursos virtuais (checados pelos webhooks do ACM) ---"
sar "update managedclusters/accept    [register.open-cluster-management.io]" \
    "register.open-cluster-management.io" managedclusters accept update
sar "create managedclustersets/bind   [cluster.open-cluster-management.io]" \
    "cluster.open-cluster-management.io" managedclustersets bind create
sar "create managedclustersets/join   [cluster.open-cluster-management.io]" \
    "cluster.open-cluster-management.io" managedclustersets join create

echo
echo "--- recursos normais ---"
sar "patch  managedclustersets"          "cluster.open-cluster-management.io" managedclustersets        "" patch
sar "create managedclustersetbindings"   "cluster.open-cluster-management.io" managedclustersetbindings "" create "$NS"
sar "create managedclusters"             "cluster.open-cluster-management.io" managedclusters           "" create
sar "create placements"                  "cluster.open-cluster-management.io" placements                "" create "$NS"
sar "create channels"                    "apps.open-cluster-management.io"    channels                  "" create cluster-gitops-repo
sar "create gitopsclusters"              "apps.open-cluster-management.io"    gitopsclusters            "" create "$NS"
sar "create klusterletaddonconfigs"      "agent.open-cluster-management.io"   klusterletaddonconfigs    "" create
sar "create clusterdeployments"          "hive.openshift.io"                  clusterdeployments        "" create
sar "create machinepools"                "hive.openshift.io"                  machinepools              "" create
sar "create namespaces"                  ""                                   namespaces                "" create
sar "create secrets"                     ""                                   secrets                   "" create

echo
if [[ $fail -eq 0 ]]; then
  echo "Todas as permissoes concedidas."
else
  echo "Faltam permissoes. Aplique (como cluster-admin):"
  echo "    oc apply -f argocd/00-rbac-acm.yaml"
  echo
  echo "Se ja aplicou e continua negado, verifique se o operador do OpenShift"
  echo "GitOps nao esta reconciliando por cima do binding:"
  echo "    oc get clusterrolebinding openshift-gitops-acm-manager -o yaml"
  echo "    oc get subscription -n openshift-operators openshift-gitops-operator \\"
  echo "       -o jsonpath='{.spec.config.env}'"
  exit 1
fi
