# Roteiro da demo · ACS para o time de segurança

**Duração:** ~45 min + perguntas · **Público:** segurança da informação, risco, auditoria
**Mensagem central:** *o time de segurança escreve a regra uma vez; a plataforma faz cumprir,
mede e gera evidência — em todos os clusters, sem virar gargalo da entrega.*

| # | Bloco | Tempo | KPIs |
|---|---|---|---|
| 0 | Abertura: Scorecard e as 4 perguntas | 5 min | — |
| D | Nenhum cluster sem cobertura | 5 min | RSK-02 |
| B | Política de segurança é código | 6 min | EST-03, RSK-01 |
| **A** | **Fase central: do commit à violação** (5 violações e a versão final) | **20 min** | RSK-03, 04, 05, 06, 09 |
| E | Evidência para auditoria | 4 min | RSK-01 |
| F | Jornada de Fundação ao vivo | 3 min | os 8 |

---

## Preparação (D-1)

> Tudo tem escopo restrito ao namespace `pagamentos-demo`. Nenhuma outra carga é afetada.

1. **Ambiente:** hub com ACM + OpenShift GitOps + ACS Central (namespace `rhacs-operator`; o SecuredCluster fica em `stackrox`) e ao menos
   um cluster gerenciado. ACS ≥ 4.6 (SecurityPolicy como CR).
2. **Admission controller:** no `SecuredCluster` do cluster da demo, confira que o enforcement está
   ligado para create, update e eventos (exec):
   ```bash
   oc -n stackrox get securedcluster -o yaml | grep -A8 admissionControl
   ```
3. **RBAC do Argo CD e Applications:**
   ```bash
   oc apply -f seguranca/acs/rbac/argocd-securitypolicies.yaml
   oc apply -f seguranca/argocd/app-acs-policies.yaml
   oc apply -f seguranca/argocd/app-pagamentos-demo.yaml      # auto-sync + selfHeal
   ```
4. **Confira as políticas no Central:** *Platform Configuration › Policy Management*, filtro
   `DEMO -`. Devem aparecer 5 políticas, com o selo de gerenciadas externamente.
5. **Gate de build (`roxctl-check.sh`):**
   - **Crie o namespace da demo antes.** As políticas DEMO têm *scope* em `pagamentos-demo`, e o
     script avalia a imagem *no contexto* desse namespace (`--cluster` + `--namespace`). Sem
     contexto, o Central ignora políticas com scope e **tudo é aprovado**; com o namespace
     inexistente, o check falha com `not found: namespace`. O Argo CD adota o namespace no sync.
     ```bash
     oc apply -f seguranca/demo-apps/pagamentos-demo/00-namespace.yaml
     ```
   - **Credenciais:** token em *Platform Configuration › Integrations › API Token* (papel
     *Continuous Integration* para o gate, *Analyst* para o script de KPIs). Em laboratório, a senha
     do admin também serve (`ROX_ADMIN_PASSWORD`, secret `central-htpasswd` em `rhacs-operator`).
   - **Teste os três resultados possíveis:**
     ```bash
     export ROX_ENDPOINT=central-rhacs-operator.apps.<cluster>:443 ROX_API_TOKEN=<token>
     # ROX_CLUSTER é lido do SecuredCluster via oc; defina se não estiver logado no cluster
     ./seguranca/pipeline/roxctl-check.sh; echo "exit=$?"                     # BARRADA  (exit 1)
     ./seguranca/pipeline/roxctl-check.sh registry.access.redhat.com/ubi9/ubi-minimal:9.8; echo "exit=$?"  # APROVADA (exit 0)
     ./seguranca/pipeline/roxctl-check.sh registry.access.redhat.com/ubi9/ubi-minimal:latest; echo "exit=$?"  # BARRADA pela tag (exit 1)
     ```
   - **Critério do script:** a imagem é **BARRADA** quando viola ao menos uma política com
     enforcement de build (coluna `BLOQ. = SIM`); violações marcadas `-` são só alerta e **não**
     reprovam. **Exit 2 = ERRO** (conexão, token, namespace): o check não rodou e não conta como barrada.
   - "Componentes vulneráveis: 0" na 9.8 é esperado: o resumo conta só componentes **com** CVE.
     Se a 9.8 passar a reprovar, saiu CVE nova corrigível: use a tag mais recente
     (`skopeo list-tags docker://registry.access.redhat.com/ubi9/ubi-minimal`).
6. **GitHub Actions (opcional):** cadastre `ROX_ENDPOINT` e `ROX_API_TOKEN` como secrets e
   `ROX_CLUSTER` como variable do repositório (nome do cluster no ACS).
   O Central precisa ser alcançável pela internet; se não for, use o script local.
7. **Demo D (cobertura):** no hub, siga os pré-requisitos do cabeçalho de
   `seguranca/acm/policy-acs-cobertura.yaml`: secret `acs-crs` e ConfigMap `acs-central`, ambos em
   `acm-policies`. Depois aplique o arquivo. Confira:
   ```bash
   oc -n acm-policies get placement placement-acs-frota      # SUCCEEDED=True, SELECTEDCLUSTERS >= 1
   oc -n acm-policies get policy acs-secured-cluster         # Compliant
   ```
   - `NoManagedClusterSetBindings` no Placement = falta o `ManagedClusterSetBinding` (já vem no arquivo,
     ligando o ClusterSet `global` ao namespace `acm-policies`).
   - Cluster que **já tem ACS** converge sem reinstalar: o CR usa o mesmo nome
     (`stackrox-secured-cluster`) e o `OperatorPolicy` aceita o OperatorGroup existente. A política
     aplica, porém, a configuração do admission controller (`enforcement: Enabled`) nesses clusters.
   - Para mostrar a **instalação acontecendo** é preciso um cluster gerenciado ainda sem ACS
     (~10 min até o Sensor ficar saudável). Sem ele, a demo mostra a cobertura já `Compliant`.
   - A CRS vale 30 dias (`roxctl central crs list`); gere outra antes de importar clusters novos depois disso.
8. **Demo E:** aplique `seguranca/acm/policy-compliance-pci.yaml` na véspera — a primeira varredura
   leva alguns minutos e você quer resultado pronto.
9. **Linha de base dos KPIs:**
   ```bash
   export ROX_ENDPOINT=central-rhacs-operator.apps.<hub>:443
   export ROX_API_TOKEN=<API Token do ACS com papel Analyst>
   export OC_CONTEXT=<contexto do hub no kubeconfig>   # só se o oc atual não for o hub
   ./seguranca/kpis/coletar-kpis.sh --csv > antes.csv
   ```
   - **Token:** precisa ser um *API Token* do ACS com papel **Analyst**. Token com papel
     *Continuous Integration* recebe 403 em alertas, clusters e políticas. Token do OpenShift
     (`oc whoami -t`, `sha256~…`) não é aceito pelo Central. O script avisa e para nos dois casos.
     Em laboratório, `ROX_ADMIN_PASSWORD` também funciona.
   - **Hub:** RSK-01, RSK-02 e EST-03 leem do ACM. Se o `oc` estiver em outro cluster (ex.: depois de
     um `oc login` no ROSA), o script avisa e esses três saem `n/d`. Use `OC_CONTEXT`.
   - **Escopo:** violações em namespaces de plataforma (`openshift-*`, `kube-*`, ACM/MCE, `stackrox`…)
     ficam fora de RSK-03/04/06/09, senão as políticas padrão dominam a conta. Ajuste com `EXCLUIR_NS`.
   - Antes da demo é normal RSK-03/04/05/06/09 saírem 0 ou `n/d`: ainda não houve violação nos
     namespaces de aplicação. É o contraste com o "depois".
10. **Abas abertas:** Scorecard (Jornada de Fundação); no ACS: *Violations*, *Vulnerability
    Management › Results*, *Risk*, *Compliance › OpenShift Coverage* e *Platform Configuration ›
    Policy Management*; Argo CD (`pagamentos-demo`, `acs-security-policies`); ACM (Governance);
    GitHub (branch `seguranca`); terminal.
    > Nomes de menu conferidos no ACS 4.11. Em versões ≤ 4.6 a página de CVEs se chamava
    > *Workload CVEs* e o relatório, *Vulnerability Reporting*.
11. **Scan delegado:** em *Platform Configuration › Clusters › Delegated image scanning*, deixe
    **All registries** com o hub como cluster padrão. Sem isso, o Central pode guardar imagens com
    **0 CVEs** (visto no laboratório com a `ubi8:8.0`) e o admission controller deixa tudo passar.
12. **Estado inicial da fase central:**
    ```bash
    ./seguranca/demo-apps/etapa.sh 00
    ```
    Deixa o `pagamentos-api` na versão inicial (aceitável). Em *Violations › User Workloads ›
    Active*, filtro `Namespace: pagamentos-demo`, não pode haver nenhuma política `DEMO -`.
    Se houver violação de **runtime** antiga, abra e clique **Mark as resolved**.
13. **Ensaio completo (obrigatório, ~12 min):** rode `etapa.sh` de `01` a `06` exatamente como na
    demo e confira cada resultado com a tabela da seção A. Termine com `etapa.sh 00`.
    - Cada etapa gera um commit `demo(etapa NN): …` na branch `seguranca`. É esperado e serve de
      histórico. Para ensaiar sem poluir o histórico, use um fork ou uma branch de ensaio e aponte
      a Application para ela.
    - **Se a etapa 01 não gerar violação de CVE:** a imagem pode estar em cache sem CVEs. Não há
      botão de rescan, e o `roxctl image scan --force` não substitui o cache. Apague o registro e o
      próximo uso reescaneia pela delegação (passo 11):
      ```bash
      curl -sk -u admin:$ROX_ADMIN_PASSWORD -G -X DELETE "https://$ROX_ENDPOINT/v1/images" \
        --data-urlencode "query.query=Image:<imagem>" --data-urlencode confirm=true
      ```

---

## 0 · Abertura (5 min)

Mostre o **Scorecard DevSecOps · Segurança**, seção *Resumo executivo* e *Jornada de Fundação*.

> "Não viemos mostrar mais um scanner. Viemos mostrar como a regra que vocês escrevem passa a valer
> sozinha em todos os clusters — e como vocês provam isso com números. Vou organizar a conversa em
> quatro perguntas que todo time de segurança faz: **o que eu vejo, o que eu bloqueio, quão rápido eu
> corrijo e como eu provo.** Cada uma tem dois indicadores, e cada demo vai mexer em pelo menos um."

---

## D · Nenhum cluster sem cobertura (5 min) — RSK-02

**Mostrar:** ACM › Governance › política `acs-secured-cluster` e ACS › Platform Configuration › Clusters.

> "O primeiro risco é o cluster que ninguém lembra que existe. Aqui a instalação do ACS é uma política
> do ACM: cluster que entra na frota recebe o operador, a credencial e o agente. E a terceira parte só
> *informa* se o Sensor está de pé — isso vira o RSK-02, cobertura de segurança."

- Abra `seguranca/acm/policy-acs-cobertura.yaml` no GitHub: 3 templates (operador, CRS + `SecuredCluster`,
  Sensor saudável) e um Placement com toda a frota, exceto o hub.
- ACM › Governance › `acs-secured-cluster`: aba *Clusters*, com `<cluster-gerenciado>` `Compliant` nos 3 templates.
- ACS › Platform Configuration › Clusters: o mesmo cluster `Healthy`. São duas ferramentas contando a
  mesma história.
- Se houver cluster sem ACS no laboratório: importe-o ao vivo e mostre a política instalando o ACS. É o
  ponto cego sendo fechado sem ticket.
  > "Não existe um 'cluster novo esquecido': o ACM instala, o ACS registra, e a política mede."
- **Gancho:** "Cobertura é o denominador de todos os outros KPIs. 90% de cobertura significa que
  10% do risco nem entra na conta."

---

## B · Política de segurança é código (6 min) — EST-03, RSK-01

**Mostrar:** GitHub (`seguranca/acs/policies/`) → Argo CD (`acs-security-policies`) → ACS Policy Management.

1. Abra `10-cve-corrigivel-bloqueada.yaml`: nome, justificativa, remediação, critérios e enforcement —
   **legível por quem não é de plataforma**.
2. No ACS, abra a mesma política: aparece como gerenciada externamente e **não pode ser editada na UI**.
   > "A fonte da verdade é o Git. Ninguém afrouxa uma política às 23h pela console: tem PR, revisão
   > e histórico. Isso é controle de mudança que o auditor reconhece."
3. **Ao vivo (opcional):** edite pelo GitHub a severidade de `20-tag-latest-proibida.yaml`, faça
   commit na branch `seguranca`, clique *Refresh* no Argo CD e mostre a mudança no Central.
   > "Do commit à frota inteira em minutos. Esse é o EST-03: tempo para adotar um novo padrão."
4. **Prova de drift:** tente apagar a política direto no cluster:
   ```bash
   oc -n rhacs-operator delete securitypolicy demo-tag-latest-proibida
   ```
   O Argo CD (`selfHeal`) recria em segundos.

---

## A · Fase central: do commit à violação (20 min) — RSK-03, 04, 05, 06, 09

**A ideia:** o apresentador faz o papel do time de desenvolvimento. Cada commit muda o Deployment do
`pagamentos-api`, o Argo CD sincroniza sozinho (auto-sync) e o ACS mostra, em cerca de 1 minuto, o
que aquela versão violou. São **5 violações, uma por política DEMO**, e depois a **versão final**,
que deixa tudo limpo. Cada versão nova também **resolve** a violação da anterior, e isso aparece
na aba *Resolved*.

### Antes de começar: o que fica aberto e como ler

| Janela | O que mostrar |
|---|---|
| Terminal | `./seguranca/demo-apps/etapa.sh NN`: mostra a etapa, faz commit/push, espera o sync e diz o que olhar |
| GitHub | o commit `demo(etapa NN): …` e o diff do `10-deployment.yaml` |
| Argo CD | app `pagamentos-demo`: revisão nova, `Synced` |
| ACS › **Violations** | subaba **User Workloads**; abas **Active**, **Resolved** e **Attempted**; filtro `Namespace: pagamentos-demo` |

> **Por que o Argo CD não é barrado (diga isso ao cliente, não esconda):** o admission controller do
> ACS não bloqueia requests de service accounts de namespaces `openshift-*`, e o Argo CD padrão do
> OpenShift GitOps roda em `openshift-gitops`. Por isso, nesta fase o ACS **detecta e registra**
> cada violação (com a ação de enforcement que tomaria), mas o sync acontece. O bloqueio real
> aparece em três pontos da demo: no **pipeline** (etapa 01), no **`oc apply` humano** (etapa 03) e
> no **`exec`** (etapa 05). Recomendação para produção: Argo CD padrão só para configuração do
> cluster e uma **instância dedicada, fora de `openshift-*`**, para as aplicações. Ela é barrada
> pelo admission como qualquer outro usuário.

### Etapa 00 · ponto de partida (já preparado na D-1)
Mostre o Argo CD `Synced` e o ACS sem nenhuma `DEMO -` ativa.
> "Essa é a API de pagamentos em produção, entregue por GitOps e limpa. Agora vou fazer o papel do
> time de desenvolvimento, e cada commit meu vai introduzir um tipo de problema."

### Etapa 01 · CVE crítica com correção: Log4Shell — RSK-05, RSK-04
```bash
./seguranca/pipeline/roxctl-check.sh        # primeiro: o que o pipeline diria desta imagem
./seguranca/demo-apps/etapa.sh 01
```
- **Pipeline:** `RESULTADO: BARRADA no build`. Na tabela aparecem a `DEMO - CVE corrigível…`
  (BLOQ. = SIM) e, como alerta, as nativas **Log4Shell** e **Spring4Shell** (CRITICAL).
- **ACS › Violations › Active (~1 min):** `DEMO - CVE corrigível Importante ou Crítica`, *Log4Shell:
  log4j Remote Code Execution vulnerability* e *Spring4Shell*, estágio **Deploy**.
- **ACS › Vulnerability Management › Results › User Workloads** (`Namespace: pagamentos-demo`, *CVE
  status* = Fixable, *CVE severity* = Critical): 11 Críticas, entre elas **CVE-2021-44228 (CVSS 10)**
  em `log4j 2.14.1`, que é corrigida na `2.15.0`.
- **ACS › Risk › User Workloads:** o `pagamentos-api` sobe no ranking (Priority 1 = maior risco).
> "Se o pipeline usasse esse gate, essa imagem nem chegaria ao Git. Como chegou, o ACS reconheceu a
> Log4Shell pelo nome em menos de um minuto, com a versão que corrige. Não é uma lista de CVEs para
> pânico: é a fila do que tem correção hoje."

*Segurança da demo:* a variação troca o `java` da imagem por `sleep`. A imagem vulnerável está no
cluster, que é o que o ACS avalia, mas a aplicação explorável não sobe. Não há Service nem Route.

### Etapa 02 · tag `latest` — rastreabilidade
```bash
./seguranca/demo-apps/etapa.sh 02
```
- **Active:** `DEMO - Tag latest proibida` (e a nativa *Latest tag*).
- **Resolved:** as três da etapa 01. A imagem com Log4Shell saiu, e o ACS fechou sozinho.
> "Corrigiram a CVE, mas agora a imagem é 'latest': amanhã ninguém sabe o que está rodando, nem
> consegue voltar. E vejam a aba Resolved: o ACS fechou as violações da Log4Shell sozinho quando a
> imagem saiu. Ninguém precisou atualizar planilha."

### Etapa 03 · container privilegiado — RSK-03
```bash
./seguranca/demo-apps/etapa.sh 03
oc apply -f seguranca/demo-apps/variacoes/privilegiado.yaml     # contraste: um humano tentando o mesmo
```
- **Active:** `DEMO - Container privilegiado em namespace PCI` (CRITICAL), mais as nativas
  *Privileged Container* e *Container with privilege escalation allowed*.
- **Cluster:** `FailedCreate`, porque a SCC `restricted-v2` não permite `privileged`. O rolling update
  trava e a **versão anterior continua atendendo**. O Argo CD fica `Synced`, mas não `Healthy`.
- **Contraste humano:** o `oc apply` é **negado** no terminal (`Failed currently enforced policies
  from RHACS`) e aparece em **Violations › Attempted**, com `FAIL_DEPLOYMENT_CREATE_ENFORCEMENT`.
> "Duas camadas: o ACS registrou a violação, e a plataforma não deixou o pod rodar. Quando um humano
> tenta o mesmo com `oc apply`, o ACS recusa na hora, e a tentativa fica registrada mesmo sem o
> objeto existir. É o RSK-03, deploys inseguros barrados."

### Etapa 04 · runtime: ferramenta de rede em execução — RSK-09
```bash
./seguranca/demo-apps/etapa.sh 04          # aguarde ~1 min depois do sync
```
- **Active:** `DEMO - Ferramenta de rede executada em pod de pagamentos`, estágio **Runtime**. Abra a
  violação: processo `curl`, argumentos, pod, contêiner e horário.
- **Resolved:** as de privilégio da etapa 03.
> "Essa versão é 'limpa' no papel: imagem atual, sem privilégio, tag fixa. O problema é o que ela
> FAZ: baixa coisas da internet em runtime. Nenhum scanner de imagem pega isso; só quem vê o
> processo rodando. Para quem procura exfiltração ou pós-exploração, é esse sinal que importa."

### Etapa 05 · runtime: exec no pod, mudança fora do Git — RSK-09
```bash
./seguranca/demo-apps/etapa.sh 05          # executa o oc exec ao vivo; não há commit
```
- **Terminal:** o `exec` é **recusado** (`admission webhook "k8sevents.stackrox.io" denied the
  request … DEMO - Exec em pod de pagamentos`).
- **Violations › Attempted:** a tentativa, com `FAIL_KUBE_REQUEST_ENFORCEMENT`.
> "Alguém tentou 'consertar rapidinho' em produção. Em ambiente PCI, isso é mudança sem revisão. O
> ACS recusou e registrou quem, quando e onde. A mudança tem que ir pelo Git, como todas as outras."

### Etapa 06 · versão final: tudo limpo — RSK-06
```bash
./seguranca/demo-apps/etapa.sh 06
```
- **Resolved:** todas as violações de **Deploy** das etapas anteriores. A versão final ainda
  endurece a inicial (sem token de service account montado), e com isso a nativa *Pod Service
  Account Token Automatically Mounted* também resolve.
- **Ainda Active:** a de **runtime** da etapa 04 (`curl`). Violação de runtime registra um **evento
  que aconteceu**, e por isso não some com uma versão nova. Abra a violação e clique **Mark as
  resolved**. **Não** use *Resolve and add to process baseline*, que passaria a considerar o `curl`
  normal para esse deployment.
- **Resultado:** nenhuma `DEMO -` ativa. Resta só *Docker CIS 4.1* (LOW, informativo: a imagem
  base declara usuário root, mas o OpenShift executa com UID aleatório).
> "Detecção, correção por commit, tudo resolvido e com rastro no Git. O tempo entre a primeira
> violação e este commit é o RSK-06. E o evento de runtime passou por triagem humana, que é como
> deve ser."

### Se algo não acontecer como descrito
| Sintoma | Causa provável | Ação |
|---|---|---|
| `etapa.sh` fica esperando o sync | Argo CD sem acesso ao GitHub ou app sem auto-sync | `oc -n openshift-gitops get applications.argoproj.io pagamentos-demo` e reaplicar `seguranca/argocd/app-pagamentos-demo.yaml` |
| Etapa 01 sem violação de CVE | imagem em cache sem CVEs | apagar o registro (passo 13 da preparação) e repetir `etapa.sh 01` |
| Etapa 04 sem violação após 2 min | o Collector ainda não viu o `curl` (roda a cada 30 s) | aguardar mais 1 min; conferir o pod `Running` |
| `exec` não é recusado | admission sem eventos (`k8sevents.stackrox.io` ausente) | `oc get validatingwebhookconfiguration stackrox` e passo 2 da preparação |

---

## E · Evidência para auditoria (4 min) — RSK-01

ACS › **Compliance › OpenShift Coverage** (perfil `ocp4-pci-dss`; as varreduras ficam em
*Compliance › OpenShift Schedules*) e ACM › Governance (`compliance-pci-dss`).
> "Dois públicos, a mesma fonte: o time de segurança vê controle por controle; plataforma vê
> cluster por cluster. Exporta CSV para o auditor. Evidência deixa de ser projeto e vira consulta."

---

## F · Jornada de Fundação ao vivo (3 min)

```bash
./seguranca/kpis/coletar-kpis.sh          # mesmas variáveis do passo 9 da preparação
```
Compare com `antes.csv`. Destaque o **EST-03**: do commit da política à política valendo no Central
leva segundos (medido no laboratório: ~11 s). Volte ao Scorecard, seção *Jornada de Fundação*, e proponha:
> "Na próxima reunião, preenchemos juntos a linha de base e as metas de 6 e 12 meses para esses
> oito números. Quem de vocês seria o responsável por cada um?"

**Próximo passo concreto:** workshop de 2 h para linha de base + metas (etapa 2 do *Como medir*).

---

## Objeções frequentes

| Objeção | Resposta |
|---|---|
| "Já temos scanner de imagem." | Scanner mostra o problema; o ACS **impede** o deploy, detecta em runtime e prova cobertura da frota. Os KPIs RSK-03, RSK-09 e RSK-02 não saem de um scanner. |
| "Mas o Argo CD passou!" | O Argo CD padrão roda em `openshift-gitops`, isento do admission. O ACS detectou e registrou cada violação. Em produção, entregue as aplicações por uma instância de Argo CD dedicada, fora de `openshift-*`, e ela é barrada como qualquer usuário. O pipeline com `roxctl` barra antes do commit. |
| "Admission controller vai derrubar produção." | Comece em modo *inform* (sem `enforcementActions`), meça RSK-03/RSK-04 por 30 dias e ative enforcement política a política. Há break-glass por anotação, auditado. |
| "Muito falso positivo." | Use *Fixable* + severidade como critério: só o que tem correção. Exceções viram *exceptions* com prazo, aprovadas por PR. |
| "Quem é dono das políticas: segurança ou plataforma?" | Segurança é *code owner* de `acs/policies/` no Git; plataforma revisa o impacto. O PR é o contrato entre os dois. |
| "E os clusters em outras nuvens?" | A política do ACM vale para qualquer cluster gerenciado (on-prem, ARO, ROSA, GCP). RSK-02 mede exatamente isso. |
| "Como isso entra no SIEM?" | Notifiers nativos (Splunk, Syslog, Sumo, AWS Security Hub, webhook genérico) por política. |

---

## Limpeza

```bash
oc delete -f seguranca/argocd/app-pagamentos-demo.yaml -f seguranca/argocd/app-acs-policies.yaml
oc delete ns pagamentos-demo
oc -n rhacs-operator delete securitypolicy -l app.kubernetes.io/instance=acs-security-policies --ignore-not-found
```
