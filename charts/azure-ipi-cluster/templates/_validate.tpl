{{/*
  ===========================================================================
   GUARDA CONTRA <PREENCHER> ESQUECIDO
  ---------------------------------------------------------------------------
   "required" do Helm so barra valor vazio -- o placeholder <PREENCHER> passa
   por ser uma string valida. Sem esta checagem o ClusterDeployment seria
   aplicado com "<PREENCHER>" no lugar do resource group, e a falha so
   apareceria minutos depois, num log do Job de instalacao do Hive.
  ===========================================================================
*/}}
{{- define "azure-ipi-cluster.validate" -}}
{{- $p := .Values.provision -}}
{{- $campos := dict
  "baseDomain"                                   .Values.baseDomain
  "provision.imageSetRef"                        $p.imageSetRef
  "provision.azure.region"                       $p.azure.region
  "provision.azure.baseDomainResourceGroupName"  $p.azure.baseDomainResourceGroupName
  "provision.networking.machineNetwork"          $p.networking.machineNetwork
-}}
{{- if eq $p.credentials.mode "externalSecret" -}}
  {{- $_ := set $campos "provision.credentials.sourceSecret"    $p.credentials.sourceSecret -}}
  {{- $_ := set $campos "provision.credentials.sourceNamespace" $p.credentials.sourceNamespace -}}
{{- end -}}
{{- if $p.azure.virtualNetwork -}}
  {{- $_ := set $campos "provision.azure.networkResourceGroupName" $p.azure.networkResourceGroupName -}}
  {{- $_ := set $campos "provision.azure.controlPlaneSubnet"       $p.azure.controlPlaneSubnet -}}
  {{- $_ := set $campos "provision.azure.computeSubnet"            $p.azure.computeSubnet -}}
{{- end -}}
{{- $pendentes := list -}}
{{- range $chave, $valor := $campos -}}
  {{- if or (not $valor) (contains "<PREENCHER>" (toString $valor)) -}}
    {{- $pendentes = append $pendentes $chave -}}
  {{- end -}}
{{- end -}}
{{- if $pendentes -}}
  {{- fail (printf "\n\nCluster %q: %d valor(es) ainda por preencher em clusters/%s/values.yaml:\n  - %s\n\nPreencha antes de deixar provision.enabled: true, senao o Hive iniciaria a\ninstalacao com placeholders e so falharia no log do Job, minutos depois.\n" .Values.clusterName (len $pendentes) .Values.clusterName (join "\n  - " (sortAlpha $pendentes))) -}}
{{- end -}}
{{- end -}}
