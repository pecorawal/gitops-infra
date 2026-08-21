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
{{- if $pendentes -}}
  {{- fail (printf "\n\nCluster %q: valor(es) ainda por preencher em clusters/%s/values.yaml:\n  - %s\n\nPreencha antes de ligar nsgRule.enabled: true.\n" .Values.clusterName .Values.clusterName (join "\n  - " (sortAlpha $pendentes))) -}}
{{- end -}}
{{- end -}}
