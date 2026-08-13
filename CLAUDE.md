# Chasqui Pet

Instrucciones permanentes para Claude Code en este repositorio. Todo lo que sigue
está verificado contra el código, la configuración y las migraciones. Lo que no
pudo verificarse aparece como `[PENDIENTE DE VERIFICAR]`.

Idioma del proyecto: **español neutro** (sin voseo) en código, comentarios,
identificadores SQL, mensajes al usuario y documentación.

---

## Project Overview

- **Nombre:** Chasqui Pet (`docker-compose.yml` → `name: chasquipet`).
- **Propósito:** sistema de gestión para una clínica veterinaria en Bogotá,
  Colombia, operado principalmente desde Telegram (`README.md`, `chasquipet.md`).
- **Tipo:** sistema autoalojado con Docker Compose: bot de Telegram + portal web
  administrativo + pantalla pública de sala de espera + worker de cola.
- **Independiente:** no comparte código ni base de datos con el sistema "Chasqui"
  original; por eso los puertos van corridos (DB 5433, n8n 5679, web 3100,
  proxy 8081).
- **Estado:** MVP declarado **terminado (paso 8 de 8)** en `README.md`. Encima de
  ese MVP hay trabajo en curso del asistente «Habla con Chasqui» y un plan de
  consolidación vigente: `docs/plan-consolidacion-chasqui-pet.md` (bloque A,
  cimientos; bloque B, producto). Ese documento es la **única** hoja de ruta
  vigente; los planes anteriores están en `docs/archivo/`.
- **Componentes principales** (servicios de `docker-compose.yml`):
  `db` (PostgreSQL 16), `n8n`, `worker` (Node.js), `web` (Next.js), `backup`,
  `proxy` (Caddy) y, bajo el perfil `local`, `cloudflared` y `registrador`.

### Decisión rectora: la lógica vive en PostgreSQL

Las reglas de negocio, los permisos, el estado conversacional del bot, la cola de
tareas, el rate limiting y la auditoría están en funciones plpgsql dentro de
`db/migrations/`. n8n es un traductor de formato (sus nodos solo llaman funciones
SQL y la Bot API; no toman decisiones de negocio), el worker solo despacha tareas
y la web solo traduce formularios a llamadas SQL.
**No mover lógica de negocio a Node/n8n.**

---

## Tech Stack

| Área | Qué es | Evidencia |
|---|---|---|
| Base de datos | PostgreSQL 16 (`postgres:16-alpine`), extensiones `pgcrypto`, `pg_trgm`, `unaccent` | `docker-compose.yml`, `db/migrations/010_base.sql` |
| ORM | **Ninguno**: SQL directo con `pg` | `web/src/lib/db.ts`, `worker/src/index.js` |
| Runtime | Node.js ≥ 22 (`node:22-alpine` en ambas imágenes) | `web/package.json`, `worker/package.json`, Dockerfiles |
| Web | Next.js 16, App Router, React 19, TypeScript en modo `strict` + `noUncheckedIndexedAccess`, `output: 'standalone'` | `web/package.json`, `web/tsconfig.json`, `web/next.config.ts` |
| Worker | Node.js ESM puro (`"type": "module"`), sin framework | `worker/package.json`, `worker/src/` |
| Gestor de paquetes | npm (hay `package-lock.json`; las imágenes usan `npm ci`) | Dockerfiles |
| Orquestación de webhooks/jobs | n8n, **versión fija a propósito** (no `latest`): subirla obliga a reimportar los workflows | `docker-compose.yml` |
| Cliente Telegram | `fetch` nativo, sin librerías | `worker/src/telegram.js` |
| IA | SDK `openai` (API compatible OpenAI). El *endpoint* por defecto es `https://api.deepseek.com`, sobreescribible con `DEEPSEEK_BASE_URL`; **el modelo no está en el código**: sale de la config de la base (`config_txt('ia_modelo', …)`, sembrado en `078` con `nemotron-3-ultra-free`) | `worker/package.json`, `worker/src/tareas/chasqui_responder.js`, `db/migrations/078_chasqui_ia.sql` |
| Proxy | Caddy 2 (`caddy:2-alpine`) | `proxy/Caddyfile` |
| Túnel público | `cloudflare/cloudflared` (perfil `local`) | `docker-compose.yml` |
| Autenticación | Solo Telegram: challenge de 6 dígitos o enlace de un solo uso; cookie de sesión validada por SQL | `db/migrations/058_auth_web.sql`, `077_portal_enlace.sql`, `web/src/lib/sesion.ts` |
| Testing | pgTAP sobre una base efímera levantada desde las migraciones (`db/pruebas/`, `scripts/pruebas.sh`). Nada automatizado en Node ni en la web | ver *Testing* |
| Lint/formato | **No hay configuración de ESLint ni Prettier** | ver *Testing* |
| Zona horaria | `America/Bogota` en todos los contenedores; `timestamptz` en UTC, presentación en hora local | Dockerfiles, `010_base.sql` (`hoy_bogota()`, `ahora_bogota()`) |

---

## Architecture

Flujo real observado:

```
Telegram ──webhook──► n8n (01-telegram-webhook.json)
                        1. registrar_update_telegram(jsonb)   (dedupe)
                        2. bot_manejar_update(jsonb) ─► {acciones:[…]}
                        3. nodo Code: acciones → llamadas Bot API
                        4. HTTP a api.telegram.org
                        5. marcar_update_procesado(update_id)

PostgreSQL ── tarea_async ──► worker (polling)
                        reclamar_tareas(lote)  FOR UPDATE SKIP LOCKED
                        manejador por tipo (worker/src/tareas/index.js)
                        completar_tarea() / fallar_tarea()  (backoff en la BD)
                        rescatar_tareas_colgadas(min) cada 5 min
                        (umbral WORKER_RESCATE_MIN, 15 por defecto)

n8n jobs (schedule) ──► funciones SQL:
                        02 turnos (cada minuto): recordatorio de llamados
                           vencidos + rescatar_tareas_colgadas(15)  ← red de
                           seguridad redundante con la del worker, a propósito
                        03 inventario (7:30): bloquear_lotes_vencidos + alerta
                        04 mantenimiento (3:15): purga diaria + ANALYZE

Navegador ──► Next.js (server components + server actions) ──► funciones SQL
Internet ──► cloudflared ──► Caddy: /webhook/* → n8n, resto → web
```

Puntos que hay que respetar:

- **El webhook responde rápido**: todo trabajo diferido se encola en
  `tarea_async`, nunca se hace en línea.
- **El worker es deliberadamente tonto**: no reimplementa backoff, prioridades ni
  reglas de negocio. Para agregar un tipo de tarea: crear
  `worker/src/tareas/<tipo>.js` exportando `tipo` y `manejar(tarea, ctx)` e
  importarlo en `worker/src/tareas/index.js`. Nada más
  (`ctx = { db, log, marcarAviso }`).
- **La web no decide permisos**: `exigirPermiso()` es la segunda cerradura; la
  función SQL vuelve a exigir el permiso con el `usuario_id` de la sesión.
- **El asistente IA no ejecuta escrituras por su cuenta**: el modelo llama
  herramientas registradas en `ia_herramienta`; toda escritura arma una propuesta
  en `ia_accion_pendiente` y espera confirmación humana por botón
  (`ia:ok`/`ia:no` → `ia_confirmar` → `ia_escribir` → ejecutor SQL). Regla C6.9
  del plan; no se salta.
- **Append-only**: `evento_auditoria`, `movimiento_inventario`, `pago` y
  `descuento` no admiten UPDATE/DELETE desde la aplicación; los errores se
  corrigen con movimientos/reversos, nunca editando la fila original
  (`db/migrations/090_grants.sql`).

---

## Repository Structure

```
db/migrations/   Esquema, funciones plpgsql, permisos y seeds. Se aplican en el
                 primer arranque vía /docker-entrypoint-initdb.d (orden alfabético,
                 prefijos de TRES dígitos, .sh y .sql mezclados).
db/demo/         Datos de demostración (los carga scripts/cargar-demo.sh).
db/seeds/        Vacío.
db/pruebas/      Batería de invariantes con pgTAP + su Dockerfile. No son
                 migraciones: solo se cargan en la base efímera de scripts/pruebas.sh.
n8n/workflows/   Webhook de Telegram y 3 jobs programados, versionados en JSON.
worker/src/      Worker de la cola: index.js (ciclo), telegram.js, log.js, tareas/.
web/src/app/     Next.js App Router: (portal) protegido, /entrar, /pantalla,
                 /api, /health, /salir, /sin-permiso.
web/src/lib/     db.ts, sesion.ts, formato.ts, clinico.ts, reportes.ts, pantalla.ts,
                 notificaciones.ts.
scripts/         Puesta en marcha, respaldos, restauración, importación de n8n.
proxy/Caddyfile  Ruteo público.
docs/            Modelo de datos, reportes técnicos, guía de operación y la hoja
                 de ruta vigente (plan-consolidacion-chasqui-pet.md).
docs/archivo/    Planes superados, con cabecera que lo advierte. Referencia
                 histórica: no consultarlos como fuente vigente. Incluye los
                 documentos de la herramienta externa StrictContext, ajenos a
                 la aplicación.
backups/         Dumps diarios (ignorados por git).
```

`.strictcontext/`, `.strictcontext.db` y `opencode.json` son de herramientas
externas y no forman parte de la aplicación. **Ojo: no están en `.gitignore`;
solo están sin rastrear.** `opencode.json` **contiene una credencial**: no lo
copie, no lo imprima y no lo agregue al índice de git (ver *Git Rules*).

---

## Database

- **Motor:** PostgreSQL 16. Base de negocio `chasquipet`; n8n usa una base
  **separada** (`n8n`) con usuario propio, creada por `db/migrations/000_n8n_db.sh`.
- **Sin ORM**: no hay Prisma/Drizzle/Knex. SQL directo con `pg`.
- **Con migrador propio desde la Fase A1**: la tabla `schema_version`
  (`120_schema_version.sql`) registra qué se aplicó, y `scripts/migrar.sh` es el
  **único camino previsto** para aplicar una migración a una base ya inicializada.
  Los dos caminos convergen: en instalación limpia initdb corre `db/migrations/` y
  `910_registrar_versiones.sh` siembra el registro; en base viva, `migrar.sh`
  aplica y registra en la misma transacción.

  ```bash
  bash scripts/migrar.sh --estado   # qué está aplicado y qué falta
  bash scripts/migrar.sh            # aplica lo pendiente, en orden
  ```

  El migrador **guarda el hash** de cada archivo: si una migración ya aplicada
  cambia de contenido, se detiene con código 2 y no aplica nada. Es la regla del
  proyecto vuelta reja —una migración aplicada no se edita— y no se rodea.
- **Aun así, escriba las migraciones idempotentes** (`CREATE OR REPLACE`,
  `IF NOT EXISTS`, `INSERT … ON CONFLICT`, `GRANT` repetibles): el registro dice
  qué corrió en *esa* base, no en todas.
- **Convenciones observadas:**
  - Nombres de tablas/columnas/funciones en español, `snake_case`, tablas en
    singular (`turno`, `cuenta`, `movimiento_inventario`).
  - Prefijo numérico de tres dígitos + nombre descriptivo; los archivos `0x6_bot_*`
    contienen la capa de bot del módulo `0x0_*`.
  - Cabecera de comentario en cada archivo explicando el porqué y citando la
    sección del `chasquipet.md` (§).
  - **Toda migración nueva declara su ámbito en la cabecera** (Fase A7a), en una
    de estas dos formas exactas:
    `-- Ámbito: NÚCLEO` (identidad, permisos, auditoría, cola, config, inventario,
    cobro, compras, admin) o `-- Ámbito: VERTICAL` (turnos veterinarios, pacientes,
    consulta clínica, agenda de citas). `scripts/migrar.sh` **lo exige**: una
    pendiente sin esa línea aborta la tanda entera antes de aplicar nada. Las 26
    migraciones anteriores a la convención no se retocan (una migración aplicada no
    se edita) y la reja no las mira.
  - Claves primarias `uuid` (`gen_random_uuid()`), `timestamptz` en UTC, fechas de
    negocio con `hoy_bogota()`.
  - Trigger `touch_updated_at()` para `updated_at`.
  - Búsqueda tolerante con `normalizar()` + `pg_trgm` + `unaccent`.
  - Estados como texto con `CHECK` (p. ej. `consulta.estado`
    `'borrador'→'firmada'→'anulada'`), no enums nativos.
- **Roles:** `chasquipet_app` (la aplicación; no es dueño ni superusuario),
  `chasquipet_lectura` (solo lectura). El dueño (`POSTGRES_USER`) solo se usa para
  administración/migraciones (`ADMIN_DATABASE_URL`).
- **Inicialización:** `900_superadmin.sh` fija las contraseñas de los roles de
  aplicación y crea el superadmin con `SUPERADMIN_TELEGRAM_USER_ID`.
- **Reglas para Claude:**
  - **Nunca editar un archivo de `db/migrations/` que ya exista**: cree uno nuevo
    con el siguiente prefijo libre. No hay forma de saber desde el repositorio si
    una migración ya se aplicó (no hay tabla de versiones), así que la regla es
    incondicional. Si un arreglo parece exigir tocar `079`–`083`, pregunte antes.
  - Nunca `DROP`/`TRUNCATE` de tablas de negocio ni de auditoría.
  - Nunca conceder UPDATE/DELETE sobre las tablas append-only.
  - Al reemplazar funciones de enganche (`ia_llamar`, `ia_escribir`,
    `ia_texto_resultado`, `bot_ia_bienvenida`) el cambio debe ser **aditivo** y hay
    que verificar que no se pierda nada de la versión previa.
  - El orden importa: los enganches de `083` asumen `079`, `081` y `082` aplicados.

---

## APIs and Integrations

**Internas (Next.js, `web/src/app/api/` y rutas):**

| Ruta | Para qué |
|---|---|
| `POST /api/entrar` | Crea el challenge de ingreso (código de 6 dígitos + enlace `t.me`). |
| `/api/entrar/[id]` | Estado del challenge. |
| `/entrar/enlace/[id]` | Ingreso por enlace de un solo uso (5 minutos, §077). |
| `/api/pantalla/[sede]` y `/stream` | Pantalla pública de turnos (sondeo + stream con `LISTEN`). |
| `/api/reportes/[clave]` | Exportación CSV de los reportes. |
| `/health` | Health check (`SELECT 1`). |
| `/salir` | Cierre de sesión. |

**Externas:**

- **Telegram Bot API**: entrada por webhook a n8n (`/webhook/chasquipet-telegram`);
  salida desde n8n y desde el worker (`worker/src/telegram.js`). Manejo de errores
  ya definido: `429` → respeta `retry_after` y reintenta una vez; `403` → no
  reintenta (`{ok:false, motivo:'bloqueado'}`); resto → lanza y la cola aplica
  backoff.
- **DeepSeek** (`DEEPSEEK_API_KEY`, `DEEPSEEK_BASE_URL`): solo el worker la usa.
  Sin la clave, el asistente avisa que no está configurado y el resto del bot sigue
  funcionando.
- **Cloudflare Tunnel**: publica el proxy; el `registrador` re-registra el webhook
  y escribe `config.portal_url`.

**Reintentos y errores:** el backoff exponencial, el máximo de intentos y la
bandeja de fallidas viven en `tarea_async` / `fallar_tarea` en la base. No los
reimplemente en Node.

---

## Testing

- **Batería de invariantes con pgTAP** (Fase A4), en `db/pruebas/`, que se corre con
  `bash scripts/pruebas.sh` (o `bash scripts/pruebas.sh 030` para filtrar, o
  `--conservar` para dejar la base en pie). Levanta un contenedor efímero **desde
  `db/migrations/`**, así que cada corrida verifica también que una instalación
  limpia sigue funcionando. Cada archivo corre en una transacción que termina en
  `ROLLBACK`; no toca la base de trabajo ni ningún contenedor de compose.
  - Cubre lo que rompe el producto si se rompe: `exigir_permiso` en toda función de
    escritura, append-only, FEFO, consulta firmada inmutable, cuadre de caja,
    consentimiento (Ley 1581), confirmación humana de la IA (C6.9) y el alta de
    paciente.
  - Al agregar un archivo: declare `SELECT plan(n)` con el número exacto de pruebas
    —el corredor falla si no cuadra— y termine en `SELECT * FROM finish(); ROLLBACK;`.
    Los constructores de datos están en `db/pruebas/000_arnes.sql` y llaman a las
    funciones de negocio reales, no insertan filas a mano.
- **No hay** Jest, Vitest ni Playwright: nada automatizado del lado de Node ni de la web.
- Otros comandos de verificación:
  - `cd web && npm run typecheck` (`tsc --noEmit`).
  - `cd web && npm run build`.
  - `cd worker && npm run check` (`node --check src/index.js`; **solo valida la
    sintaxis de ese archivo**, no de `src/tareas/`).
- **Contradicción conocida:** `web/package.json` declara `"lint": "next lint"`,
  pero no hay dependencia de ESLint ni archivo de configuración. Trate el lint como
  no disponible salvo que se configure explícitamente (decisión del usuario).
- **Cómo se cierra una fase** (ver `docs/reporte-fase*.md`): con una tabla
  `#/Prueba/Esperado/Obtenido/PASS-FAIL`. Lo que se pueda expresar como invariante
  va a `db/pruebas/`; el resto sigue siendo verificación con `psql` sobre datos
  demo. Ese es el estándar del proyecto. Cobertura mínima exigida por
  `docs/plan-consolidacion-chasqui-pet.md` §Anexo A2: caso exitoso, datos
  inválidos, permisos insuficientes, ausencia de datos, idempotencia, rollback,
  auditoría, confirmación humana, respuesta al usuario e integración.
- Las pruebas deben usar datos representativos y **no destruir información real**;
  limpie las trazas que genere.

---

## Development Commands

Requiere Docker y Docker Compose. Comandos verificados en `README.md` y `scripts/`:

```bash
cp .env.example .env            # y completar los valores
docker compose up -d            # levanta db, n8n, worker, web, backup, proxy
docker compose --profile local up -d   # además: cloudflared + registrador
bash scripts/importar-n8n.sh    # importa y publica los workflows
bash scripts/configurar-bot.sh  # comandos y descripción del bot; imprime el
                                # ENLACE para hacer el QR y la URL de la pantalla
                                # (no genera la imagen del QR)
bash scripts/cargar-demo.sh     # opcional: datos de demostración
bash scripts/crear-superadmin.sh
bash scripts/migrar.sh --estado # qué migraciones están aplicadas y cuáles faltan
bash scripts/migrar.sh          # aplica las pendientes, en orden y en transacción
bash scripts/pruebas.sh         # batería de invariantes (contenedor efímero aparte)
bash scripts/restaurar.sh <archivo>     # DESTRUCTIVO: ver Comandos peligrosos
docker compose logs -f worker
docker compose ps
```

Desarrollo de la web fuera de Docker:

```bash
cd web && npm install
npm run dev          # necesita DATABASE_URL; el puerto publicado por compose es
                     # 127.0.0.1:5433 (inferido de docker-compose.yml; no está
                     # documentado en README.md)
npm run typecheck
npm run build
```

Reconstruir un servicio tras cambiar código:

```bash
docker compose build worker && docker compose up -d worker
docker compose build web    && docker compose up -d web
```

Puertos: web/pantalla `3100` (LAN), proxy `8081`, n8n `5679`, PostgreSQL `5433`
(los tres últimos solo `127.0.0.1`).

---

## Security

- **Secretos**: solo en `.env` (ignorado por git). Se versiona únicamente
  `.env.example`, con valores de relleno. Nunca copie valores reales a la
  documentación, a comentarios, a logs ni a un reporte.
- Existen en el árbol de trabajo `.env`, `.env.bak.1785518025` y `opencode.json`
  con credenciales reales: **no imprimirlos, no versionarlos, no citarlos**. Los
  dos primeros los cubre `.gitignore` (`.env`, `.env.*`); **`opencode.json` no**.
- **Autenticación**: exclusivamente por Telegram. No hay contraseñas de usuario.
  La cookie `chasquipet_sesion` guarda el token en claro; en la base solo vive su
  `sha256` (`058_auth_web.sql`). Sesión de 30 días. No introduzca login por
  contraseña ni sesiones firmadas en Node.
- **Autorización**: los permisos son datos en Postgres (`rol_permiso`) y se exigen
  con `exigir_permiso` dentro de la función SQL, **antes de escribir**. La
  comprobación en la web/bot es adicional, nunca sustitutiva.
- **Validación**: la hacen las funciones SQL. En el bot no se acepta SQL libre del
  modelo: solo herramientas tipadas de `ia_herramienta`.
- **Webhook**: n8n dedupe por `registrar_update_telegram`; el token del bot se
  inyecta por `$env.TELEGRAM_BOT_TOKEN` para que no quede escrito en el JSON
  versionado. El editor de n8n no se enruta al exterior.
- **Datos personales (Ley 1581 de 2012)**: no se envía nada al dueño sin
  `consentimiento_datos` y chat vinculado; se valida en borrador, en ejecución y en
  el worker. No debilite ninguna de las tres capas.
- **Logs**: una línea por evento a stdout, en español, sin datos sensibles ni
  credenciales (`worker/src/log.js`).
- **Base de datos**: la aplicación se conecta como `chasquipet_app`, nunca como
  dueño. `ADMIN_DATABASE_URL` solo para migraciones y mantenimiento.

---

## Protected Areas

**Nunca modificar sin autorización explícita:**

- `.env`, `.env.bak.*`, cualquier archivo con credenciales, `opencode.json`.
- `backups/` y los `.dump`.
- Cualquier archivo existente de `db/migrations/`: se agrega uno nuevo, no se
  edita uno viejo (ver *Database → Reglas para Claude*).
- `db/migrations/090_grants.sql` (modelo de permisos y append-only) y
  `900_superadmin.sh`.
- `docker-compose.yml`, Dockerfiles, `proxy/Caddyfile` (topología e infraestructura).
- `scripts/restaurar.sh`, `scripts/backup.sh`.
- Documentos de plan: `chasquipet.md`, `docs/plan-consolidacion-chasqui-pet.md` y
  todo `docs/archivo/` (archivado: no se edita, no se «actualiza»).

**Modificar solo cuando la fase lo requiera:**

- Migraciones nuevas (`db/migrations/NNN_*.sql`, prefijo siguiente disponible).
- `worker/src/tareas/` y su `index.js`.
- `web/src/app/**` y `web/src/lib/**`.
- `n8n/workflows/*.json` (requiere reimportar con `scripts/importar-n8n.sh`).
- `.env.example` cuando aparece una variable nueva (solo el nombre y un valor de
  relleno).

**Normalmente seguros:**

- `docs/reporte-*.md` (reportes de fase nuevos), `README.md` cuando el alcance
  cambió de verdad.

---

## Git Rules

- Repositorio local, rama única `master`, **sin remotos configurados**. `main` no
  existe todavía; no hay evidencia de estrategia de ramas ni de PRs.
- Convención de commits observada: una línea en español, en modo enunciado, con el
  paso o la fase entre paréntesis. Ej.: *«Cobro: cuenta, pagos, descuentos, recibo
  y cierre de caja (paso 5)»*. Sin Conventional Commits, sin prefijos `feat:`.
- No se versionan: `.env*` (salvo `.env.example`), `node_modules/`, `.next/`,
  `*.tsbuildinfo`, `next-env.d.ts`, `backups/`, `*.dump`, `uploads/`, `*.log`,
  `coverage/`.
- Claude **puede** inspeccionar git (`status`, `log`, `diff`, `show`).
- Claude **no debe**, sin autorización explícita: `git push`, `git reset --hard`,
  borrar ramas, reescribir historial, `git clean -fd`, ni commitear/hacer stash de
  cambios que no pidió el usuario.
- **Nunca `git add -A` / `git add .`**: `opencode.json` (con credencial),
  `.strictcontext/` y `.strictcontext.db` están sin rastrear pero **no
  ignorados**, y entrarían al commit. Agregue siempre rutas explícitas.

---

## Coding Conventions

**Transversal:** todo en español (identificadores, comentarios, mensajes),
`snake_case` en SQL y en archivos del worker, `camelCase` en TS/JS. Los comentarios
explican **por qué**, con densidad alta y citando `§` del `chasquipet.md` o el
archivo/línea de la función reutilizada. Mantenga ese estilo: es la norma real del
repositorio, no un extra.

**SQL (`db/migrations/`):**
- Cabecera de bloque con `-- ===` y explicación del diseño.
- `SET client_min_messages = warning;` al inicio (lo tienen todas menos
  `035_aviso_turno.sql`; siga la mayoría).
- Funciones `plpgsql`/`sql` con `STABLE`/`IMMUTABLE` donde aplica, `SECURITY
  DEFINER` solo cuando es imprescindible y justificado en comentario.
- Retornos como `jsonb` con `{ok, mensaje, …}` para lo que consume el bot o la web.
- Idempotencia: `CREATE OR REPLACE`, `IF NOT EXISTS`, `ON CONFLICT DO NOTHING`.
- Auditoría con `auditar(...)`; encolado con `encolar_tarea(tipo, payload,
  prioridad, clave_unicidad, retraso, max_intentos)`.

**Worker (JS, ESM):**
- Un archivo por tipo de tarea, exportando `tipo` y `manejar(tarea, ctx)`.
- Devolver un objeto JSON (se guarda en `tarea_async.resultado`); lanzar para
  fallar (la base decide el reintento).
- Sin estado en memoria, sin dependencias nuevas salvo necesidad real.
- Logs con `log.info/aviso/error`, errores con `textoError(err)`.

**Web (TypeScript):**
- Server components por defecto; `'use server'` en `acciones.ts` para mutaciones.
- Acceso a datos solo por `consultar` / `consultarUna` de `@/lib/db`, siempre con
  parámetros posicionales (`$1`), **nunca** interpolando SQL.
- Rutas de API con `runtime = 'nodejs'` y `dynamic = 'force-dynamic'` cuando
  corresponde; respuestas con `Cache-Control: no-store` donde hay datos vivos.
- Cada acción empieza por `exigirSesion` / `exigirPermiso`; luego llama a la
  función SQL que vuelve a validar.
- Estilos con CSS Modules (`*.module.css`), sin librerías de UI.
- Imports absolutos con el alias `@/`.

---

## Documentation

Antes de trabajar, consulte según el tema:

| Tema | Documento |
|---|---|
| Especificación del producto (§ que citan las migraciones) | `chasquipet.md` |
| Modelo de datos y decisiones de diseño | `docs/modelo-datos.md` |
| Panorama técnico completo (arquitectura, integraciones, brechas) | `docs/reporte-tecnico.md` — ojo: sus «Fase 1/Fase 2» son las del plan de negocio (DIAN, reservas), **no** las del asistente |
| **Hoja de ruta vigente**: falencias a cerrar, funciones faltantes, reglas C6 y batería de pruebas | `docs/plan-consolidacion-chasqui-pet.md` |
| Estado de cada fase del asistente | `docs/plan-consolidacion-chasqui-pet.md` §Anexo A3 y `docs/reporte-fase1|3|4|5-*.md` |
| Planes superados (asistente, negocio DIAN/reservas, StrictContext) | `docs/archivo/` — referencia histórica, **no** son fuente vigente |
| Operación diaria del personal | `docs/guia-operacion.md` |
| Estado de los datos de la base (foto del 1-ago-2026; envejece rápido, verifique contra la base antes de confiar en las cifras, y no cite el ID de Telegram del superadmin) | `docs/datos-actuales.md` |
| Puesta en marcha, puertos, comandos | `README.md` |

No copie estos documentos: referéncielos.

---

## Development Workflow

1. Leer este `CLAUDE.md`.
2. Leer el documento de la fase correspondiente y su especificación funcional.
3. Revisar el código relacionado **antes** de escribir nada: la funcionalidad
   probablemente ya existe parcialmente (regla §2 del plan del asistente).
4. Identificar dependencias (migraciones previas, funciones que se van a reusar,
   permisos, tipos de tarea).
5. Identificar incertidumbres; si alguna puede cambiar significativamente la
   implementación, **reportarla antes de continuar** en vez de adivinar.
6. Verificar si hay decisiones arquitectónicas relacionadas (append-only,
   confirmación humana, permisos en SQL, `tarea_async`).

Durante la implementación:

- Implementar **únicamente** lo que pide la fase.
- Reutilizar funciones y componentes existentes; no duplicar.
- Respetar la arquitectura: lógica en PostgreSQL, worker tonto, n8n sin decisiones.
- No refactorizar lo no relacionado, no cambiar tecnologías, no borrar código
  porque "parece innecesario", no modificar contratos existentes salvo que la fase
  lo indique.
- No avanzar automáticamente a la fase siguiente.

---

## Definition of Done

Una fase no está terminada hasta verificar:

- [ ] Alcance implementado, sin cambios fuera de él.
- [ ] Arquitectura existente respetada.
- [ ] Autorización con `exigir_permiso` en la función SQL, antes de escribir.
- [ ] Confirmación humana para toda escritura del asistente (C6.9).
- [ ] Auditoría de las operaciones que la requieren.
- [ ] Idempotencia y transacción atómica donde corresponde (todo o nada).
- [ ] Operaciones pesadas o externas vía `tarea_async`.
- [ ] Migraciones nuevas idempotentes y con el prefijo siguiente.
- [ ] `npm run typecheck` / `npm run build` en `web` si se tocó la web.
- [ ] Pruebas ejecutadas con evidencia: caso exitoso, datos inválidos, permisos
      insuficientes, ausencia de datos, idempotencia, rollback, auditoría,
      regresión de los flujos previos.
- [ ] Integraciones afectadas verificadas (bot, worker, portal, n8n).

**Reporte final obligatorio** (formato de `docs/reporte-fase*.md`):
1. cambios realizados; 2. archivos modificados; 3. base de datos (tablas,
funciones, permisos, migraciones); 4. integraciones; 5. pruebas ejecutadas y su
resultado (tabla PASS/FAIL); 6. decisiones tomadas; 7. incertidumbres restantes;
8. riesgos y problemas encontrados; 9. desviaciones respecto al plan; 10. trabajo
pendiente.

No ocultar problemas para poder marcar una fase como completada.

---

## Comandos peligrosos (pedir confirmación antes)

Esta es la lista autoritativa de acciones que exigen confirmación explícita del
usuario antes de ejecutarse (las secciones anteriores la referencian, no la
repiten):

- `docker compose down -v` o cualquier borrado del volumen `chasquipet_pgdata`
  (destruye la base y fuerza la reinicialización desde `db/migrations/`).
- `bash scripts/restaurar.sh <archivo>` (reemplaza la base actual por un dump).
- `docker compose down`, `restart` o `build` de servicios en un entorno que pueda
  estar en uso por la clínica.
- Cualquier `DROP`, `TRUNCATE`, `DELETE` masivo o `UPDATE` sin `WHERE` sobre la
  base viva.
- `psql` con `ADMIN_DATABASE_URL` o como usuario dueño.
- Aplicar una migración a mano sobre una base con datos reales.
- `SELECT mantenimiento_diario()` u otras purgas fuera de su horario.
- Registrar/cambiar el webhook de Telegram (`setWebhook`) o tocar la configuración
  del bot en producción.
- `git push`, `reset --hard`, borrado de ramas, reescritura de historial,
  `git add -A`.
- Borrar archivos de `backups/` o de `db/migrations/`.

Claude nunca debe exponer secretos, imprimir credenciales, modificar credenciales
existentes ni acceder a producción sin autorización explícita.

---

## Important References

- Punto de entrada del bot: `bot_manejar_update(jsonb)` (SQL) desde
  `n8n/workflows/01-telegram-webhook.json`.
- Cola: `encolar_tarea`, `reclamar_tareas`, `completar_tarea`, `fallar_tarea`,
  `rescatar_tareas_colgadas`.
- Sesión web: `crear_challenge_web`, `sesion_por_token` (`058_auth_web.sql`,
  `077_portal_enlace.sql`).
- Asistente: `ia_herramienta`, `ia_accion_pendiente`, `ia_llamar`, `ia_confirmar`,
  `ia_escribir`, `ia_texto_resultado` (`078`–`083`), worker
  `chasqui_responder.js`.

### Contradicciones y puntos abiertos detectados

- `web/package.json` declara `"lint": "next lint"` sin ESLint instalado ni
  configurado → el comando no es utilizable tal cual.
- `worker/src/index.js` menciona `worker/sql/010_aviso_turno.sql` en un aviso de
  error, pero ese archivo no existe; la tabla `aviso_turno_enviado` vive en
  `db/migrations/035_aviso_turno.sql`.
- El comentario de `web/Dockerfile` dice «Requiere en next.config.js», pero el
  archivo real es `next.config.ts`.
- ~~La Fase 2 del asistente no tiene reporte ni está en git.~~ **Resuelto por la
  Fase A2** (12-ago-2026): `docs/reporte-fase2-borrador-consulta.md` y `079`–`083`
  versionados. La Fase 6 (métricas) sigue sin empezar: es la **Fase B5** del plan.
- `worker/src/index.js` lee `WORKER_RESCATE_MIN` y `worker/src/telegram.js` lee
  `TELEGRAM_TIMEOUT_MS`, pero **ninguna de las dos aparece en `.env.example` ni
  en el bloque `environment:` del servicio `worker`** de `docker-compose.yml`:
  hoy no hay manera de fijarlas por compose, siempre corren con su valor por
  defecto (15 min y 15000 ms). No las "arregle" en el código; si el usuario las
  necesita, hay que declararlas en compose y en `.env.example`.
- `opencode.json`, `.strictcontext/` y `.strictcontext.db` no están en
  `.gitignore`: cualquier `git add -A` los versionaría, y `opencode.json` lleva
  una credencial real. (`.env.bak.*` sí queda cubierto por el patrón `.env.*`.)
- `README.md` declara el sistema «terminado (paso 8 de 8)»: eso aplica al MVP, no
  al trabajo actual (bloque B del plan de consolidación, sin empezar).
- ~~No hay migrador ni tabla de versiones.~~ **Resuelto por la Fase A1**: el estado
  de cada ambiente se consulta con `bash scripts/migrar.sh --estado`. Ya no hay que
  adivinar mirando `pg_proc`.
- Estrategia de ramas y proceso de despliegue a producción:
  `[PENDIENTE DE VERIFICAR]` (una sola rama local, sin remoto, sin CI).
- Estado de la facturación electrónica DIAN: **no implementada**; el sistema emite
  un recibo interno consecutivo que no es documento tributario (`README.md`).
