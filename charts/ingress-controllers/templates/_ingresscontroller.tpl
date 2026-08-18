{{/*
  Template unico dos IngressControllers adicionais.
  Recebe: (dict "ic" <bloco private|public> "wave" "<n>")
*/}}
{{- define "ingress-controllers.controller" -}}
{{- $ic := .ic -}}
apiVersion: operator.openshift.io/v1
kind: IngressController
metadata:
  name: {{ $ic.name }}
  namespace: openshift-ingress-operator
  annotations:
    argocd.argoproj.io/sync-wave: {{ .wave | quote }}
spec:
  domain: {{ $ic.domain | quote }}
  replicas: {{ $ic.replicas }}
  endpointPublishingStrategy:
    type: LoadBalancerService
    loadBalancer:
      # Internal = Azure Internal Load Balancer (so acessivel pela VNet)
      # External = Azure Public Load Balancer
      scope: {{ $ic.scope }}
      # Unmanaged e obrigatorio: se o ingress-operator gerenciar o DNS, ele
      # briga com o ExternalDNS pelos mesmos registros na zona da Azure.
      dnsManagementPolicy: Unmanaged
  # ---- ADMISSAO DE ROTA POR LABEL ----
  # Somente Routes que carreguem esta label entram neste IngressController.
  routeSelector:
    matchLabels:
      {{ $ic.routeSelector.key }}: {{ $ic.routeSelector.value | quote }}
  {{- with $ic.namespaceSelector }}
  namespaceSelector:
    matchLabels:
      {{- toYaml . | nindent 6 }}
  {{- end }}
  {{- if $ic.certificate.enabled }}
  # Secret gerado pelo cert-manager no namespace openshift-ingress (wave 20).
  defaultCertificate:
    name: {{ $ic.certificate.secretName }}
  {{- end }}
  routeAdmission:
    namespaceOwnership: InterNamespaceAllowed
    wildcardPolicy: WildcardsDisallowed
  {{- with $ic.nodePlacement }}
  nodePlacement:
    nodeSelector:
      matchLabels:
        {{- toYaml . | nindent 8 }}
  {{- end }}
{{- end -}}
