# Reporte — Fase B1a: agenda de citas (núcleo)

**Fecha:** 12 de agosto de 2026
**Alcance de esta tanda:** el núcleo SQL de la agenda. Los canales (portal,
bot, herramienta del asistente y recordatorios al dueño) quedan para la
tanda B1b, por decisión explícita del usuario al abrir la fase.

---

## 1. Cambios realizados

La agenda de citas existía como cascarón desde `050_pacientes.sql`: las
tablas `cita` y `disponibilidad` estaban modeladas y ninguna función las
leía ni las escribía; `consulta.cita_id` siempre quedaba `NULL`. Esta
tanda la pone en pie:

1. **Revisión de la forma de las tablas** (lo que el plan pide antes de
   escribir nada encima) y corrección de lo que no aguantaba.
2. **Restricción de exclusión contra la doble reserva**: dos citas del
   mismo veterinario —o del mismo consultorio— no pueden solaparse. Es una
   reja del motor, no una consulta previa: entre un `SELECT` de
   verificación y el `INSERT` cabe otra recepcionista.
3. **Tabla `bloqueo_agenda`**: ausencia, festivo, almuerzo, cirugía. Antes,
   la única manera de tapar un hueco era desactivar la franja entera.
4. **Las seis funciones de negocio que pide el plan** más tres de soporte
   sin las cuales la agenda no tendría qué ofrecer.
5. **Permisos `agenda.ver` y `agenda.gestionar`**, sembrados por rol.
6. **`consulta.cita_id` deja de ser una columna muerta**: la consulta que
   nace del turno de una cita hereda el vínculo.
7. **Batería de invariantes** propia (34 pruebas) y seis rejas más en la
   batería de permisos.

---

## 2. Archivos modificados

| Archivo | Qué |
|---|---|
| `db/migrations/160_agenda.sql` | **Nuevo.** Toda la fase. Ámbito: VERTICAL. |
| `db/pruebas/090_agenda.sql` | **Nuevo.** 34 invariantes de la agenda. |
| `db/pruebas/010_permisos.sql` | Nueve rejas nuevas (`plan(29)` → `plan(38)`). |
| `docs/reporte-faseB1a-agenda-nucleo.md` | Este reporte. |

No se tocó ninguna migración ya aplicada, ningún archivo del worker, de la
web ni de n8n.

---

## 3. Base de datos

### Extensión

`btree_gist`. Es lo que permite mezclar en una misma restricción `EXCLUDE`
una igualdad (el veterinario) con un solapamiento de rangos (la hora).

### Tablas

**`cita`** — columnas nuevas, todas con `ADD COLUMN IF NOT EXISTS`:

| Columna | Para qué |
|---|---|
| `canal_origen` | Por dónde entró la cita (`telegram`/`web`/`sistema`). |
| `confirmada_at` | Confirmación previa del dueño. Queda lista para B1b. |
| `cancelada_at`, `cancelada_por`, `motivo_cancelacion` | Quién canceló, cuándo y por qué. |
| `recordatorio_enviado_at` | Reja de idempotencia del job diario de recordatorios. |

Restricciones nuevas:

- `cita_canal_origen_check`.
- `cita_sin_choque_veterinario` — `EXCLUDE USING gist` sobre
  `(veterinario_id =, tstzrange(inicio_at, fin_at, '[)') &&)`, parcial:
  solo estados `programada` y `confirmada`.
- `cita_sin_choque_consultorio` — la misma idea sobre el consultorio.

**`disponibilidad`** — `sede_id` (el consultorio es opcional, así que la
sede no siempre se deduce de él) y `duracion_slot_min` (cada cuánto se
ofrece un cupo dentro de la franja; 0 = la duración del tipo de servicio).
Índice único `(veterinario_id, dia_semana, hora_inicio, vigente_desde)`
para que `definir_disponibilidad` pueda ser idempotente.

**`bloqueo_agenda`** — nueva. `sede_id`, `veterinario_id` (NULL = toda la
sede, que es como se expresa un festivo), `inicio_at`, `fin_at`, `motivo`,
`activo`. No se borra: se desactiva.

### Funciones

| Función | Contrato |
|---|---|
| `crear_cita(p_actor, p_args jsonb, p_canal)` | → `{ok, cita, mensaje}` |
| `reprogramar_cita(p_actor, p_cita_id, p_inicio, p_veterinario_id, p_motivo, p_canal)` | → `{ok, cita}` |
| `cancelar_cita(p_actor, p_cita_id, p_motivo, p_canal)` | → `{ok, cita}` |
| `confirmar_asistencia(p_actor, p_cita_id, p_canal)` | → `{ok, cita, turno}` |
| `agenda_del_dia(p_actor, p_sede_id, p_fecha, p_veterinario_id)` | → `{ok, fecha, citas, total, por_estado}` |
| `horarios_disponibles(p_actor, p_sede_id, p_fecha, p_tipo_codigo, p_veterinario_id)` | → `{ok, fecha, duracion_min, slots, total}` |
| `definir_disponibilidad(p_actor, p_args, p_canal)` | soporte: la franja semanal del médico |
| `bloquear_agenda(p_actor, p_args, p_canal)` / `liberar_bloqueo(p_actor, p_bloqueo_id, p_canal)` | soporte: los huecos |
| `cita_json(uuid)`, `agenda_sede(uuid, uuid)`, `agenda_instante(text)` | presentación y utilidades |
| `abrir_consulta(...)` | **reemplazo aditivo**: hereda `cita_id` |

Todas exigen su permiso con `exigir_permiso` **antes de mirar un solo
dato**, auditan lo que corresponde y devuelven `{ok, …}`.

### Permisos

`agenda.ver` y `agenda.gestionar` (módulo `agenda`), otorgados a
superadmin, admin, veterinario, auxiliar y recepción. Recepción los tiene
los dos porque agendar es literalmente su trabajo (§4); el veterinario
también, porque quien fija el control de una mascota es él.

### Configuración

`agenda_paso_min` (15) y `agenda_horizonte_dias` (90), ambos editables
desde el portal.

### Migración

`160_agenda.sql`, idempotente (`ADD COLUMN IF NOT EXISTS`,
`CREATE TABLE IF NOT EXISTS`, `ON CONFLICT DO NOTHING`, restricciones
creadas dentro de un `DO` que consulta `pg_constraint`). Aplicada con
`bash scripts/migrar.sh` a la base de desarrollo; verificada además desde
cero en cada corrida de `scripts/pruebas.sh`.

---

## 4. Integraciones

- **Cola de turnos:** `confirmar_asistencia` llama a `crear_turno_manual`
  (`030:252`) — no reimplementa la creación de turnos — y ata
  `cita.turno_id`.
- **Historia clínica:** `abrir_consulta` copia `cita_id` cuando el turno
  nació de una cita. Es el círculo agenda → cola → historia.
- **Bot, portal, n8n y worker:** sin cambios en esta tanda. Nada de lo
  existente cambió de contrato.

---

## 5. Pruebas ejecutadas

`bash scripts/pruebas.sh` — base efímera levantada desde `db/migrations/`.
**9 archivos, todos en verde.**

| # | Prueba | Esperado | Obtenido | PASS/FAIL |
|---|---|---|---|---|
| 1 | Agendar una cita | `ok:true`, estado `programada` | igual | PASS |
| 2 | Duración del cupo | Sale del tipo de servicio (15 min), no de quien agenda | igual | PASS |
| 3 | Doble reserva del mismo veterinario | `motivo:'ocupado'` | igual | PASS |
| 4 | Tras el choque | Ninguna cita creada a medias | 1 cita | PASS |
| 5 | Cita en el pasado | `inicio_pasado` | igual | PASS |
| 6 | Mascota inexistente | `paciente_inexistente` | igual | PASS |
| 7 | Sin fecha y hora | `sin_inicio` | igual | PASS |
| 8 | Tipo de servicio inventado | `tipo_desconocido` | igual | PASS |
| 9 | Agendar a 400 días | `fuera_de_horizonte` | igual | PASS |
| 10 | Auditoría de la creación | Evento `cita/crear` | igual | PASS |
| 11 | Sin disponibilidad declarada | 0 cupos, sin error | igual | PASS |
| 12 | Declarar franja 08:00–12:00 | `ok:true` | igual | PASS |
| 13 | Cupos de la franja | 16 posibles − 1 tomado = 15 | 15 | PASS |
| 14 | El cupo ocupado | No se ofrece | no aparece | PASS |
| 15 | Bloquear una franja con cita dentro | Informa 1 cita afectada, no la cancela | igual | PASS |
| 16 | Agendar dentro de un bloqueo | `agenda_bloqueada` | igual | PASS |
| 17 | Liberar el bloqueo | `ok:true`, la franja vuelve a estar libre | igual | PASS |
| 18 | Reprogramar | Misma cita, hora nueva | igual | PASS |
| 19 | Reprogramar reinicia el recordatorio | `recordatorio_enviado_at` NULL | igual | PASS |
| 20 | Reprogramar encima de otra cita | `ocupado` | igual | PASS |
| 21 | Cancelar con motivo | `ok:true`, motivo guardado, fila conservada | igual | PASS |
| 22 | Cancelar dos veces (idempotencia) | `ya_estaba:true` | igual | PASS |
| 23 | Reprogramar una cancelada | `estado_no_reprogramable` | igual | PASS |
| 24 | Auditoría de la cancelación | Evento `cita/cancelar` | igual | PASS |
| 25 | Confirmar asistencia | Genera turno, cita `cumplida` | igual | PASS |
| 26 | Confirmar dos veces (idempotencia) | El mismo turno, no otro | igual | PASS |
| 27 | `consulta.cita_id` | La consulta hereda la cita | igual | PASS |
| 28 | Agenda del día | Lista las 2 citas y las resume por estado | igual | PASS |
| 29 | Cita inexistente | `sin_cita`, sin excepción | igual | PASS |
| 30 | Permisos (9 funciones nuevas) | SQLSTATE 42501 con actor sin permisos | igual | PASS |
| 31 | Regresión | Los 8 archivos previos de la batería siguen en verde | 126 pruebas ✔ | PASS |

Verificación sobre la base de desarrollo tras `scripts/migrar.sh`: los dos
permisos existen y están repartidos a los cinco roles, las dos claves de
configuración están sembradas, las dos restricciones `EXCLUDE` están en
`pg_constraint` y las seis funciones del plan existen. Sin escrituras de
prueba sobre datos reales.

---

## 6. Decisiones tomadas

1. **La franja sugiere, no prohíbe.** `horarios_disponibles` ofrece los
   cupos que salen de `disponibilidad`, pero `crear_cita` **no** exige que
   la hora caiga dentro de una franja: una clínica real encaja pacientes
   fuera de horario. Lo infranqueable es el solapamiento y el bloqueo.
2. **Reprogramar mueve la misma fila**, no cancela y crea otra. El dueño
   conserva «su» cita, la restricción `EXCLUDE` no choca contra la versión
   vieja de sí misma y la historia queda en `evento_auditoria` con antes y
   después. Por eso no se agregó una columna `cita_origen_id`.
3. **`confirmar_asistencia` es la llegada al mostrador**, no la
   confirmación telefónica previa: genera el turno del día. El estado
   `confirmada` y `confirmada_at` quedan reservados para el recordatorio
   de B1b.
4. **El choque lo decide el motor.** Se captura `exclusion_violation` y se
   traduce a `{ok:false, motivo:'ocupado'}`, en vez de validar antes con un
   `SELECT` que deja la carrera abierta.
5. **Rangos semiabiertos `[)`** en las dos definiciones de «choque» —la de
   la restricción y la de la consulta de cupos—: una cita que termina a las
   10:00 y otra que empieza a las 10:00 no se solapan. Si las dos
   definiciones no coincidieran, el sistema ofrecería cupos que después
   rechazaría al insertar.
6. **Hora sin zona = hora de Bogotá** (`agenda_instante`). El texto con
   offset explícito se respeta. Un `::timestamptz` a secas usaría la zona
   de la sesión, que en el worker o en un `psql` suelto puede no ser la de
   la clínica.
7. **Bloquear no cancela citas.** Se informa cuántas quedan dentro del
   bloqueo para que alguien llame y las reprograme; cancelarlas en silencio
   dejaría a un dueño esperando en la puerta.
8. **Se agregaron tres funciones de soporte** fuera de la lista del plan
   (`definir_disponibilidad`, `bloquear_agenda`, `liberar_bloqueo`). Sin
   ellas, `disponibilidad` seguiría siendo un cascarón y
   `horarios_disponibles` no tendría nunca nada que ofrecer.

---

## 7. Incertidumbres restantes

- **Quién ve la agenda de quién.** Hoy `agenda_del_dia` muestra toda la
  sede a cualquiera con `agenda.ver`, con filtro opcional por veterinario.
  Si la clínica quisiera que cada médico viera solo la suya, es una regla
  nueva, no un ajuste.
- **Duración por tipo de servicio vs. por médico.** El cupo dura lo que
  dice `tipo_servicio`; `duracion_slot_min` solo cambia cada cuánto se
  ofrece. Si un médico necesita 30 minutos para lo que otro hace en 15, hoy
  se resuelve pasando `duracion_min` explícito al agendar.
- **Sedes múltiples.** `horarios_disponibles` deduce la sede de la franja
  con `COALESCE(disponibilidad.sede_id, consultorio.sede_id, usuario.sede_id)`.
  Con una sola sede activa es indistinto; con varias conviene poblar
  siempre `disponibilidad.sede_id`.

---

## 8. Riesgos y problemas encontrados

- **`btree_gist` es una dependencia nueva** del esquema. Viene en la
  imagen `postgres:16-alpine` (contrib) y la migración la crea con
  `CREATE EXTENSION IF NOT EXISTS`, que exige privilegios de superusuario:
  funciona porque las migraciones corren como dueño de la base
  (`ADMIN_DATABASE_URL`), nunca como `chasquipet_app`.
- **Estado `no_asistio` sin quien lo escriba.** El `CHECK` de `cita` lo
  admite desde `050`, pero ninguna función de esta tanda lo asigna: le
  corresponde al job diario de B1b, junto con los recordatorios. Hasta
  entonces es un estado alcanzable solo a mano.
- **Un hallazgo lateral al escribir las pruebas**: `abrir_consulta` acepta
  `canal_origen` solo en `telegram`/`web` (`CHECK` de `050:210`). No es un
  problema nuevo ni se tocó; queda anotado porque cualquier canal futuro
  que llame a esa función con otro valor fallará.

---

## 9. Desviaciones respecto al plan

- El plan lista seis funciones; se entregan **nueve**. Las tres extra son
  las de soporte de la decisión 8.
- «Enlazar `consulta.cita_id` cuando el turno viene de una cita agendada»
  está hecho; los demás puntos del alcance de B1 (canales y recordatorios)
  se posponen a B1b por decisión del usuario, no por omisión.

---

## 10. Trabajo pendiente (B1b)

1. **Portal**: vista de agenda del día y de cupos, con las acciones de
   agendar, reprogramar, cancelar y registrar llegada.
2. **Bot**: flujo de botones para agendar y para registrar la llegada.
3. **Asistente**: herramienta en `ia_herramienta` con su `funcion` y su
   `funcion_borrador` (tras A5, es un `INSERT` y un envoltorio), con
   confirmación humana obligatoria (C6.9).
4. **Recordatorios**: job programado de n8n a las 18:00 que recorre las
   citas del día siguiente y encola `enviar_aviso_dueno` respetando las
   tres capas de validación de consentimiento; `recordatorio_enviado_at`
   es la reja de idempotencia y ya está en su sitio.
5. **Marcar `no_asistio`** en el mismo job, para las citas del día que
   pasaron sin turno.
