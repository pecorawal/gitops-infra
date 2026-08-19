{{/*
  Template unico das instancias de ExternalDNS.
  Recebe: (dict "zone" <bloco private|public>)

  Uma instancia por IngressController: o campo openshiftRouteOptions.routerName
  faz o ExternalDNS enxergar apenas as Routes admitidas por aquele router, e
  usar o hostname do Load Balancer daquele router como alvo do registro.

  O que separa a zona privada da publica NAO e o provider (que e Azure nos dois
  casos) e sim o resource ID em spec.zones:
    .../providers/Microsoft.Network/privateDnsZones/<zona>   -> Azure Private DNS
    .../providers/Microsoft.Network/dnszones/<zona>          -> Azure DNS publica
*/}}
{{- define "external-dns-config.instance" -}}
{{- $z := .zone -}}
apiVersion: externaldns.olm.openshift.io/v1beta1
kind: ExternalDNS
metadata:
  name: {{ $z.name }}
  annotations:
    argocd.argoproj.io/sync-wave: "0"
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
spec:
  provider:
    type: Azure
    azure:
      configFile:
        name: {{ $z.configSecretName }}
  source:
    type: OpenShiftRoute
    openshiftRouteOptions:
      routerName: {{ $z.routerName }}
    hostnameAnnotation: Ignore
  domains:
    - filterType: Include
      matchType: Pattern
      pattern: {{ printf ".*\\.%s" ($z.domain | replace "." "\\.") | quote }}
    {{- /*
      Exclusoes. Necessarias quando o dominio de outro router e SUBDOMINIO deste:
      sem excluir, o filtro .*\.cgibs\.gov\.br tambem casaria com
      app.pri.cgibs.gov.br e as duas instancias disputariam o mesmo registro.
    */}}
    {{- range $z.excludeDomains }}
    - filterType: Exclude
      matchType: Pattern
      pattern: {{ printf ".*\\.%s" (. | replace "." "\\.") | quote }}
    {{- end }}
  zones:
    - {{ $z.zoneId | quote }}
{{- end -}}
