# Branch `seguranca` — demo do ACS para o time de segurança

Material da demonstração do **Red Hat Advanced Cluster Security** para convencer uma equipe de
segurança, derivado do **Scorecard DevSecOps (alpha)**. Tudo é entregue por GitOps e tem escopo
restrito ao namespace `pagamentos-demo`.

📖 **[Roteiro da demo](docs/roteiro-demo.md)** · **[Os 8 KPIs](docs/kpis-seguranca.md)**

| Demo | O que mostra | KPIs | Arquivos |
|---|---|---|---|
| D | ACM instala e mede o ACS em toda a frota | RSK-02 | `acm/policy-acs-cobertura.yaml` |
| B | Política de segurança como código (PR → Argo CD → Central) | EST-03 RSK-01 | `argocd/app-acs-policies.yaml`, `acs/` |
| **A** | **Fase central: cada commit viola uma política DEMO, o Argo CD sincroniza e o ACS mostra; a versão final limpa tudo** | RSK-03 04 05 06 09 | `demo-apps/etapa.sh`, `demo-apps/etapas/`, `pipeline/`, `acs/policies/` |
| E | Varredura PCI-DSS no ACS Compliance e no ACM Governance | RSK-01 | `acm/policy-compliance-pci.yaml` |
| F | Os 8 KPIs extraídos ao vivo | todos | `kpis/coletar-kpis.sh` |

```bash
oc apply -f seguranca/acs/rbac/argocd-securitypolicies.yaml   # Argo CD pode gerenciar SecurityPolicy
oc apply -f seguranca/argocd/app-acs-policies.yaml            # políticas DEMO no Central
oc apply -f seguranca/argocd/app-pagamentos-demo.yaml         # auto-sync; a demo é feita por commits
./seguranca/demo-apps/etapa.sh 00                             # estado inicial da fase central

export ROX_ENDPOINT=central-rhacs-operator.apps.<hub>:443 ROX_API_TOKEN=<token>   # Analyst para os KPIs
./seguranca/pipeline/roxctl-check.sh                          # gate de build
./seguranca/kpis/coletar-kpis.sh                              # Jornada de Fundação
```

| Diretório | Papel |
|---|---|
| `acs/policies/` | `SecurityPolicy` (CR do ACS ≥ 4.6) aplicadas pelo Argo CD no namespace do Central (`rhacs-operator`) |
| `acs/rbac/` | Role/RoleBinding para o application controller do Argo CD |
| `acm/` | Policies do ACM: cobertura do ACS na frota e varredura PCI-DSS |
| `argocd/` | Applications apontando para esta branch |
| `demo-apps/` | `etapa.sh` + `etapas/` (00 inicial, 01–04 uma violação cada, 06 final) e `variacoes/` para tentativas manuais |
| `pipeline/` | gate `roxctl image check` local (o mesmo do workflow do GitHub Actions) |
| `kpis/` | coleta dos 8 KPIs via API do ACS Central e do ACM |
| `docs/` | roteiro, falas, objeções e ficha dos KPIs |
