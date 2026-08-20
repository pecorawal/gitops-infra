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

   modo "existing" (padrao): os Secrets ja existem no namespace do cluster,
     criados por docs/cliente/scripts/preparar-credenciais.sh a partir da
     Credential compartilhada do ACM. Os nomes seguem a MESMA convencao
     (<cluster>-azure-creds e <cluster>-pull-secret), entao nao e preciso
     informar nada -- os campos existing* sao apenas para nomes fora do padrao.
  ===========================================================================
*/}}

{{/* Secret com osServicePrincipal.json (platform.azure.credentialsSecretRef) */}}
{{- define "azure-ipi-cluster.azureCredsSecret" -}}
{{- $c := .Values.provision.credentials -}}
{{- if and (eq $c.mode "existing") $c.existingCredentialsSecret -}}
{{- $c.existingCredentialsSecret -}}
{{- else -}}
{{- printf "%s-azure-creds" .Values.clusterName -}}
{{- end -}}
{{- end -}}

{{/* Secret dockerconfigjson (pullSecretRef) */}}
{{- define "azure-ipi-cluster.pullSecret" -}}
{{- $c := .Values.provision.credentials -}}
{{- if and (eq $c.mode "existing") $c.existingPullSecret -}}
{{- $c.existingPullSecret -}}
{{- else -}}
{{- printf "%s-pull-secret" .Values.clusterName -}}
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
