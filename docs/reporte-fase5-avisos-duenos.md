# Reporte — Fase 5: Avisos y recordatorios a dueños

**Tarea StrictContext:** `asistente-f5-avisos-duenos`
**Estado:** `COMPLETED`
**Fecha de verificación:** 2026-08-11 (BD viva `chasquipet-db`)


> Nota (12-ago-2026): las menciones a `docs/plan_complementacion_asistente_chasqui.md`
> son históricas. Ese plan está archivado en `docs/archivo/`; la hoja de ruta vigente es
> `docs/plan-consolidacion-chasqui-pet.md`.

## Resumen

La Fase 5 del plan de complementación del asistente quedó implementada y verificada:

- Herramienta `preparar_aviso_dueno` (`avisos.enviar`, `escribe=true`, `critica=false`) registrada en `ia_herramienta`.
- `ia_aviso_dueno_borrador`: re-exige `avisos.enviar`, valida que el dueño exista, que el mensaje no esté vacío ni exceda 3000 caracteres y que **consienta recibir mensajes por Telegram y tenga chat vinculado** (§12, Ley 1581 de 2012); arma la tarjeta de vista previa con el aviso y deja la propuesta en `ia_accion_pendiente`. Nunca envía nada por sí mismo.
- Confirmación estándar (`ia:ok`) → `ia_aviso_dueno_ejecutar`: vuelve a exigir el permiso y **revalida el consentimiento en el momento de enviar** (pudo retirarse después del borrador); si todo sigue en regla, encola la tarea `enviar_aviso_dueno` en `tarea_async` y audita. El envío real es asíncrono (worker), nunca dentro del callback.
- `enviar_aviso_dueno.js` (worker): tercer cierre de protección — si el dueño ya no consiente o no tiene chat en el momento del envío, la tarea se completa **sin mandar nada** (caso normal, no error, sin reintentos).
- Tres capas de validación de consentimiento: borrador, confirmación (ejecutar) y worker.

## Archivos modificados

| Archivo | Cambio |
|---|---|
| `db/migrations/083_chasqui_ia_aviso_dueno.sql` | Nueva migración de la Fase 5: permiso `avisos.enviar` + concesiones a roles, `ia_aviso_dueno_borrador`, `ia_aviso_dueno_ejecutar`, registro de la herramienta, enganches `ia_llamar` / `ia_escribir` / `ia_texto_resultado` / `bot_ia_bienvenida` (CREATE OR REPLACE) y GRANT lectura de `ia_herramienta`. |
| `worker/src/tareas/enviar_aviso_dueno.js` | Nuevo manejador de tarea `enviar_aviso_dueno` (envío por Telegram con nombres de clínica y mensaje escapados). |
| `worker/src/tareas/index.js` | Registro del nuevo manejador en `MODULOS`. |
| `docs/plan_complementacion_asistente_chasqui.md` | Marca la Fase 5 como completada. |

Sin cambios de bot, Portal ni n8n: el flujo es bot + SQL + worker existentes (`chasqui_responder` llama `ia_llamar`, muestra la tarjeta y el callback `ia:ok` dispara `ia_confirmar` → `ia_escribir` → ejecutor).

## Base de datos

- **Tablas**: ninguna nueva. Se reutilizan `ia_herramienta`, `ia_accion_pendiente`, `dueno`, `sede`, `tarea_async`, `evento_auditoria`.
- **Permiso nuevo**: `avisos.enviar` (módulo `avisos`), concedido a `superadmin`, `admin`, `auxiliar` y `recepcion`. **No** se concedió a `veterinario`: es quien más habla con el dueño, la exclusión es deliberada para probar el rechazo por permiso.
- **Funciones nuevas**: `ia_aviso_dueno_borrador(uuid, bigint, uuid, jsonb)`, `ia_aviso_dueno_ejecutar(uuid, jsonb)`.
- **Funciones reemplazadas (enganches)**: `ia_llamar` (nuevo caso → borrador), `ia_escribir` (nuevo `WHEN` → ejecutor vía `ia_aviso_dueno_ejecutar`), `ia_texto_resultado` (nuevo texto de resultado), `bot_ia_bienvenida` (nuevo ejemplo con `preparar_aviso_dueno`). Verificadas byte a byte (normalizadas) contra las versiones previas: idénticas salvo las adiciones previstas.
- **Encolamiento**: `encolar_tarea('enviar_aviso_dueno', {dueno_id, mensaje}, prioridad 5, clave 'aviso_dueno_<dueno>_<md5(mensaje)>', retraso 0, intentos máx 5)`. La clave de unicidad impide dos avisos idénticos del mismo dueño pendientes a la vez.
- **Auditoría**: la confirmación audita `ia_accion_pendiente/confirmar`; el envío encolado audita `dueno/<id>/avisar` con el `usuario_id` que confirmó.
- **Idempotencia**: confirmación protegida por `FOR UPDATE` + estado `pendiente` (doble toque rechazado: "Esa confirmación ya no está disponible.") y revalidación de consentimiento en el momento del envío.

## Integraciones

- **Worker**: `worker/src/tareas/enviar_aviso_dueno.js` registrado en `index.js` (log de arranque: `…, enviar_aviso_dueno, …`). Construido y reiniciado con `docker compose build worker && docker compose up -d worker`.
- **Telegram (bot):** sin cambios: la tarjeta la arma `bot_ia_tarjeta_confirmacion` (genérico, `[✅ Sí, hazlo]`/`[✖️ No]`) y el callback `ia:ok`/`ia:no` del `bot_ia_callback` existente; el mensaje se deriva del payload y del aviso aprobado.
- **n8n / Portal web:** sin cambios.

## Pruebas ejecutadas

Ejecutadas en BD viva (`chasquipet-db`) con los datos demo. Las trazas se limpiaron al final (propuestas, tareas y dos pruebas de consentimiento que mutaron temporalmente a María Fernanda). Los `telegram_chat_id` de la demo (900100066+) son ficticios: la última milla contra Telegram real devuelve `chat not found`, lo que confirma que la tarea se ejecuta hasta el punto de envío.

| # | Prueba | Resultado esperado | Resultado obtenido | PASS/FAIL |
|---|---|---|---|---|
| 1 | Catálogo de herramientas | `preparar_aviso_dueno` con `avisos.enviar`, escribe, critica | INSERT OK; `escribe=true`, `critica=false`, orden 290 | PASS |
| 2 | Permiso por rol | `avisos.enviar` en los 4 roles previstos | `superadmin`, `admin`, `auxiliar`, `recepcion` | PASS |
| 3 | Sin permiso (Camilo, veterinario) | Rechazo con `exigir_permiso` | `No tienes permiso para esta acción (avisos.enviar)` | PASS |
| 4 | Borrador exitoso (Yuly, auxiliar) | Vista previa con dueño, mascotas y aviso, sin enviar | `{"ok":true,"requiere_confirmacion":true,"accion_id":…}` con resumen 📨 | PASS |
| 5 | Dueño sin consentimiento | Rechazo Ley 1581 | `«…no autorizó recibir mensajes o no tiene chat…protegido por la Ley 1581»` | PASS |
| 6 | Dueño con consentimiento pero sin chat | Rechazo Ley 1581 | mismo rechazo (Luis Alberto Mendoza) | PASS |
| 7 | Mensaje vacío o > 3000 chars | Rechazo amable | `«El aviso está vacío o es demasiado largo (máx. 3000)»` | PASS |
| 8 | `ia_llamar` enrutado | Llama al borrador vía modelo | Devuelve propuesta `preparar_aviso_dueno` | PASS |
| 9 | Tarjeta de confirmación | Texto + botones `ia:ok`/`ia:no` | Devuelve `texto` con «¿Lo hago?» y 2 filas de botones | PASS |
| 10 | Confirmación (ejecutar) | Encola tarea y audita | `tarea 523` en `tarea_async`; evento `dueno/…/avisar` con usuario | PASS |
| 11 | Worker procesa el aviso | Ejecuta la tarea | `tarea 523 → completada` (900 ms), `{"enviado":false,"motivo":"chat_invalido"}` (chat demo ficticio) | PASS |
| 12 | Doble confirmación | Segunda rechazada | `{"ok":false,"mensaje":"Esa confirmación ya no está disponible."}` | PASS |
| 13 | Consentimiento retirado tras el borrador | Confirmación bloquea el envío | `{"ok":false,"mensaje":"El dueño ya no autoriza…: no se envió nada."}`; 0 tareas creadas | PASS |
| 14 | Capa 3 (worker): tarea directa, dueño sin chat | Completa sin reintentos, no envía | `{"motivo":"sin_chat_id","enviado":false}` | PASS |
| 15 | Capa 3 (worker): tarea directa, dueño sin consentimiento | Completa sin reintentos, no envía | `{"motivo":"sin_consentimiento","enviado":false}` | PASS |
| 16 | Regresión F1–F4: `ia_llamar` lectura | `ver_tarifas` sigue funcionando | `ok:true` con tarifas | PASS |

Nota: la prueba 16 confirma que el enganche `ia_llamar` reescrito no regresiona los flujos existentes (diferencia verificada solo aditiva).

## Incertidumbres

Ninguna **BLOCKER**. Observaciones:

- **Última milla Telegram no probada en vivo**: los `telegram_chat_id` demo (900100066–) no existen en Telegram, así que el envío real termina en `chat not found`. El flujo, el enrutado, la tarjeta, la confirmación y el worker están probados; falta un chat real con consentimiento para ver el mensaje 📨 llegar.
- **Expiración de propuestas**: expiran a los 10 minutos (`expira_at`, igual que el resto del asistente).
- **La clave de unicidad** deriva del `md5` del mensaje: un aviso idéntico al mismo dueño que siga pendiente no se vuelve a encolar.

## Riesgos

- **Aplicación de la migración 083 pendiente en otros ambientes**: aplicada y probada solo en `chasquipet-db`; falta aplicarla en `chasqui-tunjosoft-*` y `chasqui-assistant-*` (deploy de migraciones de cada compose). La migración es idempotente (CREATE OR REPLACE + ON CONFLICT + GRANT).
- **Orden de migraciones**: 083 debe aplicarse después de 079, 081 y 082 (sus enganches sobrescriben versiones previas).
- **Worker desactualizado en otros ambientes**: el manejador `enviar_aviso_dueno` requiere reconstruir la imagen del worker; un worker viejo simplemente no conocería el tipo y se reintenta hasta fallar.

## Dependencias

- BD demo con migraciones 078, 079, 081, 082 y 083 aplicadas, y el worker reconstruido con `enviar_aviso_dueno` registrado.
- Para el camino de punta a punta con Telegram real: bot con webhook activo, `DEEPSEEK_API_KEY` configurada, un chat con el flujo `ia` activo y un dueño con `consentimiento_datos=true` y `telegram_chat_id` real.

## Estado

`COMPLETED` — cumplidos los 4 `acceptance_criteria` de la tarea StrictContext (herramienta registrada; notificaciones externas vía `tarea_async`; vista previa y confirmación; validación del consentimiento para protección de datos en tres capas).