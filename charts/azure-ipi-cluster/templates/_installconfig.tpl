{{/*
  ===========================================================================
   O MANIFESTO DO openshift-install
  ---------------------------------------------------------------------------
   Este e exatamente o install-config.yaml que o openshift-install usaria numa
   instalacao IPI manual. O Hive le o Secret gerado por 01-install-config-secret
   (chave install-config.yaml) e dispara o instalador dentro de um Job no hub.

   pullSecret e sshKey ficam vazios de proposito: o Hive os substitui pelo
   conteudo de spec.pullSecretRef e spec.provisioning.sshPrivateKeySecretRef
   do ClusterDeployment. Nenhum segredo neste arquivo, nenhum segredo no Git.
  ===========================================================================
*/}}
{{- define "azure-ipi-cluster.installConfig" -}}
{{- $p := .Values.provision -}}
apiVersion: v1
metadata:
  name: {{ .Values.clusterName }}
baseDomain: {{ .Values.baseDomain }}
controlPlane:
  name: master
  architecture: amd64
  hyperthreading: Enabled
  replicas: {{ $p.controlPlane.replicas }}
  platform:
    azure:
      type: {{ $p.controlPlane.type }}
      osDisk:
        diskSizeGB: {{ $p.controlPlane.osDisk.diskSizeGB }}
        diskType: {{ $p.controlPlane.osDisk.diskType }}
      {{- with $p.controlPlane.zones }}
      zones:
        {{- toYaml . | nindent 8 }}
      {{- end }}
compute:
  - name: worker
    architecture: amd64
    hyperthreading: Enabled
    replicas: {{ $p.compute.replicas }}
    platform:
      azure:
        type: {{ $p.compute.type }}
        osDisk:
          diskSizeGB: {{ $p.compute.osDisk.diskSizeGB }}
          diskType: {{ $p.compute.osDisk.diskType }}
        {{- with $p.compute.zones }}
        zones:
          {{- toYaml . | nindent 10 }}
        {{- end }}
networking:
  networkType: {{ $p.networking.networkType }}
  {{- /*
    Os tres campos abaixo aceitam DOIS formatos, porque o nome e igual ao do
    install-config, onde sao listas -- e e natural preenche-los assim:

      clusterNetwork: "10.128.0.0/14"          # escalar (forma curta)
      clusterNetwork:                          # lista (forma do install-config)
        - cidr: 10.128.0.0/14
          hostPrefix: 23

    Sem este tratamento, uma lista era interpolada como texto e virava
    "- cidr: [map[cidr:10.128.0.0/14]]", quebrando o YAML com
    "did not find expected ',' or ']'".
  */}}
  clusterNetwork:
  {{- if kindIs "slice" $p.networking.clusterNetwork }}
    {{- toYaml $p.networking.clusterNetwork | nindent 4 }}
  {{- else }}
    - cidr: {{ $p.networking.clusterNetwork }}
      hostPrefix: {{ $p.networking.hostPrefix }}
  {{- end }}
  machineNetwork:
  {{- if kindIs "slice" $p.networking.machineNetwork }}
    {{- toYaml $p.networking.machineNetwork | nindent 4 }}
  {{- else }}
    - cidr: {{ $p.networking.machineNetwork }}
  {{- end }}
  serviceNetwork:
  {{- if kindIs "slice" $p.networking.serviceNetwork }}
    {{- toYaml $p.networking.serviceNetwork | nindent 4 }}
  {{- else }}
    - {{ $p.networking.serviceNetwork }}
  {{- end }}
platform:
  azure:
    region: {{ $p.azure.region }}
    cloudName: {{ $p.azure.cloudName }}
    baseDomainResourceGroupName: {{ $p.azure.baseDomainResourceGroupName }}
    {{- if $p.azure.virtualNetwork }}
    # ---- BYO VNet: instalador NAO cria rede, usa a existente ----
    networkResourceGroupName: {{ $p.azure.networkResourceGroupName }}
    virtualNetwork: {{ $p.azure.virtualNetwork }}
    controlPlaneSubnet: {{ $p.azure.controlPlaneSubnet }}
    computeSubnet: {{ $p.azure.computeSubnet }}
    {{- end }}
    outboundType: {{ $p.azure.outboundType }}
publish: {{ $p.publish }}
fips: {{ $p.fips }}
pullSecret: ""
sshKey: ""
{{- end -}}
