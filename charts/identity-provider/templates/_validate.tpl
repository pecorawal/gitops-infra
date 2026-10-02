{{/*
  Falha o render se algum campo dos providers ainda estiver com <PREENCHER>.
  Sem isto o OAuth/cluster seria aplicado com clientID vazio e o login quebraria
  para todo mundo -- inclusive para quem ja estava autenticado, porque o
  authentication-operator reinicia os pods do oauth-server ao reconciliar.
*/}}
{{- define "identity-provider.validate" -}}
{{- $rendered := toYaml .Values.identityProvider.providers -}}
{{- if regexMatch "<[A-Z_]{2,}>" $rendered -}}
{{- fail (printf "identityProvider.providers ainda contem placeholder <MAIUSCULAS>. Preencha (ou desligue identityProvider.enabled) antes de commitar.\n%s" $rendered) -}}
{{- end -}}
{{- if not .Values.identityProvider.providers -}}
{{- fail "identityProvider.enabled=true mas identityProvider.providers esta vazio -- o OAuth ficaria sem nenhum provider e so o kubeadmin conseguiria entrar." -}}
{{- end -}}
{{- end -}}
