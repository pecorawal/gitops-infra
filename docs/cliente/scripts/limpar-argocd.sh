#!/usr/bin/env bash
# =============================================================================
#  Zera o estado do ArgoCD desta esteira, para recomecar do zero.
#
#  POR QUE APAGAR A APPLICATION RAIZ NAO APAGOU NADA
#  -------------------------------------------------------------------------
#  O ArgoCD so faz delecao em CASCATA quando a Application tem o finalizer
#  resources-finalizer.argocd.argoproj.io. As Applications desta esteira NAO
#  tem -- de proposito, porque a cascata da provision-<cluster> destruiria o
#  ClusterDeployment e o Hive deprovisionaria o cluster na Azure.
#
#  O preco dessa seguranca e que a limpeza precisa ser explicita. E o que este
#  script faz, na ordem certa:
#
#    1. ApplicationSet cliente-clusters   (senao ele recria os bundle-* sozinho)
#    2. Applications filhas               provision-/operators-/certs-/ingress-/dns-
#    3. Applications bundle-*
#    4. Application raiz cliente-bootstrap
#    5. Objetos do bootstrap/             GitOpsCluster, bindings, placements, ESO
#
#  O QUE ELE NAO TOCA
#  -------------------------------------------------------------------------
#  ClusterDeployment, ManagedCluster, MachinePool e os namespaces dos clusters.
#  Apagar um ClusterDeployment faz o Hive DESTRUIR o cluster na Azure, e isso
#  nunca deve ser efeito colateral de "resetar o ArgoCD". Os clusters continuam
#  de pe; ao reaplicar o root, o ArgoCD os readota.
#  Para descomissionar de verdade: docs/cliente/02-provisionar-cluster.md, 2.8
#
#  Uso:
#    ./docs/cliente/scripts/limpar-argocd.sh              # so lista (dry-run)
#    ./docs/cliente/scripts/limpar-argocd.sh --confirmar  # executa
# =============================================================================
set -uo pipefail

NS="${NS:-openshift-gitops}"
GO=0
[[ "${1:-}" == "--confirmar" ]] && GO=1

hdr() { printf "\n\033[1m== %s\033[0m\n" "$1"; }
act() { # <descricao> <comando...>
  local desc="$1"; shift
  if [[ $GO -eq 1 ]]; then
    printf "  \033[31mAPAGANDO\033[0m %s\n" "$desc"
    "$@" >/dev/null 2>&1 || printf "           (ja nao existia)\n"
  else
    printf "  seria apagado: %s\n" "$desc"
  fi
}

oc whoami >/dev/null 2>&1 || { echo "ERRO: faca login no hub primeiro." >&2; exit 1; }
echo "Hub: $(oc whoami --show-server)"
[[ $GO -eq 0 ]] && echo "MODO DRY-RUN -- nada sera apagado. Use --confirmar para executar."

# ------------------------------------------------- 1. o gerador, antes de tudo
hdr "1. ApplicationSet"
act "applicationset/cliente-clusters" \
  oc delete applicationset cliente-clusters -n "$NS" --ignore-not-found

# ------------------------------------------------------- 2 e 3. as Applications
hdr "2. Applications da esteira"
APPS=$(oc get application -n "$NS" -o name 2>/dev/null \
  | sed 's|application.argoproj.io/||' \
  | grep -E '^(bundle|provision|operators|certs|ingress|dns)-' || true)
if [[ -z "$APPS" ]]; then
  echo "  nenhuma encontrada"
else
  # filhas primeiro, bundles depois
  for app in $(grep -v '^bundle-' <<<"$APPS") $(grep '^bundle-' <<<"$APPS"); do
    act "application/$app" oc delete application "$app" -n "$NS" --ignore-not-found --wait=false
  done
fi

hdr "3. Application raiz"
act "application/cliente-bootstrap" \
  oc delete application cliente-bootstrap -n "$NS" --ignore-not-found

# --------------------------------------------------- 4. objetos do bootstrap/
hdr "4. Objetos do bootstrap/"
act "gitopscluster/gitops-cluster"                oc delete gitopscluster gitops-cluster -n "$NS" --ignore-not-found
for b in pro non-pro global-clusters; do
  act "managedclustersetbinding/$b"               oc delete managedclustersetbinding "$b" -n "$NS" --ignore-not-found
done
for p in all-managed-clusters pro-clusters non-pro-clusters gitops; do
  act "placement/$p"                              oc delete placement "$p" -n "$NS" --ignore-not-found
done
act "applicationset/import-external-clusters"     oc delete applicationset import-external-clusters -n "$NS" --ignore-not-found
act "channel/cluster-gitops-channel"              oc delete channel cluster-gitops-channel -n cluster-gitops-repo --ignore-not-found
act "namespace/cluster-gitops-repo"               oc delete namespace cluster-gitops-repo --ignore-not-found --wait=false
act "clustersecretstore/acm-credentials-hub"      oc delete clustersecretstore acm-credentials-hub --ignore-not-found

echo
echo "NAO tocado (de proposito): ManagedClusterSet, ClusterDeployment,"
echo "ManagedCluster, MachinePool e os namespaces dos clusters."

# ----------------------------------------------------------- 5. verificacao
if [[ $GO -eq 1 ]]; then
  hdr "5. Sobrou algo?"
  sleep 3
  REST=$(oc get application,applicationset -n "$NS" -o name 2>/dev/null \
    | grep -E '(bundle|provision|operators|certs|ingress|dns|cliente)-' || true)
  if [[ -z "$REST" ]]; then
    echo "  nada. Estado do ArgoCD limpo."
  else
    echo "  ainda presente:"; sed 's/^/    /' <<<"$REST"
    echo
    echo "  Se estiver preso, quase sempre e finalizer de uma versao antiga."
    echo "  Confira antes de forcar:"
    echo "    oc get application <nome> -n $NS -o jsonpath='{.metadata.finalizers}'"
    echo "  E so entao:"
    echo "    oc patch application <nome> -n $NS --type=merge -p '{\"metadata\":{\"finalizers\":null}}'"
    echo
    echo "  ATENCAO: remover o finalizer NAO dispara cascata -- o objeto some e os"
    echo "  recursos ficam. E o que voce quer aqui."
  fi

  cat <<'FIM'

Para recomecar:
    oc apply -f argocd/00-rbac-acm.yaml
    oc apply -f argocd/root-cliente.yaml

Os clusters ja provisionados continuam de pe e serao readotados na primeira
sincronizacao, desde que clusters/<cluster>/values.yaml continue no Git.
FIM
fi
