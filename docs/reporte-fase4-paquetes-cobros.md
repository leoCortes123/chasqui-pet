# Reporte — Fase 4: Asistente para Cargar Paquetes de Servicios y Cobros

**Tarea StrictContext:** `asistente-f4-paquetes-cobros`
**Estado:** `COMPLETED`
**Fecha de verificación:** 2026-08-10 (BD viva `chasquipet-db`)


> Nota (12-ago-2026): las menciones a `docs/plan_complementacion_asistente_chasqui.md`
> son históricas. Ese plan está archivado en `docs/archivo/`; la hoja de ruta vigente es
> `docs/plan-consolidacion-chasqui-pet.md`.

## Resumen

La Fase 4 del plan de complementación del asistente quedó implementada y verificada:

- Herramienta `cargar_paquete_servicios` (`cobro.linea`, `escribe=true`, `critica=true`) y `aplicar_descuento_asistido` (`cobro.descuento`, `escribe=true`, `critica=true`) registradas en `ia_herramienta`.
- `ia_cargar_paquete_borrador`: re-exige `cobro.linea`, normaliza cada servicio (por `tarifa_id` o por nombre tolerante vía `ia_buscar_tarifa`), admite servicios de valor libre, arma la tarjeta de pre-factura con **subtotal, descuento (si va) y total por separado**, y deja la propuesta en `ia_accion_pendiente`. Nunca escribe la cuenta.
- `ia_paquete_ejecutar`: disparada por la confirmación (C6.9). Bloquea la cuenta (`FOR UPDATE`), escribe cada servicio con `agregar_linea_servicio` (misma auditoría y append-only del menú) y aplica el descuento con `aplicar_descuento`. Si algo no se puede escribir, no queda NADA (una sola transacción).
- `ia_aplicar_descuento_borrador` / `ia_descuento_ejecutar`: descuento asistido sobre una cuenta abierta, con motivo escrito obligatorio y permiso `cobro.descuento` exigido con `exigir_permiso` (C6.5). Soporta monto o porcentaje (`ia_parse_descuento`).
- `ia_cobrar_cerrar` + `ia_confirmar_cobrar`: el botón **«💳 Cobrar y cerrar»** de la pre-factura confirma la propuesta, registra el pago del saldo (`registrar_pago`) y cierra la cuenta (`cerrar_cuenta`) en un solo toque y una sola transacción. El botón solo se muestra si quien confirma tiene `cobro.pago`; la ejecución vuelve a exigirlo **antes de escribir** (sin efecto parcial).

## Archivos modificados

| Archivo | Cambio |
|---|---|
| `db/migrations/082_chasqui_ia_cobro.sql` | Nueva migración de la Fase 4: `ia_buscar_tarifa`, `ia_parse_descuento`, borradores y ejecutores de paquete y descuento, `ia_cobrar_cerrar`, `ia_confirmar_cobrar`, y enganches `ia_llamar` / `ia_escribir` / `ia_texto_resultado` / `bot_ia_bienvenida` / `bot_ia_tarjeta_confirmacion` / `bot_ia_callback` (CREATE OR REPLACE). |
| `docs/plan_complementacion_asistente_chasqui.md` | Marca la Fase 4 como completada. |
| `.strictcontext.db` | Tarea `asistente-f4-paquetes-cobros` actualizada. |

No se modificó worker, bot, Portal ni n8n: el flujo es solo bot + SQL + worker existentes (`chasqui_responder` llama `ia_llamar`; el callback `ia:cobrar` dispara `ia_confirmar_cobrar`).

## Base de datos

- **Tablas**: ninguna nueva. Se reutilizan `ia_herramienta`, `ia_accion_pendiente`, `cuenta`, `cuenta_linea`, `descuento`, `pago`, `tarifa`, `evento_auditoria`.
- **Funciones nuevas**: `ia_buscar_tarifa(text)`, `ia_parse_descuento(text, numeric)`, `ia_cargar_paquete_borrador(uuid, bigint, uuid, jsonb)`, `ia_paquete_ejecutar(uuid, jsonb)`, `ia_aplicar_descuento_borrador(uuid, bigint, uuid, jsonb)`, `ia_descuento_ejecutar(uuid, jsonb)`, `ia_cobrar_cerrar(uuid, uuid, text)`, `ia_confirmar_cobrar(uuid, uuid)`.
- **Funciones reemplazadas (enganches)**: `ia_llamar`, `ia_escribir`, `ia_texto_resultado`, `bot_ia_bienvenida`, `bot_ia_tarjeta_confirmacion`, `bot_ia_callback`. Verificadas byte a byte (normalizadas) contra las versiones previas: idénticas salvo las adiciones previstas.
- **Autorización (C6.5)**: `exigir_permiso` en borradores y ejecutores (`cobro.linea`, `cobro.descuento`, `cobro.pago`); la tarjeta filtra el botón de cobro por `cobro.pago`.
- **Append-only**: se reusan `agregar_linea_servicio`, `aplicar_descuento` y `registrar_pago`, cuyo dinero queda inmutable (`descuento_inmutable`, `pago_inmutable`: solo reverso). Verificado: los pagos/descuentos de prueba no se pueden borrar.
- **Auditoría**: cada línea y descuento audita en `evento_auditoria`; `ia_confirmar_cobrar` audita `ia_accion_pendiente/confirmar_cobrar`.
- **Idempotencia**: `ia_confirmar_cobrar` usa `FOR UPDATE` + estado `pendiente` (doble toque rechazado) y el mismo criterio de expiración que `ia_confirmar`.
- **Atomicidad**: paquete, descuento y cobro+cierre son una sola transacción; se aborta todo si una pieza falla (ERRCODE 23514).

## Integraciones

- **Telegram (bot):** sin cambios de código del bot: la tarjeta la arma `bot_ia_tarjeta_confirmacion` (ahora con `[✅ Sí, hazlo]`/`[💳 Cobrar y cerrar]`/`[✖️ No]` cuando aplica) y el callback `ia:ok`/`ia:no`/`ia:cobrar` del `bot_ia_callback` existente. El texto posterior a cobrar incluye el recibo (`recibo_texto`).
- **Worker:** sin cambios: `chasqui_responder` reenvía la llamada a `ia_llamar`, muestra la tarjeta y no ejecuta.
- **n8n / Portal web:** sin cambios.

## Pruebas ejecutadas

Ejecutadas en BD viva (`chasquipet-db`) con cuentas de prueba dedicadas. Como las finanzas son append-only por diseño, los resultados no se revierten: las tres cuentas de prueba se cerraron con pago legítimo (recibos 61–63) y el turno y las acciones pendientes de prueba se limpiaron.

| # | Prueba | Resultado esperado | Resultado obtenido | PASS/FAIL |
|---|---|---|---|---|
| 1 | Catálogo de herramientas | `cobro.linea`/`cobro.descuento`, escribe, critica | `INSERT 0 2` con ON CONFLICT; `escribe=true`, `critica=true`, ordenadas | PASS |
| 2 | Paquete multi-servicio (nombres tolerantes) | Pre-factura con subtotal/total, `accion_id`, sin escribir | «Consulta general = $60.000», «Aplicación de vacuna × 2 = $50.000», Subtotal $110.000 | PASS |
| 3 | Servicio de valor libre con valor explícito | Pre-factura usa el valor pasado | «Desparasitación = $15.000» (tarifa libre) | PASS |
| 4 | Descuento sin permiso (Camilo) | Rechazo con `exigir_permiso` | `No tienes permiso para esta acción (cobro.descuento)` | PASS |
| 5 | Descuento % (Leonardo, `cobro.descuento`) | Descuento sobre base, motivo obligatorio | 10 % de $110.000 = −$11.000, Total $99.000 | PASS |
| 6 | Tarjeta de confirmación sin permiso de pago | Solo `[✅ Sí, hazlo]`/`[✖️ No]` | `bot_ia_tarjeta_confirmacion` devuelve 2 filas de botones | PASS |
| 7 | Tarjeta con permiso de pago (Yuly/Leonardo) | Suma `[💳 Cobrar y cerrar]` | 3 filas: `ia:ok`, `ia:cobrar`, `ia:no` | PASS |
| 8 | `ia_paquete_ejecutar` (confirmación) | Líneas escritas, subtotal correcto | 2 líneas, subtotal $110.000, `ok:true` | PASS |
| 9 | `ia_confirmar_cobrar` (pago+cierre atómicos) | Escribe, cobra saldo, cierra, recibo, caja | Recibo 61: total $75.000, pagado $75.000, estado `cerrada`, `cierre_caja_id` | PASS |
| 10 | Paquete + descuento + cobrar en un toque | Subtotal, descuento y total correctos y cerrados | Subtotal $130.000 − $5.000 = $125.000, pagado, recibo 62 | PASS |
| 11 | Sin `cobro.pago` en `ia:confirmar_cobrar` | Rechazo **sin** escribir líneas | `{"ok":false,"mensaje":"No tienes permiso para cobrar."}`, líneas sin cambio (2→2) | PASS |
| 12 | `recibo_texto` tras cobrar | Recibo legible con desglose | Recibo N.° 61 con líneas, total y forma de pago | PASS |
| 13 | Regresión F1/F2/F3: `ia_llamar` lectura | `ver_tarifas` sigue funcionando | `ok:true` con 8 tarifas | PASS |
| 14 | Regresión camino genérico de escritura | `crear_turno` borrador + confirmación | `accion_id` creado; `ia_confirmar` creó el turno A-001 | PASS |
| 15 | Borrador con descuento inválido (> base) | Rechazo amable | «El descuento no puede pasar de …» | PASS |

Nota: las pruebas 13–15 confirman que los enganches reescritos no regresionan los flujos existentes (diferencias verificadas solo aditivas).

## Incertidumbres

Ninguna **BLOCKER**. Observaciones:

- **Pago en efectivo por defecto en el botón `💳`:** `ia_cobrar_cerrar` usa `medio='efectivo'` (el cobro del saldo en un toque no pide medio ni referencia). Si se quiere cobrar por transferencia/datafono, sigue existiendo la confirmación normal + `cobrar_cuenta` con medio. Fuera del alcance de F4.
- **La tarjeta no valida estado** (heredado de F1/F3): una re-invocación directa de `bot_ia_tarjeta_confirmacion` tras resolver mostraría la tarjeta; el flujo de callback la sustituye.
- **Números de recibo usados en pruebas:** 61, 62 y 63 quedan en la secuencia de la sede (gaps normales).

## Riesgos

- **Aplicación de la migración 082 pendiente en otros ambientes**: aplicada y probada solo en `chasquipet-db`; falta aplicarla en `chasqui-tunjosoft-*` y `chasqui-assistant-*` (deploy de migraciones de cada compose). La migración es idempotente (CREATE OR REPLACE + ON CONFLICT).
- **Orden de migraciones**: 082 debe aplicarse después de 079 y 081 (sus enganches sobrescriben versiones previas).
- **Concurrencia sobre la misma cuenta**: dos confirmaciones simultáneas del mismo paquete pueden producir `deadlock`/`serialization`; el handler de `ia_paquete_ejecutar`/`ia_confirmar_cobrar` devuelve un mensaje claro y no escribe nada.

## Dependencias

- BD demo con migraciones 078, 079, 081 y 082 aplicadas, y usuarios con roles que tengan `cobro.linea`, `cobro.descuento` y `cobro.pago` según corresponda.
- Para el camino de punta a punta con Telegram real: bot con webhook activo, `DEEPSEEK_API_KEY` configurada y un chat con el flujo `ia` activo. El worker no requiere cambios.

## Estado

`COMPLETED` — cumplidos los 4 `acceptance_criteria` de la tarea StrictContext (herramientas registradas; permiso de descuento verificado con `exigir_permiso`; tarjeta de pre-factura con subtotal y descuento separado y modelo append-only; botón para proceder al cobro y cerrar la cuenta).
