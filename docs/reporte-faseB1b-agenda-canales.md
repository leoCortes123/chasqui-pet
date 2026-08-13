# Reporte — Fase B1b: la agenda sale a los canales

**Fecha:** 13 de agosto de 2026
**Alcance de esta tanda:** portal, bot, asistente y recordatorios sobre el
núcleo entregado en B1a (`docs/reporte-faseB1a-agenda-nucleo.md`). Con
esto, la Fase B1 del plan de consolidación queda completa.

---

## 1. Cambios realizados

1. **Job diario** (n8n, 18:00): recordatorio por Telegram de las citas del
   día siguiente e inasistencias marcadas al cierre.
2. **Módulo del bot** (`bot_age_*`): ver la agenda de cualquier día,
   registrar la llegada, agendar, reprogramar y cancelar desde Telegram,
   más el comando `/agenda`.
3. **Asistente**: tres herramientas nuevas —dos lecturas y una escritura
   con confirmación humana obligatoria (C6.9)—, registradas de forma
   declarativa como pide la Fase A5.
4. **Portal**: sección `/agenda` con el día, los cupos libres y las cuatro
   acciones.
5. **Pruebas**: 26 invariantes nuevos y una aserción más en el invariante
   C6.9 que ya recorría el catálogo.

No se agregó ni una regla de negocio: los cuatro canales llaman a las
funciones de B1a y ninguno decide nada por su cuenta.

---

## 2. Archivos modificados

| Archivo | Qué |
|---|---|
| `db/migrations/170_agenda_canales.sql` | **Nuevo.** Job, bot, asistente y enganches. Ámbito: VERTICAL. |
| `n8n/workflows/05-job-agenda.json` | **Nuevo.** Cron 18:00 → recordatorios → inasistencias. |
| `web/src/lib/agenda.ts` | **Nuevo.** Lectura de la agenda para el portal. |
| `web/src/app/(portal)/agenda/page.tsx` | **Nuevo.** La vista. |
| `web/src/app/(portal)/agenda/acciones.ts` | **Nuevo.** Las cuatro server actions. |
| `web/src/app/(portal)/agenda/panel.tsx` | **Nuevo.** Piezas interactivas. |
| `web/src/app/(portal)/layout.tsx` | Enlace «Agenda» en la navegación, condicionado a `agenda.ver`. |
| `db/pruebas/091_agenda_canales.sql` | **Nuevo.** 26 invariantes de los canales. |
| `db/pruebas/070_ia_confirmacion.sql` | Una aserción más: la IA tampoco agenda sin confirmar (`plan(15)` → `plan(16)`). |
| `docs/reporte-faseB1b-agenda-canales.md` | Este reporte. |

No se tocó ninguna migración ya aplicada, ni el worker, ni los otros
cuatro workflows de n8n.

---

## 3. Base de datos

### Funciones nuevas (`170_agenda_canales.sql`)

| Función | Para qué |
|---|---|
| `agenda_recordatorios(p_dias int)` | Encola el aviso de las citas de dentro de N días. Devuelve `{ok, fecha, encolados, sin_canal}`. |
| `agenda_marcar_no_asistio()` | Cita vencida sin turno → `no_asistio`. Devuelve `{ok, marcadas}`. |
| `bot_age_menu`, `bot_age_dia`, `bot_age_cita`, `bot_age_cupos`, `bot_age_callback`, `bot_age_texto` | El módulo del bot. |
| `op_agenda_del_dia`, `op_horarios_disponibles`, `op_agendar_cita` | Operaciones del asistente, firma uniforme `(uuid, uuid, jsonb) → jsonb`. |
| `ia_agenda_borrador` | Arma la propuesta que la persona confirma. |

### Funciones reemplazadas (cambio aditivo, verificado línea por línea)

`bot_menu_extra`, `bot_modulo_callback`, `bot_modulo_texto` y
`bot_texto_ayuda`. Se partió de **la versión vigente, la de `078`** —no de
la de `076`— y solo se intercaló el módulo de agenda. `bot_ia_texto` sigue
de último en `bot_modulo_texto`: si alguien está a mitad de un flujo de
botones, su texto es la respuesta al flujo y no un mensaje para el
asistente.

`ia_texto_resultado` **no se tocó** (ver decisión 4).

### Catálogo del asistente

| Herramienta | Permiso | Escribe | Función | Borrador |
|---|---|---|---|---|
| `agenda_del_dia` | `agenda.ver` | no | `op_agenda_del_dia` | — |
| `horarios_disponibles` | `agenda.ver` | no | `op_horarios_disponibles` | — |
| `agendar_cita` | `agenda.gestionar` | **sí** | `op_agendar_cita` | `ia_agenda_borrador` |

`verificar_registro_operaciones()` no encuentra hallazgos con las tres
dentro.

### Configuración

`agenda_gracia_no_asistio_min` (60): minutos de margen tras la hora de la
cita antes de darla por no asistida.

### Migración

`170_agenda_canales.sql`, idempotente (`CREATE OR REPLACE`,
`ON CONFLICT DO NOTHING`, `UPDATE` por nombre). Aplicada con
`bash scripts/migrar.sh`; verificada desde cero en cada corrida de
`scripts/pruebas.sh`.

---

## 4. Integraciones

- **n8n**: workflow nuevo `05-job-agenda.json`, importado y activo
  (`bash scripts/importar-n8n.sh`; los cinco workflows quedaron
  publicados). Los nodos solo llaman funciones SQL: n8n dispara la hora y
  nada más.
- **Worker**: sin cambios. El recordatorio reutiliza el tipo de tarea
  `enviar_aviso_dueno` y su comprobación de consentimiento, que es
  justamente lo que se quería evitar duplicar.
- **Bot**: módulo nuevo enganchado en los tres despachadores; comando
  `/agenda` en la ayuda.
- **Portal**: ruta `/agenda`, protegida por el layout y por
  `exigirPermiso('agenda.ver')`.
- **Cola de turnos**: sin cambios; el botón «Llegó» del bot y del portal
  entra por `confirmar_asistencia`, que ya usaba `crear_turno_manual`.

---

## 5. Pruebas ejecutadas

`bash scripts/pruebas.sh` — base efímera levantada desde `db/migrations/`.
**10 archivos, todos en verde (187 pruebas).**

| # | Prueba | Esperado | Obtenido | PASS/FAIL |
|---|---|---|---|---|
| 1 | Botón de agenda en el menú del bot | Lo ve quien tiene `agenda.ver` | igual | PASS |
| 2 | Y no lo ve quien no lo tiene | `[]` | igual | PASS |
| 3 | Agenda del día en el bot | Lista la cita con su mascota | igual | PASS |
| 4 | Comando `/agenda` | Responde con la agenda de hoy | igual | PASS |
| 5 | Callback de otro módulo | `bot_age_callback` devuelve NULL | igual | PASS |
| 6 | Texto suelto sin flujo de agenda | `bot_age_texto` devuelve NULL | igual | PASS |
| 7 | Botón «Llegó» | Genera el turno y lo anuncia | igual | PASS |
| 8 | Tras la llegada | La cita queda `cumplida` | igual | PASS |
| 9 | `ia_agenda_borrador` sin permisos | SQLSTATE 42501, antes de mirar datos | igual | PASS |
| 10 | Borrador sin `paciente_id` | `ok:false` con error para el modelo | igual | PASS |
| 11 | Borrador con fecha pasada | `ok:false` | igual | PASS |
| 12 | Borrador válido | `requiere_confirmacion: true` | igual | PASS |
| 13 | **C6.9** | Y **ninguna cita creada** | conteo intacto | PASS |
| 14 | Tarjeta de la propuesta | Muestra los datos reales (nota incluida) | igual | PASS |
| 15 | Confirmar la propuesta | `ok:true` | igual | PASS |
| 16 | Tras confirmar | Exactamente una cita nueva | igual | PASS |
| 17 | Respuesta al usuario | Dice para qué mascota quedó | igual | PASS |
| 18 | Lectura del asistente | Ve las dos citas del día | igual | PASS |
| 19 | Recordatorio | Encola 1 (dueño que autorizó) | igual | PASS |
| 20 | Ley 1581 | Cuenta 1 sin canal y **no** le escribe | igual | PASS |
| 21 | Asincronía | El aviso queda en `tarea_async` | igual | PASS |
| 22 | Sello | `recordatorio_enviado_at` marcado | igual | PASS |
| 23 | **Idempotencia** | Segunda corrida encola 0 | igual | PASS |
| 24 | Inasistencia | Cita vencida sin turno → `no_asistio` | igual | PASS |
| 25 | Y no toca lo atendido | La cumplida sigue cumplida | igual | PASS |
| 26 | Ni el futuro | 0 citas futuras marcadas | igual | PASS |
| 27 | C6.9 ampliado (070) | Ninguna herramienta agenda sin confirmar | igual | PASS |
| 28 | Regresión | Los 9 archivos previos siguen en verde | 161 pruebas ✔ | PASS |

**Web:**

| Prueba | Resultado |
|---|---|
| `tsc --noEmit` | PASS, sin errores |
| `next build` | PASS; la ruta `/agenda` aparece en el manifiesto |

Nota de entorno: `npm run typecheck` y `npm run build` fallan aquí con
`sh: 1: tsc: Permission denied` — los enlaces de `web/node_modules/.bin`
no tienen permiso de ejecución en este árbol. Se corrieron invocando los
binarios directamente (`node node_modules/typescript/bin/tsc --noEmit`,
`node node_modules/next/dist/bin/next build`). No es un problema del
código de esta fase, pero conviene arreglarlo o el comando documentado en
`CLAUDE.md` no sirve tal cual.
| `GET /agenda` sin sesión | 307 a `/entrar` (PASS) |
| `GET /health` tras reconstruir | 200 (PASS) |

**Base de trabajo** (tras `scripts/migrar.sh`, todo dentro de una
transacción con `ROLLBACK`, sin dejar rastro):

| Prueba | Resultado |
|---|---|
| `verificar_registro_operaciones()` | `ok: true` |
| Las tres herramientas con su `funcion`, `funcion_borrador` y `modulo` | correcto |
| `bot_texto_ayuda` incluye `/agenda` | sí |
| `bot_menu_principal` del superadmin incluye el botón | sí |
| `agenda_recordatorios(1)` y `agenda_marcar_no_asistio()` | corren sin error (0 y 0: la base no tiene citas todavía) |
| `scripts/importar-n8n.sh` | los 5 workflows publicados, incluido `chasquipetAgenda` |

---

## 6. Decisiones tomadas

1. **El bot guarda los cupos ofrecidos en `conversacion_estado` y el botón
   lleva su índice.** `callback_data` de Telegram son 64 bytes: una fecha
   con hora más un uuid de veterinario no cabe. El índice sí, y si la
   pantalla caducó el botón lo dice en vez de agendar otra cosa.
2. **La hora también se puede escribir.** Si un día no tiene franja
   declarada —o el cupo que hace falta no está—, el bot acepta `15:30` y
   agenda igual. Es la misma decisión de B1a: la franja sugiere, no
   prohíbe.
3. **El asistente escribe a través de un borrador propio**
   (`ia_agenda_borrador`), como las otras seis herramientas que normalizan
   lenguaje de mostrador. Así la tarjeta de confirmación se arma con datos
   frescos de la base —mascota, dueño, duración real, veterinario— y **no
   hubo que tocar `ia_resumen_accion`**, que es una función de 200 líneas
   con un `CASE` por herramienta.
4. **`ia_texto_resultado` no se reemplazó.** Esa función antepone el
   `mensaje` del resultado a cualquier rama propia
   (`COALESCE(NULLIF(esc(p_resultado->>'mensaje'), ''), CASE …)`), así que
   una rama para `agendar_cita` habría sido código muerto: la primera
   versión de esta fase la incluyó y la prueba lo detectó. El resultado se
   adapta donde corresponde —el envoltorio `op_agendar_cita`, que compone
   el mensaje con la mascota, la fecha y la hora—. Reemplazar una función
   de enganche para agregarle código que no se ejecuta es justo el riesgo
   que la regla de «cambio aditivo» quiere evitar.
5. **El recordatorio se marca en la misma sentencia que lo selecciona**
   (`UPDATE … RETURNING`), no en dos pasos. Dos corridas simultáneas del
   job no pueden encolar el mismo aviso, y además la clave de unicidad de
   `encolar_tarea` lo vuelve a impedir en la cola.
6. **Un dueño sin consentimiento se cuenta pero no se marca.** Aparece en
   `sin_canal` para que el reporte diga la verdad, y su cita queda sin
   sellar: si autoriza el contacto mañana, el recordatorio siguiente sí le
   llega. Marcarla habría sido perder el aviso para siempre.
7. **Bloquear no cancela y avisar no cancela**: ninguna función de esta
   fase cancela una cita por su cuenta. La única transición automática es
   `no_asistio`, y solo sobre citas cuya hora ya pasó con margen.
8. **El estado del portal vive en la URL** (fecha, búsqueda, cupo
   elegido). Así el día que se está mirando se comparte por chat, se
   recarga y funciona con el botón «atrás». Es la misma decisión que el
   buscador de pacientes, y evita estado de cliente que no aporta.

---

## 7. Incertidumbres restantes

- **La hora del recordatorio es fija (18:00, en el cron).** Si la clínica
  la quiere a otra hora hay que editar el workflow y reimportarlo; no es
  configuración de base. Se dejó así porque `agenda_recordatorios(p_dias)`
  ya admite el parámetro y mover el cron es una línea.
- **Un solo recordatorio por cita.** La opción de un segundo aviso «2
  horas antes» se descartó al abrir la fase; `recordatorio_enviado_at`
  como sello único es lo que la implementa. Si algún día se quieren dos,
  hay que cambiar el sello por un contador o una tabla de envíos.
- **El dueño todavía no puede confirmar por Telegram.** El estado
  `confirmada` y la columna `confirmada_at` existen y nadie los escribe
  salvo `confirmar_asistencia`. Falta el botón en el mensaje de
  recordatorio, que exige que el aviso lleve botones — hoy
  `enviar_aviso_dueno` manda texto plano.
- **Reprogramar desde el portal no consulta cupos**: pide fecha y hora
  directamente. Los cupos se ven en la vista del día correspondiente.

---

## 8. Riesgos y problemas encontrados

- **Una rama muerta detectada por las pruebas**, no por revisión: la
  primera versión agregó `agendar_cita` a `ia_texto_resultado` y el
  invariante falló porque `mensaje` gana siempre. Corregido según la
  decisión 4. Queda como aviso para quien agregue la herramienta número
  veintiocho.
- **El bot y el portal comparten la reja del solapamiento, no una copia.**
  Ambos pueden recibir `{ok:false, motivo:'ocupado'}` y los dos lo
  muestran. Si en el futuro alguien valida «antes» en la web para dar
  mejor mensaje, estaría reintroduciendo la carrera que B1a cerró.
- **El job corre a las 18:00 y marca inasistencias de todo el día.** Una
  cita de las 8:00 que nadie atendió queda como pendiente hasta esa hora.
  Es aceptable —la agenda del día se mira en pantalla, no en el estado—
  pero conviene saberlo antes de construir métricas encima (Fase B5).
- **`bot_age_menu` cuenta las citas de hoy en cada dibujado del menú
  principal.** Es un `count` sobre un índice parcial de `cita`; con el
  volumen de una clínica es irrelevante, pero es trabajo que antes no se
  hacía en esa función.

---

## 9. Desviaciones respecto al plan

- El plan pedía «herramienta del asistente» en singular; se entregan tres
  (dos lecturas y la escritura). Sin las lecturas, el modelo no puede
  responder «¿a qué horas hay?» ni proponer una hora razonable antes de
  agendar.
- El plan no mencionaba `no_asistio`; se implementó aquí porque el estado
  existía en el `CHECK` desde `050` sin que nadie lo escribiera, y el job
  diario era su sitio natural. Quedó anotado como pendiente al cerrar
  B1a.

---

## 10. Trabajo pendiente

Fase B1 completa. Lo que queda anotado para después, sin bloquear nada:

1. **Botón de confirmación en el recordatorio** (el dueño responde «ahí
   estaré»), que exige que `enviar_aviso_dueno` admita botones.
2. **Fase B2 — Control y recordatorios**: `consulta.proxima_revision`
   ofreciendo crear la cita correspondiente. Ahora sí hay una agenda donde
   colgarla, que era la razón de que B2 dependiera de B1.
3. **Hora del recordatorio configurable** si la clínica lo pide.
