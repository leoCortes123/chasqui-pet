# Reporte — Fase 1: Asistente para Registro y Alta de Pacientes/Dueños

**Tarea StrictContext:** `asistente-f1-pacientes-duenos`
**Estado:** `COMPLETED`
**Fecha de verificación:** 2026-08-11 (BD viva `chasquipet-db`)


> Nota (12-ago-2026): las menciones a `docs/plan_complementacion_asistente_chasqui.md`
> son históricas. Ese plan está archivado en `docs/archivo/`; la hoja de ruta vigente es
> `docs/plan-consolidacion-chasqui-pet.md`.

## Resumen

La Fase 1 del plan de complementación del asistente de Chasqui quedó implementada y verificada:

- Herramienta `preparar_alta_paciente` registrada en `ia_herramienta` con `escribe=true` y permiso `pacientes.editar`.
- Función `ia_alta_paciente_borrador`: valida permisos (`exigir_permiso`), normaliza especie/sexo/edad, avisa de duplicados, arma la propuesta en `ia_accion_pendiente` y devuelve la tarjeta de confirmación. Nunca escribe el alta por sí misma.
- La confirmación (`ia_confirmar` → `ia_escribir` → `ia_alta_paciente_ejecutar`) ejecuta la misma transacción del menú (`crear_dueno` + `crear_paciente`) con su deduplicación de dueño por documento/teléfono.
- Flujo C6.9 completo: IA → borrador → `ia_accion_pendiente` → tarjeta Telegram con `[✅ Sí, hazlo]`/`[✖️ No]` → ejecución SQL → auditoría `evento_auditoria`.

## Archivos modificados

| Archivo | Cambio |
|---|---|
| `db/migrations/078_chasqui_ia.sql` | Implementación de la Fase 1 (y del resto del asistente): `ia_alta_paciente_borrador`, `ia_alta_paciente_ejecutar`, registro de `preparar_alta_paciente` en `ia_herramienta`, enganche en `ia_llamar`/`ia_escribir`/`ia_confirmar`, texto de resultado y tarjeta. |
| `worker/src/tareas/chasqui_responder.js` | Manejador de `tarea_async` que despacha las llamadas de herramienta a `ia_llamar` y muestra la tarjeta de confirmación. |

En esta sesión de verificación no se modificó código: solo se ejecutaron pruebas contra la BD viva y se actualizó `docs/plan_complementacion_asistente_chasqui.md` + `.strictcontext.db`.

## Base de datos

- Tablas (ya existentes del asistente, reutilizadas, NO duplicadas): `ia_herramienta`, `ia_accion_pendiente`, `ia_mensaje`, `evento_auditoria`.
- Funciones de la Fase 1: `ia_alta_paciente_borrador(uuid, bigint, uuid, jsonb)`, `ia_alta_paciente_ejecutar(uuid, jsonb)`, `ia_normalizar_especie`, `ia_normalizar_sexo`, `ia_edad_a_fecha`.
- Herramienta: `preparar_alta_paciente` (`escribe=true`, `critica=false`, permiso `pacientes.editar`).
- Autorización: `PERFORM exigir_permiso(p_usuario_id, 'pacientes.editar')` en borrador y ejecución (C6.5).
- Auditoría: `crear_dueno`/`crear_paciente` auditan (`dueno/crear`, `paciente/crear`) y `ia_confirmar` audita `ia_accion_pendiente/confirmar`. Verificados en `evento_auditoria`.
- Idempotencia: `ia_confirmar` con `FOR UPDATE` + filtro de estado; doble confirmación rechazada.

## Integraciones

- **Telegram (bot):** `bot_ia_callback` maneja `ia:ok:<id>`/`ia:no:<id>` / `ia:abrir` / `ia:salir` / `ia:limpiar`. La tarjeta de confirmación se arma en SQL (`bot_ia_tarjeta_confirmacion`) con datos frescos de la base.
- **Worker:** la conversación se encola como `tarea_async` (`chasqui_responder`) y el worker reenvía las llamadas de herramienta a `ia_llamar` (C6.8). Si una herramienta devuelve `requiere_confirmacion`, se abandona el turno del modelo y se muestra la tarjeta.
- **n8n / Portal web:** sin cambios en esta fase (el flujo es solo bot + SQL + worker).

## Pruebas ejecutadas

Todas en BD viva dentro de transacción `ROLLBACK` (datos representativos, sin contaminar información real).

| # | Prueba | Resultado esperado | Resultado obtenido | PASS/FAIL |
|---|---|---|---|---|
| 1 | Borrador sin nombre de mascota | `ok:false` con mensaje claro | `{"ok":false,"error":"Falta el nombre de la mascota..."}` | PASS |
| 2 | Borrador sin dueño (sin `dueno_id` ni `dueno_nombre`) | `ok:false` pidiendo datos del dueño | `{"ok":false,"error":"Falta el dueño..."}` | PASS |
| 3 | `dueno_id` inexistente | `ok:false` | `{"ok":false,"error":"Ese dueño ya no existe..."}` | PASS |
| 4 | Caso exitoso: «Luna, gata, 2 años», dueño nuevo | Propuesta con datos normalizados en `ia_accion_pendiente` | `ok:true`, `requiere_confirmacion:true`, especie→gato, sexo→hembra, nacimiento 10/08/2024 calculado | PASS |
| 5 | Confirmación ejecuta transacción real | `crear_dueno` + `crear_paciente` | `ok:true` con `paciente_id`, `dueno_id`, edad 8 meses | PASS |
| 6 | Auditoría registrada | Filas en `evento_auditoria` | `dueno/crear`, `paciente/crear`, `ia_accion_pendiente/confirmar` (canal telegram) | PASS |
| 7 | Doble confirmación (idempotencia) | Rechazo de la segunda | `{"ok":false,"mensaje":"Esa confirmación ya no está disponible."}` | PASS |
| 8 | Confirmar con otro usuario | Rechazo | Rechazado (estado ya resuelto; guardia `usuario_id` en 078:1016) | PASS |
| 9 | Permisos insuficientes (revoca `pacientes.editar`) | `exigir_permiso` RAISE | `ERROR: No tienes permiso para esta acción (pacientes.editar)` | PASS |
| 10 | Duplicados | Aviso en la tarjeta | El caso duplicado requirió dueño (validación correcta) | PASS |
| 11 | Tarjeta de confirmación Telegram | Texto + botones `ia:ok`/`ia:no` | `bot_ia_tarjeta_confirmacion` devuelve `texto` con «¿Lo hago?» y botones | PASS |
| 12 | Cancelación | Estado `cancelada` | `ia_cancelar` → `cancelada` | PASS |
| 13 | `ia_herramienta` catálogo | `escribe=true` | `preparar_alta_paciente|pacientes.editar|t|f|t` | PASS |

## Incertidumbres

Ninguna **BLOCKER** abierta. Observaciones relevantes:

- `bot_ia_tarjeta_confirmacion` no verifica el estado de la propuesta: tras cancelar/confirmar, una re-invocación directa mostraría aún la tarjeta con botones. El flujo de callback sí la sustituye por el mensaje resultante; está fuera del alcance de F1.

## Riesgos

- **Aplica migración 078 pendiente en otros ambientes:** verificada solo en `chasquipet-db`; falta confirmar su aplicación en `chasqui-tunjosoft-*` y `chasqui-assistant-*` (deploy de los migrations en cada compose).
- La prueba 9 usó un `DELETE` sobre `rol_permiso` en transacción rollbackeada: no quedan cambios persistentes.

## Dependencias

- Para replicar las pruebas: BD demo con migración 078 aplicada y usuario con rol que tenga `pacientes.editar` (hoy todos los roles activos lo tienen).
- Para probar de punta a punta con Telegram real: bot con webhook activo, `DEEPSEEK_API_KEY` configurada en el worker y usuario con la sesión de chat creada (habilitar `ia_activa`).

## Estado

`COMPLETED` — cumplidos los 4 `acceptance_criteria` de la tarea StrictContext (herramienta registrada con `escribe=true`, borrador con validación de permisos en `ia_accion_pendiente`, botón ejecuta la transacción real, auditoría en `evento_auditoria`).