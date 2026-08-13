# Reporte — Fase 3: Asistente para Despacho Múltiple de Insumos y Recetas

**Tarea StrictContext:** `asistente-f3-despacho-recetas`
**Estado:** `COMPLETED`
**Fecha de verificación:** 2026-08-11 (BD viva `chasquipet-db`)


> Nota (12-ago-2026): las menciones a `docs/plan_complementacion_asistente_chasqui.md`
> son históricas. Ese plan está archivado en `docs/archivo/`; la hoja de ruta vigente es
> `docs/plan-consolidacion-chasqui-pet.md`.

## Resumen

La Fase 3 del plan de complementación del asistente quedó implementada y verificada:

- Herramienta `despachar_receta_multiple` registrada en `ia_herramienta` con `escribe=true`, `critica=true` y permiso `inventario.salida`.
- `ia_despacho_borrador`: re-exige permiso, normaliza la lista de medicamentos (por `medicamento_id` o por nombre tolerante), resuelve FEFO sobre `v_lote_disponible`, arma la tarjeta de desglose (producto · lote · cantidad · precio · total) y deja la propuesta en `ia_accion_pendiente`. Nunca descuenta inventario.
- `ia_despacho_ejecutar`: disparada por la confirmación (C6.9). Bloquea en un solo orden (`FOR UPDATE`) todos los lotes candidatos de todos los medicamentos, re-resuelve FEFO sobre los lotes bloqueados y despacha tramo a tramo rehusando `salida_medicamento` (misma auditoría, mismo encolado de `agregar_linea_cuenta`). Si algo no alcanza, no descuenta NADA (rollback completo).
- `ia_despacho_asignar`: resolución FEFO compartida (STABLE) usada por borrador y ejecución.
- Flujo C6.9 completo: IA → borrador → `ia_accion_pendiente` → tarjeta Telegram con `[✅ Sí, hazlo]`/`[✖️ No]` → ejecución SQL atómica → auditoría `evento_auditoria`.

## Archivos modificados

| Archivo | Cambio |
|---|---|
| `db/migrations/081_chasqui_ia_despacho.sql` | Nueva migración de la Fase 3: herramienta, `ia_despacho_asignar`, `ia_despacho_borrador`, `ia_despacho_ejecutar`, y enganches `ia_llamar` / `ia_escribir` / `ia_texto_resultado` / `bot_ia_bienvenida` (CREATE OR REPLACE). |
| `docs/plan_complementacion_asistente_chasqui.md` | Marca la Fase 3 como completada. |
| `.strictcontext.db` | Tarea `asistente-f3-despacho-recetas` actualizada. |

No se modificó worker, bot, Portal ni n8n: el flujo es solo bot + SQL + worker existentes (`chasqui_responder` llama `ia_llamar`; el callback `ia:ok` dispara `ia_confirmar`).

## Base de datos

- **Tablas**: ninguna nueva. Se reutilizan `ia_herramienta`, `ia_accion_pendiente`, `lote`, `v_lote_disponible`, `movimiento_inventario`, `evento_auditoria`, `tarea_async`.
- **Funciones nuevas**: `ia_despacho_asignar(jsonb)`, `ia_despacho_borrador(uuid, bigint, uuid, jsonb)`, `ia_despacho_ejecutar(uuid, jsonb)`.
- **Funciones reemplazadas (enganches)**: `ia_llamar`, `ia_escribir`, `ia_texto_resultado`, `bot_ia_bienvenida`.
- **Herramienta**: `despachar_receta_multiple` (`inventario.salida`, `escribe=true`, `critica=true`).
- **Autorización (C6.5)**: `PERFORM exigir_permiso(p_usuario_id, 'inventario.salida')` en borrador y ejecución; además la herramienta se filtra por catálogo y `ia_llamar` la vuelve a filtrar.
- **Auditoría**: `salida_medicamento` audita cada tramo (`movimiento_inventario/salida`) y `ia_confirmar` audita `ia_accion_pendiente/confirmar`. Verificadas en `evento_auditoria`.
- **Idempotencia**: la confirmación es el mismo `ia_confirmar` con `FOR UPDATE` + filtro de estado; doble confirmación rechazada.
- **Atomicidad**: la ejecución es atómica (una sola transacción). Maneja `deadlock_detected`/`serialization_failure` con mensaje amable y cero descuentos.

## Integraciones

- **Telegram (bot):** sin cambios de código del bot: la tarjeta la arma `bot_ia_tarjeta_confirmacion` y el callback `ia:ok`/`ia:no` del `bot_ia_callback` existente. El texto posterior usa `ia_texto_resultado` («Despachados 2 medicamento(s) por $13.200.»).
- **Worker:** sin cambios: `chasqui_responder` reenvía la llamada a `ia_llamar`, muestra la tarjeta y no ejecuta; el modelo no vuelve a tomar el turno tras la propuesta (C6.8).
- **n8n / Portal web:** sin cambios.

## Pruebas ejecutadas

Todas en BD viva dentro de transacción `ROLLBACK` (datos representativos, sin contaminar información real).

| # | Prueba | Resultado esperado | Resultado obtenido | PASS/FAIL |
|---|---|---|---|---|
| 1 | Catálogo de la herramienta | `inventario.salida`, escribe, critica, activa | `despachar_receta_multiple\|inventario.salida\|t\|t\|t` | PASS |
| 2 | `ia_despacho_asignar` 2 productos, 2 lotes (FEFO) | Asignación por vencimiento, faltante 0, total correcto | Amox 100 → lote MLX… (venc. más próximo), Melo 25 → MELX-2401; total $207.500 | PASS |
| 3 | Borrador feliz multi-producto vía `ia_llamar` | `ok:true`, propuesta en `ia_accion_pendiente`, tarjeta con desglose | Amox 5 (lote DEMO-AMX-2312) + Enro 3 (DEMO-ENR-2402), total $13.200, `accion_id` | PASS |
| 4 | Tarjeta Telegram | Texto + botones `ia:ok`/`ia:no` | `bot_ia_tarjeta_confirmacion` devuelve texto con «¿Lo hago?» y botones | PASS |
| 5 | Confirmación ejecuta despacho | Descuento correcto, stock decrementado | Amox 5 → quedan 283; Enro 3 → quedan 437; total $13.200 | PASS |
| 6 | Auditoría | Filas en `evento_auditoria` | 2× `movimiento_inventario/salida`, 1× `ia_accion_pendiente/confirmar` (canal telegram) | PASS |
| 7 | Doble confirmación (idempotencia) | Rechazo de la segunda | `{"ok":false,"mensaje":"Esa confirmación ya no está disponible."}` | PASS |
| 8 | Inventario insuficiente en borrador | No propone; mensaje claro | «No alcanza el inventario para: Ivermectina (pide 500 ml y solo hay 201)» | PASS |
| 9 | Rollback: stock cambió entre propuesta y botón | Confirmación falla y NO descuenta nada | «ya no alcanza… faltan 363 ml. No se descontó nada»; solo quedan los 2 movimientos del escenario (T5 + consumo simulado), ninguno del despacho | PASS |
| 10 | Permisos insuficientes (recepcion) | Rechazo en catálogo | `ia_llamar` → `{"ok":false,"error":"El usuario no tiene permiso para esto…"}`; `ia_herramientas()` no incluye la herramienta | PASS |
| 11 | Resolución por nombre tolerante | «amoxi» → Amoxicilina | Borrador `ok:true` con Amoxicilina (Amoxifar) | PASS |
| 12 | Despacho multi-lote FEFO (parcial, 288+12) | Dos movimientos; lote que vence primero agotado primero; justificación FEFO en el 2º | Lote DEMO-AMX-2312: 288 (motivo vacío) · DEMO-AMX-2401: 12, motivo «FEFO: agotado el lote DEMO-AMX-2312»; quedan 0 y 1488 | PASS |
| 13 | Lote vencido/bloqueado excluido | No se ofrece | Vacuna quíntuple: pide 36, solo 35 disponibles (DTO-VQC-2312 vencido/bloqueado fuera de `v_lote_disponible`) | PASS |
| 14 | Lista vacía | `ok:false` | «Falta la lista de medicamentos a despachar…» | PASS |
| 15 | Cantidad ≤ 0 | `ok:false` | «La cantidad … debe ser mayor que cero.» | PASS |
| 16 | Catálogo del modelo filtrado | Solo quien tiene permiso la ve | Camilo (vet) `t`, Jefferson (recepcion) `f` | PASS |
| 17 | Texto posterior a confirmar | Resumen legible | «Despachados 2 medicamento(s) por $13.200.» | PASS |
| 18 | Ejemplo en bienvenida | Muestra el nuevo ejemplo a quien puede despachar | `bot_ia_bienvenida` del vet contiene «· «despacha 2 amoxicilina y 1 metronidazol»» | PASS |

## Incertidumbres

Ninguna **BLOCKER**. Observaciones:

- **Vencimiento del lote sugerido en la tarjeta:** la tarjeta se arma con el estado del instante de la propuesta; si el stock cambia antes del botón, la ejecución re-resuelve y rechaza si no alcanza (probado en la prueba 9). Es el diseño documentado «se falla, no se adivina».
- **`bot_ia_tarjeta_confirmacion` no valida estado** (heredado de F1): una re-invocación directa tras cancelar/confirmar mostraría la tarjeta; el flujo de callback la sustituye. Fuera del alcance de F3.

## Riesgos

- **Aplicación de la migración 081 pendiente en otros ambientes**: aplicada y probada solo en `chasquipet-db`; falta aplicarla en `chasqui-tunjosoft-*` y `chasqui-assistant-*` (deploy de migraciones de cada compose).
- **Migración 079 aún sin commit**: la Fase 2 (`079_chasqui_ia_consulta.sql`) sigue sin seguimiento en git. El enganche `ia_llamar`/`ia_escribir` de 081 sobrescribe las versiones de 079; si 079 se aplicara después en otro ambiente, 081 debe aplicarse después.
- **Concurrencia de despachos sobre el mismo lote**: dos confirmaciones simultáneas del mismo medicamento pueden producir `deadlock`/`serialization`; el handler devuelve un mensaje claro y no descuenta nada (probado el camino de error, no la carrera real).

## Dependencias

- BD demo con migraciones 078, 079 y 081 aplicadas, y usuario con rol que tenga `inventario.salida` (veterinario).
- Para el camino de punta a punta con Telegram real: bot con webhook activo, `DEEPSEEK_API_KEY` configurada y un chat del veterinario con el flujo `ia` activo. El worker no requiere cambios.

## Estado

`COMPLETED` — cumplidos los 4 `acceptance_criteria` de la tarea StrictContext (herramienta procesa lista de medicamentos; selección FEFO por vencimiento más próximo; tarjeta de desglose con cantidades y precios; confirmación explícita con botón antes de descontar inventario, C6.9).