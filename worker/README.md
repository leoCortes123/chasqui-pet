# Worker de tareas asíncronas — Chasqui Pet

Procesa la cola `tarea_async` de Postgres. El webhook de Telegram debe responder
en menos de un segundo (§2.2), así que todo lo que tome tiempo —notificaciones,
recibos, reportes— se encola con `encolar_tarea(...)` y lo ejecuta este proceso.

## Reparto de responsabilidades

La lógica difícil vive en la base de datos, no aquí:

| Decisión | Quién |
|---|---|
| Qué tarea se reclama (`FOR UPDATE SKIP LOCKED`) | `reclamar_tareas()` |
| Cuánto se espera antes de reintentar (backoff) | `fallar_tarea()` |
| Cuándo una tarea muere y a quién se le avisa | `fallar_tarea()` |
| Rescatar tareas de un worker que murió | `rescatar_tareas_colgadas()` |
| Despachar, ejecutar y reportar el resultado | el worker |

El worker no guarda estado en memoria y **no** reimplementa el backoff. Por eso
se pueden correr varias réplicas en paralelo sin coordinarlas.

## Ciclo

1. Espera a que Postgres responda (reintentos con espera creciente hasta 30 s;
   en `docker compose` los servicios arrancan a la vez).
2. Cada `WORKER_INTERVALO_MS`: `reclamar_tareas(WORKER_LOTE)` y procesa el lote
   en paralelo.
3. Cada tarea termina en `completar_tarea(id, resultado)` o, si el manejador
   lanza, en `fallar_tarea(id, error)`.
4. Cada 5 minutos: `rescatar_tareas_colgadas(15)`.
5. Con `SIGTERM`/`SIGINT`: deja de reclamar, espera a las tareas en vuelo
   (máx. `WORKER_APAGADO_MS`) y cierra el pool.

Los logs van a stdout, en español y con hora de Bogotá, una línea por tarea con
id, tipo, desenlace y milisegundos.

## Variables de entorno

| Variable | Default | Para qué |
|---|---|---|
| `DATABASE_URL` | — | **Obligatoria.** Conexión con el rol de aplicación. |
| `TELEGRAM_BOT_TOKEN` | — | Token del bot (@BotFather). Sin él fallan las tareas que envían mensajes. |
| `WORKER_INTERVALO_MS` | `2000` | Cada cuánto se revisa la cola. |
| `WORKER_LOTE` | `10` | Máximo de tareas por pasada. |
| `WORKER_POOL_MAX` | `max(4, LOTE)` | Conexiones del pool de Postgres. |
| `WORKER_RESCATE_MIN` | `15` | Minutos en `procesando` antes de considerar colgada una tarea. |
| `WORKER_APAGADO_MS` | `25000` | Espera máxima por las tareas en vuelo al apagar. |
| `TELEGRAM_TIMEOUT_MS` | `15000` | Timeout de cada llamada a la Bot API. |
| `TZ` | `America/Bogota` | La fija el Dockerfile. |

## Manejadores actuales

| Tipo | Payload | Qué hace |
|---|---|---|
| `notificar_turno_llamado` | `{turno_id}` | «🔔 Es tu turno **A-042**. Pasa al **Consultorio 2**.» Sin `chat_id` completa sin enviar nada. |
| `notificar_turnos_proximos` | `{sede_id}` | «⏳ Faltan 2 turnos para el tuyo…» a los primeros de la cola, sin repetir. |
| `notificar_superadmin` | `{texto}` | Alarmas del sistema a todo superadmin activo con chat. |
| `recordar_llamado_vencido` | `{sede_id}` | Le recuerda al veterinario un turno llamado que no se presentó, con botones *No se presentó* / *Ya llegó*. |
| `abrir_cuenta_turno` | `{turno_id}` | No-op explícito: el módulo de cobro es el paso 5 (§7). |
| `alertas_inventario` | `{}` o `{forzar}` | Aviso diario (§6.2) a quien administra inventario: bajo mínimo, por vencer y vencidos. Si no hay nada que reportar no envía nada; `forzar` lo manda igual. |
| `agregar_linea_cuenta` | `{movimiento_id, turno_id}` | No-op explícito: la línea en la cuenta la crea el módulo de cobro, paso 5 (§7.1). |

## Cómo agregar un manejador

1. Cree `src/tareas/<tipo>.js`:

   ```js
   export const tipo = 'mi_tarea';

   export async function manejar({ payload }, { db, log, marcarAviso }) {
     // db  → pool de pg (use consultas parametrizadas, siempre)
     // log → log.info / log.aviso / log.error
     return { lo_que_sea: true };   // se guarda en tarea_async.resultado
   }
   ```

2. Impórtelo y agréguelo a `MODULOS` en `src/tareas/index.js`.
3. Encólelo desde donde haga falta:
   `SELECT encolar_tarea('mi_tarea', '{"x":1}'::jsonb);`

Reglas:

- **Devolver** = tarea completada. **Lanzar** = tarea fallida; la base decide el
  backoff y los reintentos. No implemente esperas ni contadores propios.
- Lo que no se arregla reintentando (falta un dato opcional, el usuario bloqueó
  el bot) **no es una excepción**: complete con un resultado que lo explique.
  Reintentar cinco veces algo imposible solo llena la bandeja del superadmin.
- `notificar_superadmin` nunca debe fallar por no tener destinatarios: sería un
  bucle (el fallo genera otro aviso, que vuelve a fallar).
- Todo valor interpolado en un mensaje pasa por `esc()` de `telegram.js`.

## Telegram

`src/telegram.js` usa `fetch` nativo, sin librerías. `enviarMensaje` y
`editarMensaje` devuelven `{ok:true, resultado}` o `{ok:false, motivo}`:

- **429** → respeta `parameters.retry_after`, espera y reintenta una vez.
- **403** (y «chat not found») → `{ok:false, motivo:'bloqueado'}`, sin lanzar:
  el usuario bloqueó el bot y reintentar no lo va a desbloquear.
- Cualquier otro error → lanza, y la tarea se reintenta con el backoff de la base.

## Pendiente de migración

`sql/010_aviso_turno.sql` crea la tabla `aviso_turno_enviado`, que evita repetir
el aviso de «faltan N turnos» en cada pasada. **Debe moverse a `db/migrations/`.**
Mientras no exista, el worker lo registra en el log y sigue funcionando sin
deduplicar.
