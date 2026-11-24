# Guion de la demo · Pipelines + GitOps con dos clusters

**Duración:** ~50 min + preguntas · **Público:** desarrollo, operaciones y plataforma
**Mensaje central:** *el desarrollador solo hace commit. La plataforma prueba, construye, publica y
despliega en otro cluster, y todo cambio queda en Git — sin entrar al cluster de destino.*

| # | Bloque | Tiempo | Qué se ve |
|---|---|---|---|
| 0 | Apertura: del ticket al commit | 5 min | arquitectura |
| 1 | GitOps con ACM: el cluster 2 como destino | 7 min | ACM, Argo CD |
| 2 | La esteira de CI en el hub | 8 min | Pipelines, Quay |
| 3 | Del commit al despliegue (etapa 01) | 8 min | GitHub → Tekton → Quay → Argo CD → app |
| 4 | Cuando algo falla (etapas 02 y 03) | 7 min | test rojo, nada se despliega |
| 5 | Promoción a producción | 5 min | misma imagen, sync manual |
| 6 | Drift y rollback | 5 min | selfHeal, `git revert` |
| 7 | Métricas DORA y próximos pasos | 5 min | `coletar-kpis.sh` |

**Clusters:** `hub` (ACM + OpenShift GitOps + OpenShift Pipelines) y `gestionado` (Quay + aplicaciones).
En los comandos, `<cluster-gestionado>` es el nombre del ManagedCluster en el ACM.

---

## Preparación (D-1)

> Todo vive en la branch `devops` del repositorio `gitops-infra`. Nada de la branch `main` cambia.

1. **Clusters y operadores**
   - Hub: ACM (MultiClusterHub `Running`), OpenShift GitOps, OpenShift Pipelines ≥ 1.17.
   - Gestionado: importado en el ACM (`oc --context hub get managedcluster` → `JOINED/AVAILABLE=True`) y con
     **Red Hat Quay** operativo (QuayRegistry `Available`).
   - Contextos del `oc` llamados `hub` y `gerenciado` (o ajuste `devops/config.env`):
     ```bash
     oc login <API_HUB>        && oc config rename-context $(oc config current-context) hub
     oc login <API_GESTIONADO> && oc config rename-context $(oc config current-context) gerenciado
     ```
2. **Quay (en la consola del Quay del cluster gestionado)**
   - Organización `puc` (o la que ponga en `QUAY_ORG`) y repositorio **privado** `pagamentos-api`.
   - Robot `devops_ci` con permiso **Write** y robot `devops_pull` con **Read** en el repositorio.
   - Host de la ruta: `oc --context gerenciado -n <ns-quay> get route -l quay-component=quay -o jsonpath='{.items[0].spec.host}'`.
3. **Parámetros y preparación automática**
   ```bash
   git clone -b devops https://github.com/pecorawal/gitops-infra.git && cd gitops-infra
   vi devops/config.env          # QUAY_HOST, QUAY_ORG, CLUSTER_GERENCIADO
   export QUAY_PUSH_USER='puc+devops_ci'   QUAY_PUSH_TOKEN='<token>'
   export QUAY_PULL_USER='puc+devops_pull' QUAY_PULL_TOKEN='<token>'
   export GITHUB_TOKEN='<PAT con push en el repo>'
   ./devops/scripts/preparar.sh tudo
   ```
   El script: reemplaza `<QUAY_HOST>`/`<QUAY_ORG>` en los manifiestos (commit + push), etiqueta el cluster con
   `devops=gerenciado`, crea los Secrets en el hub, aplica `devops/acm/`, `devops/pipeline/` y la app raíz del
   Argo CD, y muestra la URL y el secreto del webhook.
4. **Webhook del GitHub:** *Settings › Webhooks › Add webhook* con lo que mostró `preparar.sh webhook`
   (`application/json`, *Just the push event*). En *Recent Deliveries* el ping debe responder `202`.
   > Si la ruta del hub no es alcanzable desde internet, use el **plan B** (PipelineRun manual) en cada etapa.
5. **Confirmar el ACM**
   ```bash
   oc --context hub -n openshift-gitops get secret -l argocd.argoproj.io/secret-type=cluster --show-labels
   #   debe aparecer el cluster gestionado con devops=gerenciado
   oc --context hub -n devops-policies get policy devops-acesso-quay        # Compliant
   oc --context gerenciado -n pagamentos-dev get secret quay-pull            # creado por la Policy
   ```
   - Tras aplicar la Policy, el `image.config` del gestionado cambia y los nodos se actualizan (~2 min, sin reinicio).
   - Si el Quay usa certificado de una CA pública, desactive el template `quay-ca-confiavel` de la Policy.
6. **Build inicial y producción inicial**
   ```bash
   oc --context hub create -f devops/pipeline/manual/pipelinerun.yaml
   tkn --context hub -n devops-ci pipelinerun logs -f --last           # ~3 min la primera vez
   git pull
   ./devops/demo/etapa.sh promover && ./devops/demo/etapa.sh sync-prod
   ./devops/demo/etapa.sh status       # dev y prod con la misma tag, réplicas 1/1 y 2/2
   ```
7. **Línea de base de las métricas:** `./devops/kpis/coletar-kpis.sh --csv > antes.csv`
8. **Ensayo completo (obligatorio, ~15 min):** `etapa.sh 01`, `02`, `03`, `promover` + Sync, `drift`,
   `rollback` + Sync. Termine con `etapa.sh 00` + `promover` + `sync-prod` para dejar el punto de partida
   (versión 1.0, azul, en los dos ambientes).
9. **Pestañas abiertas:** ACM (*Infrastructure › Clusters* y *Governance*); Argo CD (filtro
   `demo-devops`); consola del hub *Pipelines › devops-ci*; Quay (repositorio `pagamentos-api` › *Tags*);
   GitHub (branch `devops`, *commits*); la página de DEV y la de PROD; terminal en la raíz del repo.

---

## 0 · Apertura (5 min)

Muestre la diapositiva de arquitectura.

> "Hoy, para poner una versión nueva en un ambiente, ¿cuántas personas tienen que intervenir y cuántos
> tickets se abren? Vamos a mostrar un flujo en que el desarrollador **solo hace commit**: la
> plataforma prueba, construye, guarda la imagen y la despliega en **otro cluster**, y cada paso queda
> registrado en Git."

- Dos clusters con papeles distintos: el **hub** construye y gobierna; el **gestionado** ejecuta y guarda las imágenes (Quay).
- Dos esteiras encadenadas por el Git: **CI** (Pipelines) termina escribiendo una tag; **CD** (GitOps) empieza leyéndola.

---

## 1 · GitOps con ACM: el cluster 2 como destino (7 min)

**Mostrar:** ACM › Clusters → label `devops=gerenciado`; Argo CD › Settings › Clusters; `devops/acm/`.

1. En el ACM, abra el cluster gestionado y muestre el label `devops=gerenciado`.
   > "Este label es la única decisión: 'este cluster recibe la aplicación'. Nadie copió kubeconfig ni token."
2. Abra `devops/acm/01-gitopscluster.yaml`: Placement por label + GitOpsCluster.
   En el Argo CD (*Settings › Clusters*) el gestionado aparece registrado automáticamente.
3. Abra `devops/gitops/argocd/appset-pagamentos-dev.yaml`: el generator selecciona clusters por label.
   > "Mañana marcan un tercer cluster con el mismo label y recibe la aplicación sin cambiar una línea."
4. ACM › Governance › `devops-acesso-quay`: la Policy dejó en el gestionado los namespaces, el pull secret del
   Quay (cuyo valor vive solo en el hub) y la confianza en el certificado del Quay.
   > "La configuración del cluster de destino también es código, y el ACM la mantiene."

---

## 2 · La esteira de CI en el hub (8 min)

**Mostrar:** Pipelines › devops-ci › Pipelines › `pagamentos-api` (vista gráfica); `devops/pipeline/pipeline.yaml`.

1. Recorra las tareas: `fetch-source` → `unit-tests` y `short-sha` → `build-and-push` → `update-gitops`.
   - `git-clone` y `buildah` son tareas **del propio operador** (resueltas desde `openshift-pipelines`): no hay nada que mantener.
   - La tag de la imagen es el **SHA corto del commit**: de la imagen se llega al código, y viceversa.
2. Abra `devops/pipeline/tasks/update-gitops.yaml`.
   > "Fíjense: la pipeline **nunca** habla con el cluster de destino. Su último paso es un commit. Quien
   > despliega es el Argo CD, leyendo el Git. Por eso el CI no necesita credenciales de producción."
3. Abra el TriggerTemplate/EventListener (`triggers/20-trigger.yaml`): solo cambios en `devops/app/**` disparan
   la pipeline — así el commit de la propia pipeline no genera un loop.
4. En el Quay, muestre el repositorio `pagamentos-api` con la tag del build inicial.
   > "La imagen se construye en el hub y queda en el registry del cluster donde va a correr."

---

## 3 · Del commit al despliegue (8 min) — etapa 01

**Mostrar en paralelo:** terminal, Pipelines (PipelineRun nuevo), Quay (Tags), Argo CD (`pagamentos-dev-…`), página DEV.

```bash
./devops/demo/etapa.sh 01      # versión 1.1, la página pasa de azul a verde
```

1. El script muestra el diff (versión y color), hace commit y push. En el GitHub aparece
   `demo(etapa 01): …`.
2. El webhook dispara un PipelineRun `pagamentos-api-webhook-…`: siga las tareas en la vista gráfica.
3. Al terminar el `build-and-push`, la tag nueva aparece en el **Quay del cluster gestionado**.
4. El `update-gitops` hace el commit `ci(dev): pagamentos-api <tag>`: muéstrelo en el GitHub (es solo una línea en `values-dev.yaml`).
5. El Argo CD sincroniza solo; refresque la página DEV: **v1.1 en verde**.
   > "Del commit a la versión en el otro cluster en pocos minutos, y con trazabilidad completa:
   > commit de código → PipelineRun → tag en el Quay → commit de despliegue → sync del Argo CD."

**Plan B (sin webhook):** `oc --context hub create -f devops/pipeline/manual/pipelinerun.yaml` justo después del push.

---

## 4 · Cuando algo falla (7 min) — etapas 02 y 03

```bash
./devops/demo/etapa.sh 02      # la versión queda "v1.2": el test de formato falla
```

1. PipelineRun: `unit-tests` en **rojo**; `build-and-push` y `update-gitops` **no se ejecutaron**.
   Abra el log del test y muestre la aserción que falló.
2. Argo CD: `pagamentos-dev-…` sigue `Synced` en la tag anterior. La página DEV **no cambió**.
   > "El error existió, pero se detuvo en la esteira. Ningún ambiente recibió un build roto, y nadie tuvo que revisar a mano."
3. Corrección:
   ```bash
   ./devops/demo/etapa.sh 03   # versión 1.2 corregida, la página pasa a rojo
   ```
   La esteira vuelve a fluir hasta DEV. Este par falla → corrección alimenta la métrica de *tiempo de recuperación*.

---

## 5 · Promoción a producción (5 min)

```bash
./devops/demo/etapa.sh promover
```

1. El script copia la tag de `values-dev.yaml` a `values-prod.yaml` y hace commit `promo(prod): …`.
   > "No hay build nuevo: **la misma imagen** que se probó en DEV va a producción. Lo que cambia es una línea en Git."
2. Argo CD: `pagamentos-prod-…` queda **OutOfSync**. Abra *App Diff*: solo cambia la imagen.
3. Haga clic en **Sync** (o `./devops/demo/etapa.sh sync-prod`).
   > "En producción el despliegue es una aprobación explícita. En un equipo real esto es un *Pull
   > Request* con revisión obligatoria: el Git guarda quién aprobó y cuándo."
4. Página PROD: v1.2 con 2 réplicas (el `pod:` cambia al recargar).

---

## 6 · Drift y rollback (5 min)

```bash
./devops/demo/etapa.sh drift       # alguien escala DEV a 5 réplicas directamente en el cluster
```
- El Argo CD detecta la diferencia y el **selfHeal** vuelve a 1 réplica en segundos.
  > "El cambio manual no sobrevive: el estado deseado está en Git. Se acaba el 'en mi cluster funciona'."

```bash
./devops/demo/etapa.sh rollback    # git revert de la última promoción
```
- `pagamentos-prod-…` OutOfSync hacia la tag anterior → **Sync**. Página PROD vuelve a la versión anterior.
  > "Rollback no es un procedimiento de emergencia: es un commit, revisable y reversible."

---

## 7 · Métricas DORA y próximos pasos (5 min)

```bash
./devops/kpis/coletar-kpis.sh
```
- Compare con `antes.csv`: frecuencia de despliegue, lead time en minutos, la falla de la etapa 02 y su recuperación.
  Ver la ficha en [`kpis-devops.md`](kpis-devops.md).
- **Próximos pasos sugeridos** (cuando el equipo esté listo):
  1. Promoción por Pull Request con revisión obligatoria (branch protection) en lugar de commit directo.
  2. Más ambientes/clusters: solo labels en el ACM.
  3. Seguridad en la misma esteira (DevSecOps): análisis de imagen en el build y control de admisión en el
     despliegue con Red Hat Advanced Cluster Security — ya preparado en la branch `seguranca`.

---

## Objeciones frecuentes

| Pregunta | Respuesta corta |
|---|---|
| "¿Por qué el hub construye y no cada cluster?" | Un solo lugar para mantener la esteira y sus credenciales; los clusters de destino solo ejecutan. Se puede tener Pipelines en otros clusters si el volumen lo pide. |
| "¿Y si el hub cae?" | Las aplicaciones siguen corriendo en el gestionado y las imágenes están en su Quay. Solo se pausan los despliegues nuevos. |
| "¿El CI tiene acceso a producción?" | No. La pipeline escribe en Git y en el Quay; quien aplica en el cluster es el Argo CD. |
| "¿Puedo usar GitLab/Bitbucket?" | Sí: cambia el interceptor del EventListener y la URL del repo. El resto es igual. |
| "¿Helm es obligatorio?" | No; el Argo CD acepta Kustomize o YAML plano. Helm se usó por los `values` por ambiente. |

## Problemas conocidos (para el ensayo)

| Síntoma | Causa probable | Qué hacer |
|---|---|---|
| `build-and-push` falla con `x509` | el hub no confía en la ruta del Quay | `TLS_VERIFY=false` (por defecto en la Pipeline) o agregue la CA del Quay en el hub |
| Pod en `ImagePullBackOff` con `x509` | nodos del gestionado sin la CA del Quay | Policy `devops-acesso-quay` `Compliant`; espere el rollout del `image.config` |
| Pod en `ImagePullBackOff` con `unauthorized` | `quay-pull` sin permiso de lectura | revise el robot `devops_pull` en el repositorio |
| El push no dispara la pipeline | webhook inaccesible o filtro CEL | *Recent Deliveries* del GitHub; `oc -n devops-ci logs deploy/el-devops-webhook` |
| `update-gitops` falla en el push | token sin permiso o branch protegida | PAT con `contents:write`; la pipeline reintenta con rebase 3 veces |
| La app no aparece en el Argo CD | cluster sin label o GitOpsCluster sin binding | sección 5 de la preparación |
