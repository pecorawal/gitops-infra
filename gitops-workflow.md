#GitOps Flow

Estrutura Final do Fluxo
ArgoCD (Hub): Detecta novo arquivo em /clusters no Git.
ArgoCD (Hub): Aplica o ClusterDeployment (CRD do Hive) no namespace de destino.
ACM (Hive): Inicia o provisionamento da infraestrutura (EC2, VPC, etc) e instala o OpenShift.
ACM (Import): Assim que o cluster sobe, o ACM o importa automaticamente como um ManagedCluster.
ArgoCD (GitOpsCluster): O vínculo de integração detecta o novo ManagedCluster e o adiciona como um endpoint de destino no ArgoCD.
ArgoCD (App): Começa a fazer o deploy das suas aplicações e políticas de segurança no cluster recém-nascido.




##Criação do Webhook


- Gerar string da senha para aplicar no GitOps
 `openssl rand -base64 20`

- Aplicar a senha a um yaml no ArgoCD

```
apiVersion: v1
kind: Secret
metadata:
  name: argocd-secret
  namespace: openshift-gitops
  labels:
    app.kubernetes.io/part-of: argocd
type: Opaque
stringData:
  # A chave 'webhook.github.secret' é obrigatória para o ArgoCD reconhecer
  webhook.github.secret: "kjGdEJX94=" # <-inserir a senha gerada no passo anterior
```


- Config no github
Configuração no GitHub (Emissor)
....Agora, vá ao seu repositório Git onde estão os Helm Charts e arquivos de configuração:
....Acesse Settings > Webhooks > Add webhook.
....Payload URL: O endereço público do seu ArgoCD Server com o sufixo /api/webhook.
....Exemplo: https://argocd-server-openshift-gitops.apps.cluster-hub.exemplo.com/api/webhook
....Content type: Selecione application/json.
....Secret: Insira a mesma string que você usou no passo anterior, value do campo webhook.github.secret.
....Selecione Just the push event.
....SSL verification: Certifique-se de que o certificado do seu OpenShift seja válido (ou desabilite se for um ambiente de laboratório com self-signed, mas não recomendo para prod).



oc create secret generic rosa-prod-01-auth \
  --from-literal=aws_access_key_id="PLACEHOLDER" \
  --from-literal=aws_secret_access_key="PLACEHOLDER" \
  -n rosa-prod-01



  O Fluxo de Ativação 
Para que tudo funcione, você precisa de um "ponta pé inicial":

Manual: Você aplica o root-app.yaml no ArgoCD uma única vez.

Automático: Esse root-app.yaml aponta para a pasta bootstrap/.

Execução: O ArgoCD lê a pasta bootstrap/, instala o ApplicationSet.

Automação: O ApplicationSet começa a ler a pasta clusters/ e cria as Applications de importação para cada subpasta que ele encontrar lá.




Como executar:
Com o repositório Git devidamente estruturado, você executa apenas este comando no seu terminal conectado ao Hub Cluster:

Bash
oc apply -f argocd-bootstrap/root.yaml

Automaticamente em seguida:

Sincronização do Root: O ArgoCD lê a pasta bootstrap/.
Instalação do Motor: Ele encontra o app-set-import.yaml e o cria no cluster.
Geração Dinâmica: O ApplicationSet recém-criado varre a pasta clusters/.
Provisionamento/Importação: Para cada subpasta (ex: clusters/aro-prod), o ApplicationSet gera uma nova Application individual que o ACM usará para importar o cluster ARO.

Pronto para uso: Como configuramos a label de replicação, o novo cluster ARO aparecerá no ArgoCD automaticamente como um destino de deploy.



Passo 1: Limpe seu values.yaml
Mantenha assim para o Push passar:

YAML
cloudCredentials:
  subscriptionId: "HIDDEN"
  tenantId: "HIDDEN"
  clientId: "HIDDEN"
  clientSecret: "HIDDEN"
Passo 2: Crie o Namespace no Hub
Bash
oc create namespace aro-prod-01
Passo 3: Crie o Secret de Credenciais da Azure (ARO) diretamente no Cluster
Execute este comando (substituindo pelos seus dados reais):

Bash
oc create secret generic aro-prod-01-auth \
  -n aro-prod-01 \
  --from-literal=osServicePrincipal.clientId="PLACEHOLDER" \
  --from-literal=osServicePrincipal.clientSecret='PLACEHOLDER' \
  --from-literal=osServicePrincipal.subscriptionId="683e1ca71fcb" \
  --from-literal=osServicePrincipal.tenantId="redhat0.joedoe.com"
