# 4. Troubleshooting

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

## O ApplicationSet não gerou nada

```bash
oc get applicationset cliente-clusters -n openshift-gitops -o yaml | grep -A20 status
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

## Uma Route não é admitida por nenhum router

```bash
oc get route <rota> -n <ns> -o jsonpath='{.status.ingress[*].routerName}'; echo
oc get route <rota> -n <ns> --show-labels
```

Sem a label `router: private|public` e com `isolateByLabel: true`, a rota é
recusada pelos três IngressControllers. Adicione a label.

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
oc get applications -n openshift-gitops | grep -E 'bundle-|provision-|operators-|certs-|ingress-|dns-'
oc get clusterdeployment -A
oc get managedcluster

# Cluster gerenciado
oc get csv -A | grep -E 'cert-manager|external-dns'
oc get clusterissuer
oc get certificate -A
oc get ingresscontroller -n openshift-ingress-operator
oc get externaldns
```
