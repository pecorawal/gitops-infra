{{/*
  ===========================================================================
   VALIDACAO DOS POOLS ADICIONAIS
  ---------------------------------------------------------------------------
   Um MachinePool errado nao falha no sync: o ArgoCD aplica, o Hive aceita ou
   recusa no webhook, e a maior parte dos erros so aparece no SPOKE, minutos
   depois, como Machine em Failed -- ou nem aparece (pool sem nenhum no).
   Tudo o que da para saber na hora do render e barrado aqui.
  ===========================================================================
*/}}
{{- define "machine-pools.validate" -}}
{{- if not .Values.clusterName -}}
  {{- fail "\n\nclusterName vazio: o values.yaml do cluster NAO foi carregado.\nO MachinePool precisa dele para o nome (<cluster>-<pool>) e para o\nclusterDeploymentRef.\n" -}}
{{- end -}}
{{- $pools := .Values.machinePools.pools | default list -}}
{{- if not (kindIs "slice" $pools) -}}
  {{- fail "\n\nmachinePools.pools tem que ser uma LISTA (cada item comeca com \"- name:\").\n" -}}
{{- end -}}
{{- if not $pools -}}
  {{- fail "\n\nmachinePools.enabled=true mas machinePools.pools esta vazio.\nNenhum MachinePool seria criado -- e nenhum erro diria por que.\nDeclare ao menos um pool ou volte enabled para false.\n" -}}
{{- end -}}
{{- $azure := .Values.provision.azure | default dict -}}
{{- $compute := .Values.provision.compute | default dict -}}
{{- $diskWorker := $compute.osDisk | default dict -}}
{{- $poolWorker := (.Values.provision.machinePool | default dict).name | default "worker" -}}
{{- /*
  REDE HERDADA DO WORKER
  Mesma licao do pool worker (04-machinepool-worker.yaml): sem os tres campos
  da BYO VNet o Hive monta o MachineSet com a rede que o instalador CRIARIA
  (<infraID>-vnet), e cada maquina falha com ResourceNotFound.
*/ -}}
{{- $campos := dict "provision.azure.region" $azure.region -}}
{{- if $azure.virtualNetwork -}}
  {{- $_ := set $campos "provision.azure.networkResourceGroupName" $azure.networkResourceGroupName -}}
  {{- $_ := set $campos "provision.azure.virtualNetwork"           $azure.virtualNetwork -}}
  {{- $_ := set $campos "provision.azure.computeSubnet"            $azure.computeSubnet -}}
{{- end -}}
{{- $pendentes := list -}}
{{- range $chave, $valor := $campos -}}
  {{- if or (not $valor) (regexMatch "<[A-Z_]{2,}>" (toString $valor)) -}}
    {{- $pendentes = append $pendentes $chave -}}
  {{- end -}}
{{- end -}}
{{- if $pendentes -}}
  {{- fail (printf "\n\nCluster %q: os pools adicionais herdam do bloco provision valor(es) ainda por preencher:\n  - %s\n\nSem eles as maquinas novas nascem fora da rede do cluster.\n" .Values.clusterName (join "\n  - " (sortAlpha $pendentes))) -}}
{{- end -}}
{{- $vistos := dict -}}
{{- range $i, $p := $pools -}}
  {{- if not (kindIs "map" $p) -}}
    {{- fail (printf "\n\nmachinePools.pools[%d] nao e um bloco (name, type, replicas...): %v\n" $i $p) -}}
  {{- end -}}
  {{- $nome := $p.name | default "" | toString -}}
  {{- $rotulo := printf "machinePools.pools[%d] (name=%q)" $i $nome -}}
  {{- if regexMatch "<[A-Z_]{2,}>" (toYaml $p) -}}
    {{- fail (printf "\n\n%s ainda contem placeholder <MAIUSCULAS>:\n%s\n" $rotulo (toYaml $p)) -}}
  {{- end -}}
  {{- /*
    NOME -- entra em tres lugares: MachinePool <cluster>-<name> (hub),
    MachineSet <infraID>-<name>-<regiao><zona> e nome da VM na Azure.
    E imutavel no Hive (spec.name).
  */ -}}
  {{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $nome) -}}
    {{- fail (printf "\n\n%s: name invalido.\nUse so minusculas, numeros e \"-\", comecando e terminando com letra ou numero.\nex: infra, highmem, gpu-a100\n" $rotulo) -}}
  {{- end -}}
  {{- if eq $nome $poolWorker -}}
    {{- fail (printf "\n\n%s: e o nome do pool WORKER (provision.machinePool.name).\nOs dois gerariam o MESMO MachinePool %s-%s, disputado por duas Applications\n(provision-%s e machinepools-%s). O worker se configura em provision.compute;\naqui vao apenas pools ADICIONAIS.\n" $rotulo $.Values.clusterName $nome $.Values.clusterName $.Values.clusterName) -}}
  {{- end -}}
  {{- if hasKey $vistos $nome -}}
    {{- fail (printf "\n\n%s: nome repetido (tambem em machinePools.pools[%v]).\nCada pool vira um MachinePool %s-<name> -- dois com o mesmo nome se sobrescrevem.\n" $rotulo (get $vistos $nome) $.Values.clusterName) -}}
  {{- end -}}
  {{- $_ := set $vistos $nome $i -}}
  {{- if not $p.type -}}
    {{- fail (printf "\n\n%s: type vazio. E o tamanho da VM na Azure.\nex: Standard_D8s_v3, Standard_E16s_v5\n  az vm list-skus -l %s --resource-type virtualMachines -o table\n" $rotulo (toString $azure.region)) -}}
  {{- end -}}
  {{- $zonas := $p.zones | default $compute.zones | default list -}}
  {{- if not (kindIs "slice" $zonas) -}}
    {{- fail (printf "\n\n%s: zones tem que ser lista. ex: [\"1\", \"2\", \"3\"]\n" $rotulo) -}}
  {{- end -}}
  {{- $maiorZona := 0 -}}
  {{- range $z := $zonas -}}
    {{- if not (toString $z) -}}
      {{- fail (printf "\n\n%s: zones tem item vazio.\n" $rotulo) -}}
    {{- end -}}
    {{- $maiorZona = max $maiorZona (len (toString $z)) -}}
  {{- end -}}
  {{- /*
    TAMANHO -- a VM na Azure recebe o nome da Machine, e VM Linux aceita no
    maximo 64 caracteres. O nome da Machine e
      <infraID>-<pool>-<regiao><zona>-<5 aleatorios>
    e o infraID e o clusterName truncado em 21 + "-" + 5 aleatorios (regra do
    openshift-install). Passar do limite nao da erro no sync: o MachineSet e
    criado e cada Machine fica em Failed com InvalidParameter da Azure.
  */ -}}
  {{- $infraID := add (len (trimSuffix "-" (trunc 21 $.Values.clusterName))) 6 -}}
  {{- $fixo := add $infraID 1 1 (len (toString $azure.region)) $maiorZona 6 -}}
  {{- if gt (add $fixo (len $nome)) 64 -}}
    {{- fail (printf "\n\n%s: o nome das VMs passaria do limite da Azure.\n  <infraID>-%s-%s<zona>-<xxxxx> = ate %d caracteres (limite: 64, VM Linux)\nA Machine ficaria em Failed com InvalidParameter, sem erro nenhum no ArgoCD.\nEncurte o name do pool para no maximo %d caracteres.\n" $rotulo $nome (toString $azure.region) (add $fixo (len $nome)) (sub 64 $fixo)) -}}
  {{- end -}}
  {{- /* DISCO -- herdado do worker campo a campo; o webhook exige tamanho > 0. */ -}}
  {{- $disk := $p.osDisk | default dict -}}
  {{- if le (int ($disk.diskSizeGB | default $diskWorker.diskSizeGB | default 0)) 0 -}}
    {{- fail (printf "\n\n%s: osDisk.diskSizeGB indefinido (nem no pool, nem em provision.compute.osDisk).\n" $rotulo) -}}
  {{- end -}}
  {{- if not ($disk.diskType | default $diskWorker.diskType) -}}
    {{- fail (printf "\n\n%s: osDisk.diskType indefinido (nem no pool, nem em provision.compute.osDisk).\nex: Premium_LRS\n" $rotulo) -}}
  {{- end -}}
  {{- /*
    TAMANHO DO POOL -- replicas OU autoscaling, nunca os dois: o webhook do Hive
    recusa o MachinePool com ambos. Com autoscaling.enabled o replicas e
    ignorado, igual ao pool worker.
  */ -}}
  {{- if and (hasKey $p "autoscaling") (not (kindIs "map" $p.autoscaling)) -}}
    {{- fail (printf "\n\n%s: autoscaling tem que ser um bloco, nao %v:\n  autoscaling:\n    enabled: true\n    minReplicas: 3\n    maxReplicas: 6\n" $rotulo $p.autoscaling) -}}
  {{- end -}}
  {{- $as := $p.autoscaling | default dict -}}
  {{- if $as.enabled -}}
    {{- if not (and (hasKey $as "minReplicas") (hasKey $as "maxReplicas")) -}}
      {{- fail (printf "\n\n%s: autoscaling.enabled=true exige minReplicas e maxReplicas.\n" $rotulo) -}}
    {{- end -}}
    {{- if gt (int $as.minReplicas) (int $as.maxReplicas) -}}
      {{- fail (printf "\n\n%s: autoscaling.minReplicas (%d) maior que maxReplicas (%d).\n" $rotulo (int $as.minReplicas) (int $as.maxReplicas)) -}}
    {{- end -}}
    {{- if lt (int $as.maxReplicas) 1 -}}
      {{- fail (printf "\n\n%s: autoscaling.maxReplicas precisa ser >= 1.\n" $rotulo) -}}
    {{- end -}}
    {{- /* Mesma regra do pool worker: o Hive reparte o minimo entre os MachineSets (um por zona). */ -}}
    {{- if and (gt (int $as.minReplicas) 0) (lt (int $as.minReplicas) (len $zonas)) -}}
      {{- fail (printf "\n\n%s: autoscaling.minReplicas = %d, mas o pool esta espalhado por %d zonas.\nO Hive cria um MachineSet por zona e reparte o minimo entre eles: com menos\nde %d, alguma zona ficaria sem instrucao valida.\nUse minReplicas >= %d (ou 0, para permitir escalar ate zero).\n" $rotulo (int $as.minReplicas) (len $zonas) (len $zonas) (len $zonas)) -}}
    {{- end -}}
  {{- else -}}
    {{- if not (hasKey $p "replicas") -}}
      {{- fail (printf "\n\n%s: sem replicas e sem autoscaling.enabled.\nDeclare o tamanho do pool -- replicas: 0 tambem vale, para criar o pool vazio.\n" $rotulo) -}}
    {{- end -}}
    {{- if lt (int $p.replicas) 0 -}}
      {{- fail (printf "\n\n%s: replicas negativo (%d).\n" $rotulo (int $p.replicas)) -}}
    {{- end -}}
  {{- end -}}
  {{- if and $p.labels (not (kindIs "map" $p.labels)) -}}
    {{- fail (printf "\n\n%s: labels tem que ser um mapa chave: valor.\nex:\n  labels:\n    node-role.kubernetes.io/infra: \"\"\n" $rotulo) -}}
  {{- end -}}
  {{- /*
    TAINTS -- o Kubernetes aceita no MachinePool um effect digitado errado e so
    o no recusa depois. Resultado: o pool sobe SEM a taint e passa a receber
    qualquer pod do cluster.
  */ -}}
  {{- if $p.taints -}}
    {{- if not (kindIs "slice" $p.taints) -}}
      {{- fail (printf "\n\n%s: taints tem que ser lista (- key: ... effect: ...).\n" $rotulo) -}}
    {{- end -}}
    {{- range $t := $p.taints -}}
      {{- if or (not (kindIs "map" $t)) (not $t.key) (not (has (toString $t.effect) (list "NoSchedule" "PreferNoSchedule" "NoExecute"))) -}}
        {{- fail (printf "\n\n%s: taint invalida: %v\nCada taint precisa de key e de effect = NoSchedule | PreferNoSchedule | NoExecute.\n" $rotulo $t) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end -}}
