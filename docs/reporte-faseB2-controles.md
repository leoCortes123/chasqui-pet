# Reporte — Fase B2: control y recordatorios

**Fecha:** 13 de agosto de 2026
**Depende de:** B1 (`docs/reporte-faseB1a-agenda-nucleo.md`,
`docs/reporte-faseB1b-agenda-canales.md`).

---

## 1. Cambios realizados

`consulta.proxima_revision` deja de ser un dato muerto. Antes de esta
fase, el veterinario anotaba «revisión en 15 días» por botón en el bot,
por formulario en el portal o dictándoselo al asistente, y **nadie volvía
a leer ese campo**: no existía una sola función con
`WHERE proxima_revision <= …`. Lo único que lo miraba era el mensaje del
día al dueño y un contador en un reporte.

Ahora:

1. **Al fijar la revisión se ofrece agendarla.** Botón en el resumen de la
   consulta en el bot y en la lista del portal. No se agenda sola: un
   control ocupa un cupo real y decidirlo por el veterinario sería
   llenarle la agenda.
2. **`agendar_control`** convierte la revisión en cita reutilizando
   `crear_cita` de B1 —no hay un segundo mecanismo de agenda— y deja el
   vínculo en `cita.consulta_origen_id`.
3. **`controles_pendientes`** responde «a quién hay que llamar», incluidos
   los vencidos.
4. **`controles_avisar`**, en el job diario de las 18:00, avisa al dueño
   unos días antes de un control **que todavía no tiene cita**. Si ya la
   tiene, se calla: de eso se encarga `agenda_recordatorios` (B1b).
5. **Vacunación y desparasitación quedan fuera, con el porqué escrito**
   (decisión 5 y §10 de la migración).

---

## 2. Archivos modificados

| Archivo | Qué |
|---|---|
| `db/migrations/180_controles.sql` | **Nuevo.** Toda la fase. Ámbito: VERTICAL. |
| `n8n/workflows/05-job-agenda.json` | Nodo nuevo «Avisar controles próximos», encadenado tras las inasistencias. |
| `web/src/lib/agenda.ts` | `controlesPendientes` y sus tipos. |
| `web/src/app/(portal)/agenda/page.tsx` | Bloque «Controles por agendar». |
| `web/src/app/(portal)/agenda/acciones.ts` | Acción `agendarControl`. |
| `web/src/app/(portal)/agenda/panel.tsx` | `BotonAgendarControl`. |
| `db/pruebas/092_controles.sql` | **Nuevo.** 22 invariantes. |
| `docs/reporte-faseB2-controles.md` | Este reporte. |

No se tocó ninguna migración ya aplicada, ni el worker, ni los otros
cuatro workflows.

---

## 3. Base de datos

### Esquema

- `cita.consulta_origen_id` (FK a `consulta`, índice parcial): de qué
  consulta salió el control. Sin esta columna no hay forma de responder
  «¿este control ya está agendado?», que es la pregunta de la que dependen
  las tres cosas de la fase.
- `aviso_control_enviado (consulta_id, tipo, enviado_at)`, PK compuesta.
  Mismo diseño que `aviso_turno_enviado` (`035`): el
  `INSERT … ON CONFLICT DO NOTHING` es la operación atómica que decide
  quién manda el aviso, sin carreras.

### Funciones

| Función | Contrato |
|---|---|
| `control_cita(p_consulta_id)` | La cita viva del control, o NULL. Cancelada y no asistida **no** cuentan. |
| `agendar_control(p_actor, p_consulta_id, p_args, p_canal)` | → `{ok, cita, mensaje}`. Idempotente. |
| `controles_pendientes(p_actor, p_sede_id, p_dias)` | → `{ok, controles, total, vencidos, …}` |
| `controles_avisar(p_dias)` | Job. → `{ok, fecha_control, encolados, sin_canal}` |
| `op_controles_pendientes` | La lectura del asistente. |
| `bot_ctl_menu`, `bot_ctl_lista`, `bot_ctl_callback`, `bot_ctl_texto` | Módulo del bot, prefijo `ctl:`, comando `/controles`. |

### Funciones reemplazadas (cambio aditivo)

- **`bot_cli_resumen`** (`056:451`): se conserva palabra por palabra y se
  agregan dos cosas — la fila «📅 Agendar el control», visible solo cuando
  hay revisión anotada y todavía no hay cita, y la línea «✅ El control ya
  está agendado» cuando sí la hay. Va aquí porque este resumen es la
  pantalla que el veterinario ve justo después de fijar la revisión y otra
  vez al firmar.
- `bot_menu_extra`, `bot_modulo_callback`, `bot_modulo_texto` y
  `bot_texto_ayuda`: se intercala `bot_ctl_*` conservando el orden de la
  versión de `170`. `bot_ia_texto` sigue de último.

### Catálogo del asistente

| Herramienta | Permiso | Escribe | Función |
|---|---|---|---|
| `controles_pendientes` | `agenda.ver` | no | `op_controles_pendientes` |

No hizo falta escritura nueva: `agendar_cita` (B1b) ya agenda.

### Configuración

`control_aviso_dias_antes` (3) y `control_hora_defecto` (`09:00`).

### Migración

`180_controles.sql`, idempotente. Aplicada con `scripts/migrar.sh`;
verificada desde cero en cada corrida de `scripts/pruebas.sh`.

---

## 4. Integraciones

- **n8n**: el workflow `05-job-agenda.json` tiene ahora tres nodos —
  recordar citas → marcar inasistencias → avisar controles. Reimportado
  con `scripts/importar-n8n.sh`.
- **Worker**: sin cambios. El aviso reutiliza `enviar_aviso_dueno` y su
  validación de consentimiento.
- **Bot**: módulo `bot_ctl_*` enganchado; `/controles` en la ayuda; botón
  en el resumen de la consulta.
- **Portal**: bloque nuevo en `/agenda`.
- **Agenda (B1)**: `agendar_control` no agenda por su cuenta; llama a
  `crear_cita`, que sigue siendo la única puerta con su restricción
  EXCLUDE y su auditoría.

---

## 5. Pruebas ejecutadas

`bash scripts/pruebas.sh` — **11 archivos, todos en verde (209 pruebas).**

| # | Prueba | Esperado | Obtenido | PASS/FAIL |
|---|---|---|---|---|
| 1 | Lista de pendientes | Las 3 consultas con revisión anotada | igual | PASS |
| 2 | Control vencido | Se cuenta como vencido, no se pierde | 1 | PASS |
| 3 | `controles_pendientes` sin permisos | SQLSTATE 42501 | igual | PASS |
| 4 | `agendar_control` sin permisos | 42501, antes de mirar datos | igual | PASS |
| 5 | Agendar el control | `ok:true` | igual | PASS |
| 6 | Tipo de la cita | `control` | igual | PASS |
| 7 | Fecha | La que anotó el veterinario, sin reescribirla | igual | PASS |
| 8 | Vínculo | `cita.consulta_origen_id` apunta a la consulta | igual | PASS |
| 9 | Auditoría | Evento `consulta/agendar_control` | igual | PASS |
| 10 | **Idempotencia** | Segundo intento → `ya_estaba: true` | igual | PASS |
| 11 | Y no crea otra cita | Conteo intacto | igual | PASS |
| 12 | Lo agendado sale de la lista | Quedan 2 pendientes | igual | PASS |
| 13 | Si la cita se cancela | El control vuelve a estar pendiente (3) | igual | PASS |
| 14 | Consulta sin revisión | `sin_fecha` | igual | PASS |
| 15 | Consulta inexistente | `sin_consulta`, sin excepción | igual | PASS |
| 16 | Aviso | Encola 1 (dueño que autorizó) | igual | PASS |
| 17 | **Ley 1581** | Cuenta 1 sin canal y no le escribe | igual | PASS |
| 18 | Asincronía | El aviso queda en `tarea_async` | igual | PASS |
| 19 | **Idempotencia del job** | Segunda corrida encola 0 | igual | PASS |
| 20 | Sin canal no se marca | 0 filas en `aviso_control_enviado` | igual | PASS |
| 21 | El bot ofrece agendar | El resumen trae `ctl:agendar` | igual | PASS |
| 22 | Y no lo ofrece sin revisión | No aparece | igual | PASS |
| 23 | Regresión | Los 10 archivos previos siguen en verde | 187 pruebas ✔ | PASS |

**Web:** `tsc --noEmit` PASS; `next build` PASS; `/health` 200 tras
reconstruir el contenedor.

**Base de trabajo** (tras `scripts/migrar.sh`, todo dentro de una
transacción con `ROLLBACK`):

| Prueba | Resultado |
|---|---|
| `verificar_registro_operaciones()` | `ok: true` con la herramienta nueva dentro |
| `controles_pendientes` sobre los datos demo | **3 controles reales** listados |
| `controles_avisar()` | corre sin error (0 encolados: ninguno cae en la fecha de aviso) |
| `bot_texto_ayuda` incluye `/controles` | sí |
| `scripts/importar-n8n.sh` | los 5 workflows publicados |

---

## 6. Decisiones tomadas

1. **El control se ofrece, no se agenda solo.** Una cita ocupa un cupo y
   compromete al dueño; crearla sin que nadie la pida llenaría la agenda
   de citas fantasma que después hay que cancelar una por una.
2. **`agendar_control` no agenda: llama a `crear_cita`.** Todo lo que B1
   protege —el permiso, la restricción EXCLUDE contra el solapamiento, el
   bloqueo, la auditoría— sigue aplicando sin copiarse.
3. **La memoria de lo avisado va en tabla aparte.** Una consulta firmada
   es inmutable: el trigger `consulta_inmutable` (`050:247`) rechaza
   cualquier UPDATE que no sea la anulación, así que un sello dentro de
   `consulta` era imposible. `aviso_control_enviado` replica el patrón que
   ya existe para turnos.
4. **Un control con cita no recibe aviso propio.** El recordatorio de la
   cita (B1b) ya cubre ese caso. Si la cita se cancela, el control vuelve
   solo a la lista de pendientes, que es justo cuando hay que llamar.
5. **Vacunación y desparasitación quedan fuera, y no es pereza.** El plan
   decía «si el modelo de datos lo permite sin inventar un módulo nuevo».
   No lo permite: no hay registro de vacunas por paciente —`tipo_servicio`
   'vacunacion' y la tarifa 'vacuna' son cosas que se cobran, no dosis
   aplicadas— ni esquema de vacunación (producto → dosis → intervalo →
   refuerzo), sin el cual no hay «próxima» que calcular. La
   desparasitación está peor: hoy es una tarifa de valor libre. Mientras
   tanto, el veterinario que vacuna anota la próxima revisión y el control
   entra por el mismo camino que todos. Está escrito en §10 de la
   migración para que no haya que redescubrirlo.
6. **El botón del bot solo aparece si hay algo que hacer.** `bot_ctl_menu`
   devuelve `[]` cuando no hay controles en 7 días: un menú con opciones
   que no llevan a ninguna parte es ruido en una pantalla de celular.
7. **Los vencidos se muestran, no se ocultan.** `dias_faltan` sale
   negativo y los canales lo dicen («vencido hace 5 días»). Un control que
   se pasó de fecha es el que más importa.
8. **El portal dice a quién hay que llamar por teléfono.** Si el dueño no
   tiene Telegram o no autorizó el contacto, la fila lo marca con «sin
   Telegram: llamar» en vez de dejar esperando un mensaje que nunca va a
   salir.

---

## 7. Incertidumbres restantes

- **La hora que se propone para un control** es el primer cupo libre del
  día, sin mirar preferencia del dueño ni del veterinario. Si esa hora no
  sirve, se cambia con «Reprogramar» sobre la cita ya creada.
- **La ventana de la lista son 15 días** (7 para el botón del menú del
  bot). Son constantes en el código, no configuración; se dejaron así
  hasta saber cómo trabaja la clínica.
- **Un solo aviso por control**, igual que en B1b. Si el dueño no responde
  no hay insistencia automática: la lista de pendientes es lo que sostiene
  el seguimiento manual.
- **`controles_pendientes` filtra por sede** con
  `COALESCE(consulta.sede_id, sede_actual)`. Una consulta antigua sin
  `sede_id` se atribuye a la sede del que consulta; con una sola sede
  activa es indistinto.

---

## 8. Riesgos y problemas encontrados

- **Dos pruebas fallaron por el mismo motivo y vale la pena dejarlo
  escrito**: una función `STABLE` no ve, dentro de la misma sentencia, un
  cambio hecho por otra función de esa misma sentencia. Pasó al comprobar
  que cancelar la cita devuelve el control a la lista, y ya había pasado
  en B1b con `abrir_consulta`. La regla práctica para estas pruebas: la
  escritura va en su propia sentencia.
- **`controles_pendientes` llama a `control_cita` por fila.** Con el
  volumen de una clínica es irrelevante (el índice parcial de
  `consulta_origen_id` lo cubre), pero si algún día la ventana se amplía a
  meses conviene mirarlo.
- **`bot_ctl_menu` consulta los pendientes en cada dibujado del menú
  principal**, igual que `bot_age_menu` cuenta las citas. Es el precio de
  que el botón muestre el número.
- **El nodo de controles corre después de los otros dos** en el mismo
  workflow: si el primero falla, los siguientes no corren. Es el
  comportamiento que ya tenían los otros jobs encadenados (mantenimiento);
  se mantuvo por coherencia, y n8n guarda la ejecución fallida.

---

## 9. Desviaciones respecto al plan

- El plan mencionaba «ofrecer crear la cita» al fijar `proxima_revision`;
  además del ofrecimiento se agregó la **lista de pendientes** (bot,
  portal y asistente). Sin ella, lo que no se agendó en el momento se
  perdía igual que antes, y el job de avisos no tendría de dónde salir.
- Vacunación y desparasitación: no implementadas, con la justificación
  escrita en la propia migración, como el plan autorizaba.

---

## 10. Trabajo pendiente

1. **Fase B3 — Remisiones externas** (independiente de B1/B2) o **B4 —
   plan multi-tarea**, según prioridad.
2. **Carné de vacunación**: si la clínica lo quiere, es un módulo nuevo
   (catálogo de biológicos, esquema por especie, dosis aplicadas), no una
   extensión de esta fase.
3. **Insistencia en los controles sin respuesta**: hoy el seguimiento tras
   el primer aviso es manual, apoyado en la lista de pendientes.
