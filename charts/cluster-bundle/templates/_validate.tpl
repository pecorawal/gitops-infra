{{/*
  Prova de que o values.yaml DO CLUSTER foi carregado.

  O ApplicationSet injeta clusterName (pelo valueFiles) e global.valuesPath
  (por helm.parameters). Se qualquer um dos dois chegar vazio, o arquivo do
  cluster NAO entrou no merge -- e sem esta checagem o bundle renderizaria os
  defaults inertes em silencio, ignorando todo enabled que o cliente ligou.

  Falhar aqui e seguro: sem os valores do cluster o bundle nao emitiria
  Application nenhuma de qualquer forma. A diferenca e que agora aparece o
  motivo, na aba de erro da Application.
*/}}
{{- define "bundle.validate" -}}
{{- if not .Values.clusterName -}}
{{- fail "clusterName vazio: o values.yaml do cluster NAO foi carregado. Confira helm.valueFiles em bootstrap/02-appset-cliente.yaml (deve resolver para clusters/<cluster>/values.yaml) e se o arquivo define clusterName no topo." -}}
{{- end -}}
{{- if not .Values.global.valuesPath -}}
{{- fail "global.valuesPath vazio: o ApplicationSet nao repassou o parametro. Sem ele as Applications filhas leriam o values errado. Confira helm.parameters em bootstrap/02-appset-cliente.yaml." -}}
{{- end -}}
{{- if not (hasSuffix (printf "clusters/%s/values.yaml" .Values.clusterName) .Values.global.valuesPath) -}}
{{- fail (printf "INCOERENTE: clusterName=%q mas global.valuesPath=%q. As Applications filhas leriam o values de OUTRO cluster. O nome do diretorio em clusters/ tem que ser igual ao clusterName." .Values.clusterName .Values.global.valuesPath) -}}
{{- end -}}
{{- end -}}
