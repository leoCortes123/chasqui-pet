# Reporte — Fase A3: Propuestas huérfanas y purga de `ia_accion_pendiente`

**Plan:** `docs/plan-consolidacion-chasqui-pet.md` → Bloque A, Fase A3
**Estado:** `COMPLETED`
**Fecha de verificación:** 2026-08-12
**Banco de pruebas:** contenedor `postgres:16-alpine` efímero construido desde
`db/migrations/` + `db/demo/`, y el manejador real del worker contra un servidor que imita
la API de DeepSeek. Migración aplicada además a la base de desarrollo.

## 1. Resumen

El defecto: en `worker/src/tareas/chasqui_responder.js` el bucle sobre las tool calls no
cortaba tras la primera propuesta. Si el modelo pedía tres escrituras en un turno, se
insertaban **tres filas** en `ia_accion_pendiente` y el bot mostraba **una sola tarjeta**.
Las otras dos quedaban `pendiente` para siempre: `bot_ia_callback` no las limpia,
`mantenimiento_diario()` no tocaba esa tabla y la expiración de `078:1020-1024` es perezosa
—solo marca `expirada` si alguien toca el botón tarde—. En la base de desarrollo había **9
filas huérfanas** vencidas, la más antigua del 4 de agosto de 2026.

Dos remedios, en el orden que manda el plan:

- **En el origen (worker):** una vez que hay una propuesta en el turno, las siguientes tool
  calls **no llegan a `ia_llamar`**. Se les responde al modelo que hay una acción esperando
  confirmación y que no proponga más. La basura ya no se crea.
- **Como red (base):** `ia_purgar_pendientes()` cierra las vencidas y borra las resueltas
  viejas, enganchada de forma aditiva en `mantenimiento_diario()`.

## 2. Archivos modificados

| Archivo | Cambio |
|---|---|
| `worker/src/tareas/chasqui_responder.js` | Guarda al inicio del bucle de tool calls: si ya hay `pendiente`, se omite la llamada y se devuelve al modelo un resultado explicándolo. `requiere_confirmacion` ya no necesita el `&& !pendiente` (era inalcanzable). Cabecera actualizada. |
| `db/migrations/130_ia_purga.sql` | **Nueva.** Config `retencion_ia_acciones_dias`, `ia_purgar_pendientes()` y `mantenimiento_diario()` reemplazada de forma aditiva. Cabecera `NÚCLEO`. |

## 3. Base de datos

- **Tablas:** ninguna nueva.
- **Config nueva:** `retencion_ia_acciones_dias` = 30, editable desde la UI. Mismo criterio
  que `retencion_tareas_dias`.
- **Función nueva:** `ia_purgar_pendientes() RETURNS jsonb {expiradas, purgadas}`. Dos pasos
  distintos a propósito: (1) las `pendiente` con `expira_at` vencido pasan a `expirada`, no
  se borran; (2) las ya resueltas —confirmadas, canceladas o expiradas— más viejas que la
  retención se borran. **Nunca borra una fila que siga `pendiente` y vigente.**
- **Función reemplazada:** `mantenimiento_diario()`. El cuerpo de `088` va palabra por
  palabra, más la llamada a la purga y dos claves en el resultado
  (`ia_acciones_expiradas`, `ia_acciones_purgadas`).
- **`SECURITY DEFINER` explícito** en la nueva versión: `CREATE OR REPLACE` **no** conserva
  esa propiedad, y `090_grants.sql` la había puesto con un `ALTER` porque la purga borra de
  `telegram_update`, tabla sobre la que la aplicación no tiene DELETE. Omitirla habría roto
  la limpieza diaria en silencio. Verificado con `pg_proc.prosecdef` en las dos bases.
- **Auditoría:** ninguna nueva. Es limpieza de infraestructura; la huella de las
  confirmaciones vive en `evento_auditoria` (`ia_accion_pendiente/<id>/confirmar`, 078) y no
  se toca. Comprobado en la prueba 9.

## 4. Integraciones

- **n8n:** el job `04-job-mantenimiento` llama `SELECT mantenimiento_diario()` y no cambia;
  recibe dos claves más en el JSON de resultado. No hace falta reimportar.
- **Worker:** imagen reconstruida y servicio reiniciado; arranca con sus 12 manejadores.
- **Bot / portal:** sin cambios de contrato.

## 5. Pruebas ejecutadas

| # | Prueba | Esperado | Obtenido | Resultado |
|---|---|---|---|---|
| 1 | **Antes**: 3 escrituras en un turno (copia del archivo sin el arreglo) | Reproduce el defecto | 3 filas `pendiente`, una sola tarjeta | FAIL esperado (defecto confirmado) |
| 2 | **Después**: las mismas 3 escrituras | 1 sola fila | 1 fila; log: `preparar_consulta_clinica → propuesta`, las otras dos `→ omitida (hay una propuesta sin confirmar)` | PASS |
| 3 | Resultado devuelto al modelo por las omitidas | Explica y pide no insistir | «Ya hay una acción esperando la confirmación de la persona. No propongas nada más…» | PASS |
| 4 | No regresión de lecturas | Una lectura antes de la escritura sí se ejecuta | `ver_cola → ok`, luego la propuesta, luego las omitidas | PASS |
| 5 | Purga sin nada que purgar | Ceros, sin error | `{"purgadas": 0, "expiradas": 0}` | PASS |
| 6 | Caso exitoso: vigente + vencida + resuelta hace 60 días | Cierra la vencida, borra la vieja, respeta la vigente | `{"purgadas": 1, "expiradas": 1}`; queda `900001=pendiente`, `900002=expirada`, la vieja borrada | PASS |
| 7 | Idempotencia | Segunda corrida no cambia nada | `{"purgadas": 0, "expiradas": 0}` | PASS |
| 8 | La propuesta vigente sigue siendo confirmable tras la purga | `ok:true` | `ok:true` | PASS |
| 9 | La expirada ya no se confirma | Rechazo | «Esa confirmación ya no está disponible.» | PASS |
| 10 | Auditoría intacta | El evento de la confirmación sigue | 1 evento `ia_accion_pendiente/confirmar` | PASS |
| 11 | Enganche aditivo: regresión de `mantenimiento_diario` | Sigue purgando lo de 088 | `updates_purgados 1`, `challenges_purgados 1`, `tareas_purgadas 1`, `conversaciones_purgadas 1`, `sesiones_vencidas 1`, más las dos claves nuevas | PASS |
| 12 | `SECURITY DEFINER` conservado | La app puede llamarla | `prosecdef = t`; llamada con `SET ROLE chasquipet_app` funciona | PASS |
| 13 | Config sembrada | 30 días | `retencion_ia_acciones_dias=30` | PASS |
| 14 | Instalación limpia con la migración nueva | Arranque completo | 29 migraciones registradas, sin errores | PASS |
| 15 | Aplicación a la base de desarrollo con `scripts/migrar.sh` | Aplica y registra | `130_ia_purga.sql aplicando... ok`; `schema_version` → `130 / migrar` | PASS |
| 16 | Verificación del plan tras A3 | Sin `pendiente` acumuladas | Las 9 huérfanas pasaron a `expirada`; quedan 0 `pendiente` | PASS |
| 17 | `node --check` en todo `worker/src` | Limpio | Sin errores | PASS |

## 6. Decisiones tomadas

- **Se omiten todas las llamadas posteriores, no solo las de escritura.** El plan pedía
  frenar las escrituras. Distinguirlas exigiría que el worker supiera qué herramienta
  escribe —conocimiento que es dato en `ia_herramienta` y que el worker no debe duplicar
  (C6.12)—. Y no cuesta nada: el bucle ya termina en cuanto hay una propuesta
  (`while … && !pendiente`), así que el resultado de una lectura posterior no lo lee nadie.
  Las lecturas **anteriores** a la propuesta siguen ejecutándose (prueba 4).
- **Se le devuelve un resultado a cada llamada omitida**, en vez de saltarla: la API rechaza
  la petición entera si falta el resultado de una tool call.
- **Las vencidas se marcan, no se borran.** Pasan por `expirada` y las barre la retención
  cuando les toque; así queda rastro de que existieron.
- **La purga no audita.** Es limpieza de infraestructura, igual que el resto de
  `mantenimiento_diario()`.

## 7. Riesgos y problemas encontrados

- **`CREATE OR REPLACE` pierde `SECURITY DEFINER`.** No es un problema encontrado en el
  código sino una trampa que casi se activa al reemplazar `mantenimiento_diario()`: si la
  nueva definición no lo declara, la función vuelve a `SECURITY INVOKER` y la limpieza
  diaria falla en silencio al no poder borrar de `telegram_update`. Queda anotado aquí
  porque **aplica a cualquier reemplazo futuro** de `mantenimiento_diario`, `auditar` o las
  demás funciones marcadas en `090_grants.sql:68-74`.
- El arreglo del worker no cubre el caso de **dos turnos distintos** del mismo chat que
  dejen propuestas sin resolver (por ejemplo, el usuario dicta, no confirma y vuelve a
  dictar). Ahí sí queda una huérfana, y es lo que la purga limpia. No se cerró en el worker
  porque implicaría decidir si la propuesta anterior se cancela sola, y eso es una decisión
  de producto que el plan no pide.

## 8. Desviaciones respecto al plan

- Se omiten también las lecturas posteriores a la propuesta, no solo las escrituras (§6).
- Se añadió la config `retencion_ia_acciones_dias`, que el plan no menciona: sin retención
  configurable, el `DELETE` habría llevado un número escrito a mano en la función.

## 9. Trabajo pendiente

- Nada de A3 queda abierto.
- Sigue pendiente lo anotado en la Fase A2: el salto de línea de la tarjeta de borrador
  (`079:249-251`), que se corregiría con un `CREATE OR REPLACE` en una migración nueva.
- La siguiente del plan es **A4** (pruebas de invariantes con pgTAP), que ahora puede
  levantar la base desde las migraciones gracias a A1.
