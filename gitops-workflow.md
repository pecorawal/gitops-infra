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
  webhook.github.secret: "xlxqifdjHaVdDJdyMTkjGdEJX94=" # <-inserir a senha gerada no passo anterior
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



