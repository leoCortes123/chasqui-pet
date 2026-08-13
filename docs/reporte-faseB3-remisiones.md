# Reporte — Fase B3: remisiones externas y seguimiento de resultados

**Fecha:** 13 de agosto de 2026
**Independiente de B1/B2** (aunque reutiliza la tarea de avisos de la
Fase 5 y el patrón de alertas del inventario).

---

## 1. Cambios realizados

Antes de esta fase, remitir a un laboratorio era escribir una frase en
`consulta.remision_externa` (`050:200`), una columna de texto libre dentro
de la consulta. No había destino, ni estado, ni fecha esperada y, sobre
todo, **no había forma de preguntar qué se mandó y todavía no volvió**. Un
examen que se perdía en el camino se descubría cuando el dueño llamaba a
reclamar.

Ahora:

1. **Módulo `remision`**: qué se pidió, a quién, para qué mascota, desde
   qué consulta, cuándo debería volver, en qué estado está
   (`pendiente → recibida`, o `anulada`).
2. **`resultado_remision`**: lo que llegó —texto, foto o archivo—, con
   quién lo cargó. Varios por remisión, y **append-only**.
3. **Alerta diaria de vencidas** a las 8:00, a quien puede llamar al
   laboratorio. Mismo patrón que `alertas_inventario`.
4. **Aviso al dueño cuando el resultado llega**, reutilizando
   `enviar_aviso_dueno` y sus validaciones de consentimiento (§12).
5. **Los cuatro canales**: portal, bot (incluida la foto de la hoja del
   laboratorio), asistente y job.

`consulta.remision_externa` **no se toca ni se migra**: sigue siendo la
nota clínica dentro de la consulta —que además es inmutable una vez
firmada—. La remisión es el seguimiento administrativo de esa nota, y se
enlazan por `remision.consulta_id`.

---

## 2. Archivos modificados

| Archivo | Qué |
|---|---|
| `db/migrations/190_remisiones.sql` | **Nuevo.** Todo el módulo. Ámbito: VERTICAL. |
| `worker/src/tareas/alertas_remisiones.js` | **Nuevo.** Entrega la alerta diaria. |
| `worker/src/tareas/index.js` | Registra la tarea nueva. |
| `n8n/workflows/06-job-remisiones.json` | **Nuevo.** Cron 8:00 → encola la alerta. |
| `web/src/lib/remisiones.ts` | **Nuevo.** Lectura para el portal. |
| `web/src/app/(portal)/remisiones/{page,acciones,panel}.tsx/ts` | **Nuevos.** La sección. |
| `web/src/app/(portal)/layout.tsx` | Enlace «Remisiones», condicionado a `remision.ver`. |
| `db/pruebas/093_remisiones.sql` | **Nuevo.** 33 invariantes. |
| `docs/reporte-faseB3-remisiones.md` | Este reporte. |

No se tocó ninguna migración ya aplicada ni ningún workflow existente.

---

## 3. Base de datos

### Tablas

**`remision`** — paciente, dueño, consulta de origen, sede, `tipo`
(`laboratorio` / `imagenes` / `especialista` / `otro`), `destino`,
`examenes`, `motivo`, `estado`, `fecha_solicitud`, `fecha_esperada`,
sellos de recepción y anulación, `aviso_dueno_at` y canal de origen.
Índice parcial `(sede_id, fecha_esperada) WHERE estado = 'pendiente'`:
sostiene la pregunta de la fase.

**`resultado_remision`** — `texto`, `adjunto_file_id`, `adjunto_url`,
quién lo cargó y por qué canal. `CHECK` de que traiga algo dentro.
**Append-only**: se revoca `UPDATE`, `DELETE` y `TRUNCATE` a
`chasquipet_app`, igual que en `090_grants.sql` para `pago` y
`movimiento_inventario`.

`destino` es texto y no un catálogo de laboratorios a propósito: el
alcance son la remisión y su resultado; un catálogo con contactos y
horarios es otra cosa y, hasta que la clínica lo pida, sería una tabla
para no usarla.

### Funciones

| Función | Contrato |
|---|---|
| `crear_remision(p_actor, p_args, p_canal)` | → `{ok, remision, mensaje}`. Con `consulta_id`, deriva mascota, dueño, sede y solicitante. |
| `registrar_resultado(p_actor, p_remision_id, p_args, p_canal)` | → `{ok, remision, aviso_dueno}`. Cierra la remisión y encola el aviso. |
| `anular_remision(p_actor, p_remision_id, p_motivo, p_canal)` | → `{ok, remision}`. Idempotente. |
| `remisiones_pendientes(p_actor, p_sede_id, p_limite)` | → `{ok, remisiones, total, vencidas}` |
| `alertas_remisiones()` / `hay_alertas_remisiones()` / `bot_texto_alertas_remisiones()` | El trío del patrón de `045:722-767`. |
| `remision_json(uuid)` | Presentación, con los resultados dentro. |
| `bot_rem_menu/lista/ficha/callback/texto/media` | Módulo del bot, prefijo `rem:`, comando `/remisiones`. |
| `op_remisiones_pendientes`, `op_registrar_remision`, `ia_remision_borrador` | El asistente. |

### Permisos

`remision.ver` y `remision.gestionar` (módulo `clinico`), a los cinco
roles. Cargar el resultado va dentro de `gestionar`: quien recibe el sobre
en el mostrador es quien lo digita, y un tercer permiso solo conseguiría
que nadie lo tuviera.

### Catálogo del asistente

| Herramienta | Permiso | Escribe | Función | Borrador |
|---|---|---|---|---|
| `remisiones_pendientes` | `remision.ver` | no | `op_remisiones_pendientes` | — |
| `registrar_remision` | `remision.gestionar` | **sí** | `op_registrar_remision` | `ia_remision_borrador` |

### Configuración

`remision_dias_espera` (5): días antes de considerar vencida una remisión
sin resultado.

### Funciones reemplazadas (cambio aditivo)

`bot_menu_extra`, `bot_modulo_callback`, `bot_modulo_texto`,
`bot_modulo_media` y `bot_texto_ayuda`, partiendo de las versiones de
`180`. **`bot_modulo_media` deja de ser exclusiva de compras**: ahora
encadena `bot_rem_media` y `bot_com_media` con `COALESCE`, y cada una
devuelve NULL si el chat no está en su flujo.

---

## 4. Integraciones

- **Worker**: tarea nueva `alertas_remisiones`. Verificado en el arranque:
  el worker la lista entre sus manejadores.
- **n8n**: workflow nuevo `chasquipetRemis` a las 8:00 —cuando la clínica
  abre y puede llamar al laboratorio—. Importado y activo; los seis
  workflows quedaron publicados.
- **Bot**: módulo `bot_rem_*`, comando `/remisiones`, y la foto de la hoja
  del laboratorio entrando por `bot_modulo_media`.
- **Portal**: ruta `/remisiones`, protegida por el layout y por
  `exigirPermiso('remision.ver')`.
- **Avisos (Fase 5)**: se reutiliza `enviar_aviso_dueno` sin tocarlo.

---

## 5. Pruebas ejecutadas

`bash scripts/pruebas.sh` — **12 archivos, todos en verde (242 pruebas).**

| # | Prueba | Esperado | Obtenido | PASS/FAIL |
|---|---|---|---|---|
| 1–4 | Las cuatro funciones sin permisos | SQLSTATE 42501, antes de mirar datos | igual | PASS |
| 5 | Registrar una remisión | `ok:true` | igual | PASS |
| 6 | Estado inicial | `pendiente` | igual | PASS |
| 7 | Fecha esperada | Hoy + 5 por configuración | igual | PASS |
| 8 | Dueño | Sale de la mascota, no se digita | igual | PASS |
| 9 | Auditoría | Evento `remision/crear` | igual | PASS |
| 10 | Sin destino | `sin_destino` | igual | PASS |
| 11 | Sin exámenes | `sin_examenes` | igual | PASS |
| 12 | Sin mascota | `sin_paciente` | igual | PASS |
| 13 | Mascota inexistente | `paciente_inexistente`, sin excepción | igual | PASS |
| 14 | Tipo inventado | `tipo_invalido` | igual | PASS |
| 15 | Lista de pendientes | La remisión aparece | igual | PASS |
| 16 | Cargar resultado | `ok:true` | igual | PASS |
| 17 | Estado tras el resultado | `recibida` | igual | PASS |
| 18 | Aviso al dueño | `aviso_dueno: true` | igual | PASS |
| 19 | Asincronía | El aviso queda en `tarea_async` | igual | PASS |
| 20 | Lo recibido sale de pendientes | 0 | igual | PASS |
| 21 | Resultado corregido | Se suma, no reemplaza (2 resultados) | igual | PASS |
| 22 | **No se avisa dos veces** | El segundo no manda mensaje | igual | PASS |
| 23 | **Append-only** | La app no tiene UPDATE ni DELETE | 0 privilegios | PASS |
| 24 | Anular una recibida | `remision_recibida` | igual | PASS |
| 25 | Alerta | Una vencida la enciende | igual | PASS |
| 26 | Lista de vencidas | 1 | igual | PASS |
| 27 | Texto de la alerta | Lo arma la base, con lo que se pidió | igual | PASS |
| 28 | Anular una pendiente | `ok:true` | igual | PASS |
| 29 | **Idempotencia** | Anular dos veces → `ya_estaba` | igual | PASS |
| 30 | Alerta tras anular | Se apaga | igual | PASS |
| 31 | **C6.9** | El asistente propone y pide confirmación | igual | PASS |
| 32 | Y no registra nada | Conteo intacto | igual | PASS |
| 33 | Al confirmar | Se registra con lo que decía la tarjeta | igual | PASS |
| 34 | Regresión | Los 11 archivos previos siguen en verde | 209 pruebas ✔ | PASS |

**Web:** `tsc --noEmit` PASS; `next build` PASS; `/remisiones` sin sesión
responde 307 a `/entrar`; `/health` 200.

**Worker:** `node --check` sobre la tarea nueva PASS; el contenedor
arranca listando `alertas_remisiones` entre sus manejadores.

**Base de trabajo** (tras `scripts/migrar.sh`, en una transacción con
`ROLLBACK`):

| Prueba | Resultado |
|---|---|
| `verificar_registro_operaciones()` | `ok: true` con las dos herramientas nuevas |
| `bot_texto_ayuda` incluye `/remisiones` | sí |
| `hay_alertas_remisiones()` | `false` (no hay remisiones todavía) |
| `has_table_privilege('chasquipet_app','resultado_remision','UPDATE')` | `false` |
| `scripts/importar-n8n.sh` | los 6 workflows publicados |

---

## 6. Decisiones tomadas

1. **Los resultados son append-only.** Un resultado de laboratorio es
   registro clínico: no se edita ni se borra. Si llega uno corregido, se
   carga otro y quedan los dos con su fecha y su autor. Misma decisión que
   `pago`, `movimiento_inventario` y la consulta firmada, y se aplica con
   el mismo mecanismo (revocar el privilegio, no confiar en el código).
2. **`consulta.remision_externa` no se migra ni se toca.** Es la nota
   clínica del veterinario dentro de una consulta que, firmada, es
   inmutable. Migrarla habría requerido reescribir historia clínica; la
   remisión vive al lado y se enlaza por `consulta_id`.
3. **Sin catálogo de laboratorios.** El alcance de la fase es la remisión
   y su resultado. `destino` es texto; el día que la clínica quiera
   contactos y horarios, será una tabla con su razón de existir.
4. **Al dueño se le avisa una sola vez**, con sello `aviso_dueno_at`. La
   segunda hoja del laboratorio no le manda un segundo mensaje.
5. **La alerta solo suena si hay vencidas.** Una remisión dentro de plazo
   es el curso normal de las cosas; avisarla cada mañana conseguiría que
   dejaran de leerse las alertas —el mismo razonamiento escrito en
   `045:759` para el inventario—.
6. **Un workflow propio a las 8:00** en vez de un nodo en el job de
   inventario (7:30). El repositorio tiene un workflow por dominio
   (turnos, inventario, mantenimiento, agenda) y meter remisiones dentro
   de «Inventario diario» habría dejado el nombre mintiendo. Las 8:00
   porque es cuando la clínica abre y puede llamar al laboratorio.
7. **No se anula lo que ya volvió.** Si el resultado llegó, la remisión
   cumplió; anularla borraría el sentido del registro.
8. **La foto de la hoja entra por el bot, no por el portal.** El portal
   acepta texto y un enlace; subir archivos exige almacenamiento, y el
   sistema no tiene ninguno hoy. Telegram ya guarda el archivo y devuelve
   un `file_id`, que es exactamente lo que hace la factura de una entrada
   de inventario desde `070`.

---

## 7. Incertidumbres restantes

- **El adjunto vive en Telegram.** `adjunto_file_id` sirve para reenviar
  el archivo por el bot, pero el portal no puede mostrarlo: no hay
  almacenamiento propio ni proxy de descarga. La columna `adjunto_url`
  queda lista para el día que lo haya; mientras tanto, desde el portal se
  pega un enlace externo.
- **La ventana de «cerradas hace poco»** en el portal son 30 días, fijos
  en la consulta. No hay historial completo de remisiones por paciente en
  la interfaz; los datos están y la ficha del paciente sería su sitio
  natural.
- **`remisiones_pendientes` filtra por sede** con
  `COALESCE(sede_id, sede_actual)`, igual que los controles de B2.
- **Nada enlaza todavía la remisión con la nota `remision_externa`** de la
  consulta cuando la remisión se crea sin `consulta_id`. Es información
  duplicada por diseño, no un error, pero conviene saberlo antes de
  construir reportes encima.

---

## 8. Riesgos y problemas encontrados

- **`bot_modulo_media` pasó de tener un dueño a tener dos.** Ahora
  `bot_rem_media` va primero y `bot_com_media` después. Ambas devuelven
  NULL si el chat no está en su flujo, así que no se pisan; pero es el
  primer sitio del bot donde dos módulos compiten por el mismo tipo de
  mensaje, y quien agregue un tercero tiene que respetar la misma
  disciplina.
- **La alerta se entrega a todos los que tengan `remision.gestionar`**,
  que son cinco roles. En una clínica con mucho personal puede ser
  demasiada gente recibiendo el mismo mensaje; si molesta, se ajusta
  repartiendo el permiso, que es dato en la base (§4).
- **El adjunto no se valida.** Se guarda el `file_id` que mande Telegram,
  sea una radiografía o una foto del almuerzo. Es el mismo compromiso que
  ya existía para la factura de una entrada.
- **`remision` no tiene restricción de unicidad**: nada impide registrar
  dos veces la misma remisión. Se descartó una reja artificial (¿mismo
  paciente, mismo destino, mismo día?) porque mandar dos exámenes
  distintos al mismo laboratorio el mismo día es normal.

---

## 9. Desviaciones respecto al plan

- El plan mencionaba «catálogo de exámenes» y «laboratorio destino» al
  describir lo que faltaba; en el alcance solo pedía las tablas `remision`
  y `resultado`. Se entregaron esas dos, con `destino` y `examenes` como
  texto. Un catálogo de exámenes estandarizados es una decisión de
  producto que nadie ha pedido todavía (decisión 3).
- El plan pedía «herramienta del asistente para registrar remisión y
  consultar pendientes»: son las dos entregadas.

---

## 10. Trabajo pendiente

1. **Fase B4 — plan multi-tarea con confirmación mixta**, que ya tiene sus
   dependencias listas (A3, A5 y los módulos B1–B3 que orquestar).
2. **Historial de remisiones en la ficha del paciente**: los datos están,
   falta la vista.
3. **Almacenamiento propio de adjuntos**, si se quiere ver la hoja del
   laboratorio desde el portal y no solo desde el chat.
