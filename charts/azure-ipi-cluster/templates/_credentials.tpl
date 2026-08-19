{{/*
  ===========================================================================
   RESOLUCAO DOS SECRETS DE CREDENCIAL QUE O HIVE CONSOME
  ---------------------------------------------------------------------------
   O Hive so le Secrets do NAMESPACE do ClusterDeployment. Como a Credential do
   ACM e uma so, compartilhada por todos os provisionamentos, ela precisa ser
   materializada em cada namespace <clusterName>.

   modo "externalSecret" (padrao): o ExternalSecret copia a Credential
     compartilhada e ja entrega os dois formatos que o Hive exige:
       <cluster>-azure-creds   Opaque       osServicePrincipal.json + ssh-privatekey
       <cluster>-pull-secret   dockerconfigjson  .dockerconfigjson

   modo "existing": voce criou a Credential do ACM dentro do namespace do
     cluster e informou os nomes em credentials.existing*.
  ===========================================================================
*/}}

{{/* Secret com osServicePrincipal.json (platform.azure.credentialsSecretRef) */}}
{{- define "azure-ipi-cluster.azureCredsSecret" -}}
{{- $c := .Values.provision.credentials -}}
{{- if eq $c.mode "externalSecret" -}}
{{- printf "%s-azure-creds" .Values.clusterName -}}
{{- else -}}
{{- required "provision.credentials.existingCredentialsSecret e obrigatorio quando credentials.mode=existing" $c.existingCredentialsSecret -}}
{{- end -}}
{{- end -}}

{{/* Secret dockerconfigjson (pullSecretRef) */}}
{{- define "azure-ipi-cluster.pullSecret" -}}
{{- $c := .Values.provision.credentials -}}
{{- if eq $c.mode "externalSecret" -}}
{{- printf "%s-pull-secret" .Values.clusterName -}}
{{- else -}}
{{- required "provision.credentials.existingPullSecret e obrigatorio quando credentials.mode=existing" $c.existingPullSecret -}}
{{- end -}}
{{- end -}}

{{/*
  Secret com ssh-privatekey (provisioning.sshPrivateKeySecretRef).
  Por padrao e o MESMO secret do osServicePrincipal.json: o Hive le chaves
  diferentes de refs diferentes, e nada impede que apontem para o mesmo objeto.
*/}}
{{- define "azure-ipi-cluster.sshSecret" -}}
{{- $c := .Values.provision.credentials -}}
{{- if $c.existingSshPrivateKeySecret -}}
{{- $c.existingSshPrivateKeySecret -}}
{{- else -}}
{{- include "azure-ipi-cluster.azureCredsSecret" . -}}
{{- end -}}
{{- end -}}
