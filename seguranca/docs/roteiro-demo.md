# Roteiro da demo · ACS para o time de segurança

**Duração:** ~45 min + perguntas · **Público:** segurança da informação, risco, auditoria
**Mensagem central:** *o time de segurança escreve a regra uma vez; a plataforma faz cumprir,
mede e gera evidência — em todos os clusters, sem virar gargalo da entrega.*

| # | Bloco | Tempo | KPIs |
|---|---|---|---|
| 0 | Abertura: Scorecard e as 4 perguntas | 5 min | — |
| D | Nenhum cluster sem cobertura | 5 min | RSK-02 |
| B | Política de segurança é código | 8 min | EST-03, RSK-01 |
| A | Barrar antes de rodar | 10 min | RSK-03, RSK-04, RSK-05 |
| C | Ver, corrigir e detectar | 10 min | RSK-05, RSK-06, RSK-09 |
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
   oc apply -f seguranca/argocd/app-pagamentos-demo.yaml      # NÃO sincronize ainda
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
12. **Estado inicial da aplicação (história: "o legado e a versão nova"):**
    ```bash
    oc apply -f seguranca/demo-apps/variacoes/legado-pagamentos-api.yaml
    ```
    - Cria o `pagamentos-api` **legado** (`ubi8:8.0`, ~1.270 CVEs) com a anotação de **break-glass**,
      porque o ACS já o bloquearia. O bypass fica registrado como violação. Isso também é argumento
      para a demo: existe saída de emergência, e ela é auditada.
    - O Argo CD (`pagamentos-demo`) fica **OutOfSync**, porque o Git já traz a "versão nova" (Log4Shell).
      **Não sincronize**: o Sync é o momento da Demo A.2.
13. **Ensaio do momento-chave (obrigatório):**
    ```bash
    oc apply --dry-run=server -f seguranca/demo-apps/pagamentos-demo/10-deployment.yaml
    # esperado: denied ... DEMO - CVE corrigível ... CVE-2021-44228 (CVSS 10) ... log4j 2.14.1 ... 2.15.0
    ```
    Se passar (`configured (server dry run)`), a imagem está em cache sem CVEs. **Rescan**: não há
    botão na console, e o `roxctl image scan --force` mostra o resultado mas **não** substitui o
    cache. O que funciona é apagar o registro em cache; o próximo uso reescaneia pela delegação:
    ```bash
    curl -sk -u admin:$ROX_ADMIN_PASSWORD -G -X DELETE "https://$ROX_ENDPOINT/v1/images" \
      --data-urlencode "query.query=Image:<imagem>" --data-urlencode confirm=true
    ```
    (Em *Vulnerability Management › Results*, a imagem deve aparecer com CVEs logo depois.)

---

## 0 · Abertura (5 min)

Mostre o **Scorecard DevSecOps · Segurança**, seção *Resumo executivo* e *Jornada de Fundação*.

> "Não viemos mostrar mais um scanner. Viemos mostrar como a regra que vocês escrevem passa a valer
> sozinha em todos os clusters — e como vocês provam isso com números. Vou organizar a conversa em
> quatro perguntas que todo time de segurança faz: **o que eu vejo, o que eu barro, quão rápido eu
> corrijo e como eu provo.** Cada uma tem dois indicadores, e cada demo vai mexer em pelo menos um."

---

## D · Nenhum cluster sem cobertura (5 min) — RSK-02

**Mostrar:** ACM › Governance › política `acs-secured-cluster` e ACS › Platform Configuration › Clusters.

> "O primeiro risco é o cluster que ninguém lembra que existe. Aqui a instalação do ACS é uma política
> do ACM: cluster que entra na frota recebe o operador, a credencial e o agente. E a terceira parte só
> *informa* se o Sensor está de pé — isso vira o RSK-02, cobertura de segurança."

- Abra `seguranca/acm/policy-acs-cobertura.yaml` no GitHub: 3 templates (operador, CRS + `SecuredCluster`,
  Sensor saudável) e um Placement com toda a frota, exceto o hub.
- ACM › Governance › `acs-secured-cluster`: aba *Clusters*, com `blackbird-rosa-4gs5p` `Compliant` nos 3 templates.
- ACS › Platform Configuration › Clusters: o mesmo cluster `Healthy`. São duas ferramentas contando a
  mesma história.
- Se houver cluster sem ACS no laboratório: importe-o ao vivo e mostre a política instalando o ACS. É o
  ponto cego sendo fechado sem ticket.
  > "Não existe um 'cluster novo esquecido': o ACM instala, o ACS registra, e a política mede."
- **Gancho:** "Cobertura é o denominador de todos os outros KPIs. 90% de cobertura significa que
  10% do risco nem entra na conta."

---

## B · Política de segurança é código (8 min) — EST-03, RSK-01

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

## A · Barrar antes de rodar (10 min) — RSK-03, RSK-04, RSK-05

### A.1 · No pipeline (build)
```bash
./seguranca/pipeline/roxctl-check.sh        # padrão: a "versão nova" do pagamentos-api (Log4Shell)
```
Resultado esperado (exit 1):
- **Informativo:** 182 CVEs: **11 Críticas** e 29 Importantes, com amostra
  `CVE · pacote · versão atual -> versão que corrige`.
- **Gate:** `SIM` em `DEMO - CVE corrigível Importante ou Crítica` → `RESULTADO: BARRADA no build`.
  Na mesma tabela, como `-` (só alerta), aparecem as políticas nativas
  **`Log4Shell: log4j Remote Code Execution vulnerability`** e **`Spring4Shell`**, ambas CRITICAL.

> "Essa imagem tem a Log4Shell, CVSS 10, a de dezembro de 2021. O ACS reconhece pelo nome. Reparem
> na coluna BLOQ.: vocês decidem o que **para** o build e o que só **avisa**. Aqui, a regra 'CVE
> corrigível Importante ou Crítica' para; a política nativa de Log4Shell, hoje, só avisa. É uma
> decisão de vocês, por PR."

Em seguida, mostre o contraste com a imagem atual, que passa:
```bash
./seguranca/pipeline/roxctl-check.sh registry.access.redhat.com/ubi9/ubi-minimal:9.8   # APROVADA, exit 0
```
(Ou rode o workflow *ACS image check* no GitHub Actions, que chama este mesmo script.)

> "O desenvolvedor recebe isso no PR, com a versão que corrige. Segurança não precisou abrir ticket."

### A.2 · No deploy — mesmo vindo do GitOps
Contexto: o `pagamentos-api` legado está rodando, e o time de desenvolvimento fez merge da "versão
nova" no Git. O Argo CD mostra `OutOfSync`.
1. No Argo CD, clique **Sync** em `pagamentos-demo`.
2. O Sync **falha**: o admission controller recusa o update, e a mensagem no Argo CD lista as CVEs,
   incluindo `CVE-2021-44228 (CVSS 10) ... log4j 2.14.1 ... resolved by version 2.15.0`. O legado
   continua rodando, intacto:
   ```bash
   oc -n pagamentos-demo get deploy pagamentos-api -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
   # registry.access.redhat.com/ubi8/ubi:8.0  (a versão com Log4Shell não entrou)
   ```
3. ACS › **Violations**, filtro `Namespace: pagamentos-demo`: `DEMO - CVE corrigível...`, estágio
   **Deploy**, com a ação de enforcement registrada.
   > "O GitOps não é um atalho para fugir da política. Ou o Argo entrega algo seguro, ou não entrega."

### A.3 · Tentativas "manuais"
```bash
oc apply -f seguranca/demo-apps/variacoes/privilegiado.yaml   # recusado: container privilegiado
oc apply -f seguranca/demo-apps/variacoes/tag-latest.yaml     # recusado: tag latest
```
Saída esperada: `Failed currently enforced policies from RHACS` com o nome da política.

**Gancho:** "Cada recusa dessas soma no RSK-03. E como foram pegas em build ou deploy, e não em
runtime, elas melhoram o RSK-04, o shift-left."

---

## C · Ver, corrigir e detectar (10 min) — RSK-05, RSK-06, RSK-09

### C.1 · Vulnerabilidades com contexto
ACS › **Vulnerability Management › Results**, aba **User Workloads**. Na barra de filtros:
`Namespace` = `pagamentos-demo`; em *CVE status*, **Fixable**; em *CVE severity*, **Critical** e
**Important**. Aparece o **legado** (`ubi8/ubi:8.0`): ~1.270 CVEs, ~850 corrigíveis. Clique na imagem
para ver CVE por CVE, com a versão que corrige.
> "A versão nova não entrou; mas e o que já estava rodando? Aqui está. Não é uma lista de 1.270
> CVEs para pânico: é quais têm correção, em que deployment e qual versão resolve. Esse é o RSK-05,
> a fila de trabalho real."

Mostre também *Vulnerability Management › Reports*: relatório agendado por e-mail para o dono da
aplicação.

### C.1b · Risco priorizado por contexto
ACS › **Risk**, aba **User Workloads** (não *All Deployments*), ou filtre `Namespace: pagamentos-demo`.
A coluna **Priority** é um ranking: **1 = maior risco**. Clique no deployment para ver os fatores
(*Policy Violations*, *Image Vulnerabilities*, *Components Useful for Attackers*, *Image Freshness*…).
> "O ACS não conta CVEs, ele ordena o que olhar primeiro: CVE corrigível, violação ativa,
> ferramentas úteis para um atacante dentro da imagem. O time de segurança começa pelo topo."

Se o `pagamentos-api` aparecer **no fim** do ranking, o ACS não está enxergando as CVEs da imagem
(ver passos 11 e 13 da preparação).

### C.2 · Corrigir é um PR (RSK-06)
Em `seguranca/demo-apps/pagamentos-demo/10-deployment.yaml`, troque a imagem para
`registry.access.redhat.com/ubi9/ubi-minimal:9.8` e o `command` indicado (os dois estão no comentário
do arquivo), commit, **Sync**. O deploy passa, o Argo CD fica `Synced`, e as violações de CVE do
legado vão para *Resolved*.
> "Detecção → correção → deploy, com rastro no Git. O tempo entre essas duas marcas é o RSK-06."

### C.3 · Runtime: alguém entrou no pod (RSK-09)
```bash
oc apply -f seguranca/demo-apps/variacoes/runtime-ok.yaml
oc -n pagamentos-demo rollout status deploy/pagamentos-worker
oc -n pagamentos-demo exec deploy/pagamentos-worker -- curl -sI https://www.redhat.com
```
- Com enforcement de exec ativo: o comando é **recusado**.
- Sem enforcement (ou em versões sem suporte): o comando roda, e em segundos aparecem as violações
  `DEMO - Exec em pod de pagamentos` e `DEMO - Ferramenta de rede executada...`, com usuário, pod,
  processo e linha de comando.
> "Em ambiente PCI, exec em produção é mudança sem trilha. Agora ela tem nome, hora e alerta — e
> pode ir para o SIEM ou o Slack de vocês via notifier."

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
