{{/*
  Bloco "source" comum a todas as Applications filhas.
  Todas apontam para o MESMO values.yaml do cluster -- e por isso todas
  enxergam os mesmos interruptores "enabled".
  O prefixo ../../ leva de charts/<nome-do-chart> ate a raiz do repo,
  mesma convencao ja usada em bootstrap/app-set-import.yaml.
*/}}
{{- define "bundle.source" -}}
repoURL: {{ .root.Values.global.repoURL | quote }}
targetRevision: {{ .root.Values.global.targetRevision | quote }}
path: charts/{{ .chart }}
helm:
  releaseName: {{ .root.Values.clusterName }}
  valueFiles:
    - ../../{{ .root.Values.global.valuesPath }}
{{- end -}}

{{/*
  syncPolicy comum. O retry existe porque as Applications de day-2 apontam para
  um cluster que ainda nao foi provisionado/registrado no ArgoCD -- elas ficam
  em erro transitorio ("Cluster not found") ate o ACM registrar o spoke.
*/}}
{{- define "bundle.syncPolicy" -}}
syncPolicy:
  automated:
    prune: true
    selfHeal: true
  syncOptions:
    - CreateNamespace=true
    - ApplyOutOfSyncOnly=true
  retry:
    limit: 5
    backoff:
      duration: 30s
      factor: 2
      maxDuration: 10m
{{- end -}}
