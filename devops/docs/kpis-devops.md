# Métricas de la esteira · DORA

Cuatro números que cualquier equipo de desarrollo y operaciones entiende, sacados en vivo con
`./devops/kpis/coletar-kpis.sh` (sin planilla). Responden a dos preguntas: **¿qué tan rápido
entregamos?** y **¿qué tan estable es lo que entregamos?**

| Pregunta | Métrica | Fórmula en la demo | Fuente | Dirección |
|---|---|---|---|---|
| Velocidad | **Frecuencia de despliegue** | entradas en el historial del Argo CD (DEV y PROD) | `Application.status.history` | ↑ |
| Velocidad | **Lead time de cambio** | `deployedAt` en DEV − fecha del commit de código | Argo CD + `git log` (línea `origem:` del commit de la pipeline) | ↓ |
| Estabilidad | **Tasa de fallo de la esteira** | PipelineRuns fallidos ÷ total | `PipelineRun.status` | ↓ |
| Estabilidad | **Tiempo de recuperación** | primera falla → siguiente PipelineRun exitoso | `PipelineRun` creation/completion | ↓ |

## Cómo leerlas en la demo
- **Antes** (`--csv > antes.csv` en el D-1): 1–2 despliegues, sin fallas.
- **Después** de las etapas 01–03: la frecuencia sube, el lead time queda en **minutos** y la etapa 02
  aparece como una falla con su tiempo de recuperación (la corrección de la etapa 03).
- Mensaje: *la falla existió, pero se detuvo en la esteira — producción nunca la vio.*

## Limitaciones honestas
- El Argo CD guarda por defecto los últimos 10 despliegues (`revisionHistoryLimit`); para series
  históricas, exporte a Prometheus/Grafana (métricas `argocd_app_*` y `tekton_pipelines_*`).
- "Tasa de fallo de la esteira" es una aproximación de *change failure rate*: en DORA estricto cuenta
  fallas **en producción**. Para medirla así, registre incidentes/rollbacks de PROD (ej.: commits `Revert "promo(prod)…`).
- Las PipelineRuns se borran por la política de *pruning* del operador; conserve el CSV de cada ensayo.
