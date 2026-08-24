{{- define "nsg-rule.validate" -}}
{{- $v := .Values.nsgRule -}}
{{- $campos := dict
  "nsgRule.nsgName"            $v.nsgName
  "nsgRule.nsgResourceGroup"   $v.nsgResourceGroup
  "nsgRule.subscriptionId"     $v.subscriptionId
  "nsgRule.serviceName"        $v.serviceName
-}}
{{- $pendentes := list -}}
{{- range $chave, $valor := $campos -}}
  {{- if or (not $valor) (contains "<PREENCHER>" (toString $valor)) -}}
    {{- $pendentes = append $pendentes $chave -}}
  {{- end -}}
{{- end -}}
{{- /*
  Nome do CronJob: "nsg-rule-<cluster>". O Kubernetes acrescenta o timestamp ao
  criar cada Job (nsg-rule-<cluster>-29012345), e nome de Job e limitado a 63
  caracteres -- por isso o CronJob nao pode passar de 52.
*/ -}}
{{- $nomeCron := printf "nsg-rule-%s" .Values.clusterName -}}
{{- if gt (len $nomeCron) 52 -}}
  {{- fail (printf "\n\nNome do CronJob muito longo: %q (%d caracteres).\nO Kubernetes acrescenta o timestamp ao criar cada Job, e nome de Job e\nlimitado a 63 caracteres -- sobram 52 para o CronJob. Encurte clusterName.\n" $nomeCron (len $nomeCron)) -}}
{{- end -}}
{{- if $pendentes -}}
  {{- fail (printf "\n\nCluster %q: valor(es) ainda por preencher em clusters/%s/values.yaml:\n  - %s\n\nPreencha antes de ligar nsgRule.enabled: true.\n" .Values.clusterName .Values.clusterName (join "\n  - " (sortAlpha $pendentes))) -}}
{{- end -}}
{{- end -}}
