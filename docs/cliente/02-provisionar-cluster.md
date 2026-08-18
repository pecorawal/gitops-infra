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
| `provision.credentialsSecret` | `oc get secret -n <cluster> -l cluster.open-cluster-management.io/type=azr` |
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

## 2.3 Ligar o interruptor e commitar

```yaml
provision:
  enabled: true      # <-- aqui
```

```bash
git add clusters/azr-cliente-prod-01/values.yaml
git commit -m "novo cluster azr-cliente-prod-01"
git push origin cliente
```

## 2.4 O que acontece

1. O `ApplicationSet` detecta o novo `values.yaml` e cria `bundle-azr-cliente-prod-01`.
2. O bundle emite `provision-azr-cliente-prod-01`.
3. Essa Application aplica no hub, em ordem de wave:
   - o Namespace do cluster (`-5`);
   - o Secret `<cluster>-install-config` (`-1`) — o manifesto do `openshift-install`;
   - o `ClusterDeployment` (`0`) — dispara o Hive;
   - o `MachinePool` de workers (`1`);
   - o `ManagedCluster` e o `KlusterletAddonConfig` (`2`).
4. O Hive sobe um Job de instalação e roda o `openshift-install` (~40 min).
5. Terminado, o ACM importa o cluster automaticamente (não há kubeconfig manual —
   isso só existe para clusters *importados*, em `charts/import-cluster`).
6. O `GitOpsCluster` vê a label `apps.open-cluster-management.io/replicate-to-argocd=true`
   e registra o cluster como destino no ArgoCD.

## 2.5 Acompanhar

```bash
export CLUSTER=azr-cliente-prod-01

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

## 2.6 Credenciais do cluster novo

```bash
oc get secret -n "$CLUSTER" "${CLUSTER}-admin-password" \
  -o jsonpath='{.data.password}' | base64 -d; echo
oc get secret -n "$CLUSTER" "${CLUSTER}-admin-kubeconfig" \
  -o jsonpath='{.data.kubeconfig}' | base64 -d > ~/.kube/"$CLUSTER"
```

## 2.7 Escalar depois

Mude `provision.compute.replicas` e commite — o Hive reconcilia o `MachinePool`.

➡️ [3. Day-2: ingress, DNS e certificados](03-day2-ingress-dns-certs.md)
