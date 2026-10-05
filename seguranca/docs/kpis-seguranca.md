# Os 8 KPIs para o time de segurança

Recorte da Jornada de Fundação do **Scorecard DevSecOps (alpha)** para convencer uma equipe de
segurança. Critérios da escolha:

1. **Fala a língua de quem responde por risco**: exposição, prevenção, tempo de resposta e evidência.
2. **Sai da ferramenta, ao vivo**: todos vêm do ACS Central ou do ACM Governance, então dá para mostrar
   o número na própria demo (`seguranca/kpis/coletar-kpis.sh`), sem planilha.
3. **Tem uma demo que mexe nele**: o time vê o número mudar por causa de algo que aconteceu na tela.

Os oito respondem a quatro perguntas que todo CISO faz:

| Pergunta | KPI | Nome | Direção | Demo |
|---|---|---|---|---|
| **Visibilidade** — o que eu vejo? | RSK-02 | Cobertura de segurança | ↑ | D |
| | RSK-05 | CVEs críticas corrigíveis em produção | ↓ | A, C |
| **Prevenção** — o que eu barro? | RSK-03 | Deploys inseguros barrados | ↑ | A |
| | RSK-04 | Shift-left de segurança | ↑ | A |
| **Resposta** — quão rápido eu corrijo? | RSK-06 | Tempo para remediar CVE crítica | ↓ | C |
| | RSK-09 | Mudanças fora do Git | ↓ | C |
| **Governança** — como eu provo? | RSK-01 | Conformidade da frota | ↑ | B, E |
| | EST-03 | Tempo para adotar um novo padrão | ↓ | B |

> Esta seleção concentra-se em Risco e Melhorias Estratégicas de propósito. Se a reunião tiver
> público executivo, acrescente **REC-04** (tempo de aprovação de segurança — segurança deixa de ser
> gargalo do go-live) e **EFC-10** (esforço de auditoria em horas-pessoa). Os dois dependem do ITSM e
> não aparecem ao vivo.

---

## Ficha de cada KPI

### RSK-02 · Cobertura de segurança — *"não se protege o que não se vê"*
- **Fórmula:** clusters com Secured Cluster saudável ÷ clusters gerenciados pelo ACM
- **Categoria:** ACM ManagedClusters × ACS Clusters (`/v1/clusters`, `healthStatus`)
- **Por que segurança se importa:** o ponto cego é o cluster criado "rapidinho" para um projeto e
  esquecido. Com a política do ACM (Demo D), cobertura deixa de ser checklist e vira conformidade
  medida: cluster sem Sensor aparece como `NonCompliant`.
- **Meta típica:** 100%, com alerta para qualquer queda.

### RSK-05 · CVEs críticas corrigíveis em produção — *"risco aceito sem decisão"*
- **Fórmula:** nº de CVEs Críticas/Importantes **com correção disponível** em workloads de produção
- **Categoria:** ACS Vulnerability Management; relatórios agendados
- **Por que segurança se importa:** separa o que o time **pode** corrigir hoje do ruído de CVEs sem
  correção. É a lista de trabalho, não a lista de pânico.
- **Leitura:** deve cair mês a mês. Se não cai, falta processo de remediação, não ferramenta.

### RSK-03 · Deploys inseguros barrados — *"quantas vezes a regra funcionou sozinha"*
- **Fórmula:** builds reprovados pelo `roxctl` + deploys bloqueados pelo admission controller, por mês
- **Categoria:** logs do pipeline; ACS Violations (estado `ATTEMPTED` / enforcement)
- **Por que segurança se importa:** cada número é um incidente potencial que não precisou de gente.
- **Atenção:** tende a **subir** no início (ganho de visibilidade) e **cair** depois, quando os times
  corrigem na origem. Leia sempre junto com RSK-04.

### RSK-04 · Shift-left de segurança — *"pegar cedo custa menos"*
- **Fórmula:** violações em build + deploy ÷ total de violações (build + deploy + runtime)
- **Categoria:** ACS Violations por lifecycle stage + resultado do CI
- **Por que segurança se importa:** prova que o controle está saindo da produção e indo para a esteira.
- **Meta típica:** acima de 80% das violações antes do runtime.

### RSK-06 · Tempo para remediar CVE crítica — *"MTTR de vulnerabilidade"*
- **Fórmula:** média de dias entre a detecção e o deploy da imagem corrigida
- **Categoria:** relatórios ACS + histórico Git/Argo CD (no script: tempo de vida das violações de CVE
  corrigível resolvidas na janela)
- **Por que segurança se importa:** é o número que auditoria e reguladores pedem (ex.: PCI-DSS 6.3.3
  exige patches críticos em até 1 mês). Com GitOps, corrigir é um PR — o tempo cai de semanas para dias.

### RSK-09 · Mudanças fora do Git — *"quem mexeu em produção sem PR?"*
- **Fórmula:** nº de ações diretas detectadas (exec, port-forward, acesso a Secret) por mês
- **Categoria:** ACS Violations (runtime e audit log)
- **Por que segurança se importa:** cada exec é uma mudança sem revisão em ambiente regulado. O ACS
  detecta, registra quem/quando/onde e pode até recusar o comando.

### RSK-01 · Conformidade da frota — *"a evidência já está pronta"*
- **Fórmula:** clusters sem violação no baseline ÷ total de clusters
- **Categoria:** ACM Governance (`policy_governance_info`); ACS Compliance (CIS, PCI-DSS, NIST)
- **Por que segurança se importa:** substitui a coleta manual de evidências por um painel contínuo
  que o auditor pode consultar.

### EST-03 · Tempo para adotar um novo padrão — *"da decisão à frota inteira"*
- **Fórmula:** dias entre publicar a política no Git e 100% da frota cumprindo
- **Categoria:** Git + ACS (status da `SecurityPolicy`) + ACM Governance
- **Por que segurança se importa:** quando sai uma nova exigência (nova CVE explorada, novo controle
  de auditoria), o time de segurança escreve a regra uma vez e ela vale em todos os clusters em
  minutos — com PR, revisão e histórico.

---

## Como coletar

```bash
export ROX_ENDPOINT=central-stackrox.apps.<hub>:443
export ROX_API_TOKEN=<token somente leitura>
oc login <hub>                                   # para RSK-01, RSK-02 e EST-03
./seguranca/kpis/coletar-kpis.sh                 # tabela na tela
./seguranca/kpis/coletar-kpis.sh --csv > linha-de-base-$(date +%F).csv
```

Os números de **build** (RSK-03, RSK-04) não ficam persistidos no Central — informe com
`BUILD_BLOQUEADOS=` e `BUILD_VIOLACOES=` a partir do histórico do CI.
