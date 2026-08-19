{{/*
  ===========================================================================
   RESOLUCAO DO ManagedClusterSet A PARTIR DE labels.env
  ---------------------------------------------------------------------------
   Ordem de decisao:
     1. clusterSet preenchido no values  -> usa esse valor (escape hatch)
     2. clusterSets.byEnv[<labels.env>]  -> usa o mapeamento
     3. clusterSets.default              -> ultimo recurso

   Se nada resolver, a renderizacao FALHA com mensagem explicita. E deliberado:
   um ManagedCluster sem a label de clusterset nao entra em nenhuma Placement,
   logo nao e registrado no ArgoCD e todo o day-2 fica sem destino -- um erro
   silencioso que so apareceria 40 minutos depois, com o cluster ja provisionado.

   O ManagedClusterSet precisa EXISTIR no hub e estar vinculado ao namespace
   openshift-gitops por um ManagedClusterSetBinding (bootstrap/03-*.yaml).
  ===========================================================================
*/}}
{{- define "azure-ipi-cluster.clusterSet" -}}
{{- $env := .Values.labels.env | default .Values.environment | default "" -}}
{{- $byEnv := (.Values.clusterSets | default dict).byEnv | default dict -}}
{{- $set := "" -}}
{{- if .Values.clusterSet -}}
  {{- $set = .Values.clusterSet -}}
{{- else if hasKey $byEnv $env -}}
  {{- $set = get $byEnv $env -}}
{{- else -}}
  {{- $set = (.Values.clusterSets | default dict).default | default "" -}}
{{- end -}}
{{- if not $set -}}
  {{- fail (printf "\n\nManagedClusterSet indefinido para o cluster %q.\n  labels.env = %q\n  clusterSets.byEnv nao tem essa chave e clusterSets.default esta vazio.\nCorrija clusters/%s/values.yaml: defina labels.env com um valor mapeado, ou\nacrescente a chave em clusterSets.byEnv, ou preencha clusterSet explicitamente.\n" .Values.clusterName $env .Values.clusterName) -}}
{{- end -}}
{{- $set -}}
{{- end -}}
