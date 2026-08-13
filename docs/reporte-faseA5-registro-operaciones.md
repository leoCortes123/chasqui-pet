# Reporte — Fase A5: Registro declarativo de operaciones

**Plan:** `docs/plan-consolidacion-chasqui-pet.md` → Bloque A, Fase A5
**Estado:** `COMPLETED`
**Fecha de verificación:** 2026-08-12
**Banco de pruebas:** base efímera desde `db/migrations/` + `db/demo/`, con captura de
regresión antes y después del cambio sobre **la misma base**.

## 1. Resumen

El ruteo del asistente dejó de ser código y pasó a ser dato. Antes, `ia_llamar`, `ia_leer` e
`ia_escribir` ramificaban con un `CASE` por nombre de herramienta, y cada fase del asistente
las reescribía **enteras** para agregar una rama: `079`, `081`, `082` y `083` hicieron
exactamente eso, y de ahí salió la dependencia de orden estricta entre migraciones que la
Fase A1 tuvo que desenredar.

Ahora `ia_herramienta` dice también qué función atiende cada herramienta, y los tres
despachadores no ramifican: buscan la fila y ejecutan.

- **25 envoltorios `op_*`** con firma uniforme `(p_actor uuid, p_sede uuid, p_args jsonb)
  → jsonb`. Los cuerpos salieron mecánicamente de las ramas del `CASE`, una por una.
- **Tres columnas nuevas** en `ia_herramienta`: `funcion`, `funcion_borrador` y `modulo`.
- **`verificar_registro_operaciones()`**, que es lo que compensa haber perdido la
  verificación estática que daba el `CASE`. Corre dentro de la batería de la Fase A4.
- **Regresión con evidencia**: las 25 herramientas responden **byte por byte igual** que
  antes del cambio.

Agregar una herramienta pasa de tocar cuatro funciones a ser un `INSERT` y un envoltorio.

## 2. Archivos

| Archivo | Cambio |
|---|---|
| `db/migrations/140_registro_operaciones.sql` | **Nueva.** Columnas, 25 envoltorios `op_*`, carga del registro, `verificar_registro_operaciones()` y los tres despachadores sin ramas. Cabecera `NÚCLEO`. |
| `db/pruebas/070_ia_confirmacion.sql` | La prueba que miraba `prosrc` de `ia_escribir` se reemplazó por `verificar_registro_operaciones()` más tres comprobaciones del registro (12 → 15 pruebas). |

Sin cambios en `worker/`, `web/` ni `n8n/`: el worker llama `ia_llamar` y su contrato no
cambió.

## 3. Diseño

**Dos columnas de destino, no una.** El plan pedía `funcion`. Hizo falta separar en dos
porque las seis herramientas que normalizan lenguaje de mostrador tienen **dos** destinos
distintos: el preparador (`ia_consulta_borrador`) y el ejecutor (`ia_consulta_ejecutar`).
Meterlos en una sola columna habría obligado a dejar la lista de esas seis escrita a mano
dentro de `ia_llamar` —justo el `IN (...)` que se quería quitar—.

| Columna | Firma | Quién la ejecuta |
|---|---|---|
| `funcion` | `(uuid, uuid, jsonb) → jsonb` | `ia_llamar` si la herramienta lee; `ia_escribir` tras la confirmación si escribe. |
| `funcion_borrador` | `(uuid, bigint, uuid, jsonb) → jsonb` | `ia_llamar`, solo en las seis con preparador propio. Es la firma que esas seis ya tenían: no se les tocó una línea. |
| `modulo` | — | Nadie todavía. Es la disciplina multi-negocio del plan: `SELECT modulo, count(*) FROM ia_herramienta` responde hoy `turnos 5, cobro 7, clinico 5, inventario 4, admin 2, compras 1, avisos 1`. |

**Reparto de las 25:** 13 lecturas, 6 escrituras directas y 6 con preparador propio.

**`ia_leer` también se desmontó.** No lo pedía el plan, pero dejarla con su `CASE` habría
significado conservar una segunda copia de las 13 lecturas —la duplicación que esta fase
elimina—. Conserva su firma, que es contrato público, y delega en el registro.

**Sobre la inyección:** `format('SELECT public.%I($1,$2,$3)')` cita el identificador y lo
califica con el esquema; el nombre sale de una tabla en la que solo escribe el
administrador de la base. Quien pueda escribir ahí ya podía crear funciones: no hay
superficie nueva.

**Sin restricción `NOT NULL` en `funcion`.** En instalación limpia, `078`–`083` insertan sus
herramientas antes de que exista la columna, y `140` las completa después. Una restricción
rompería cualquier migración futura que registre una herramienta antes de rellenarla; el
guardián es `verificar_registro_operaciones()` corriendo en las pruebas, que es donde el
plan lo puso.

## 4. Base de datos

- **Columnas nuevas:** `ia_herramienta.funcion`, `.funcion_borrador`, `.modulo`, las tres
  documentadas con `COMMENT`.
- **Funciones nuevas:** 25 `op_*` + `verificar_registro_operaciones()`.
- **Funciones reemplazadas:** `ia_llamar`, `ia_escribir`, `ia_leer`. `ia_llamar` conserva
  **exactamente** el orden de decisiones anterior: herramienta activa → permiso →
  preparador propio → lectura (con su captura de errores) → propuesta.
- **Permisos:** los `op_*` los hereda `chasquipet_app` por los privilegios por defecto de
  `090_grants.sql` (`GRANT EXECUTE ON FUNCTIONS`). Nada nuevo que conceder.
- **Idempotencia:** `ADD COLUMN IF NOT EXISTS`, `CREATE OR REPLACE` y un `UPDATE … FROM
  (VALUES …)` por nombre.

## 5. Pruebas ejecutadas

**Regresión (el punto de mayor riesgo del plan).** Se levantó una base con `db/demo/` y las
migraciones **sin** la `140`, se capturó la respuesta de las 25 herramientas, se aplicó la
`140` sobre esa misma base y se volvió a capturar. Las escrituras se ejercitaron dentro de
`BEGIN … ROLLBACK` para partir siempre del mismo estado. Se enmascararon los valores
volátiles (UUID, marcas de tiempo, minutos de espera, secuencias, el token del enlace) y se
comprobó primero que dos capturas seguidas **sin** cambiar nada dieran un resultado idéntico.

| # | Prueba | Esperado | Obtenido | Resultado |
|---|---|---|---|---|
| 1 | Determinismo de la captura (dos corridas sin cambios) | Idénticas | Idénticas, 1284 líneas | PASS |
| 2 | **Las 13 lecturas** por `ia_llamar` | Igual que antes | Sin una sola diferencia | PASS |
| 3 | **Las 6 escrituras directas**: propuesta por `ia_llamar` y ejecución por `ia_escribir` | Igual que antes | Sin diferencias | PASS |
| 4 | **Las 6 con preparador propio**: borrador y ejecución | Igual que antes | Sin diferencias | PASS |
| 5 | Lectura con argumento roto (`paciente_id` no es UUID) | Vuelve como resultado, no rompe la tarea | Mismo `{ok:false, error:…}` | PASS |
| 6 | Herramienta inexistente en `ia_llamar` y en `ia_escribir` | Mismo mensaje | Idéntico | PASS |
| 7 | Lectura y escritura sin permiso | Mismo rechazo | Idéntico | PASS |
| 8 | `cambiar_estado_turno` con una acción inventada | «Esa acción sobre el turno no existe.» | Idéntico | PASS |
| 9 | `ia_leer` llamada directo (contrato público) | Sigue respondiendo igual | Idéntico | PASS |
| 10 | `verificar_registro_operaciones()` | Sin hallazgos | `{"ok": true, "hallazgos": [], "herramientas": 25}` | PASS |
| 11 | El verificador detecta de verdad | Debe señalar lo mal registrado | Con la comprobación de firma mal escrita marcó las 25 y los 6 preparadores; corregida, cero | PASS |
| 12 | Batería completa de la Fase A4 desde cero | Todo en verde | 99 pruebas en 7 archivos | PASS |
| 13 | Aplicación al entorno de trabajo con `migrar.sh` | Aplica y registra | `140 … ok`; `schema_version` al día | PASS |
| 14 | Humo en el entorno de trabajo | Las lecturas responden | `ver_cola`, `ver_tarifas`, `resumen_dia` → `ok`; sin errores en worker ni web | PASS |

## 6. Decisiones tomadas

- **`funcion_borrador` como columna** en vez de dejar la lista de las seis dentro de
  `ia_llamar` (§3).
- **`ia_leer` delegando** en vez de quedarse con su `CASE` (§3).
- **`oidvectortypes(proargtypes)` para comparar firmas**, no
  `pg_get_function_identity_arguments`, que incluye los nombres de los parámetros. La
  primera versión del verificador usaba la segunda y marcaba las 25 herramientas como mal
  registradas: lo detectó la propia corrida, no una revisión.
- **`modulo` con los mismos nombres que `permiso.modulo`** (turnos, inventario, clinico,
  cobro, compras, admin) más `avisos`, para que las dos tablas hablen el mismo idioma.
- **La prueba de A4 que miraba `prosrc` se reemplazó**, no se borró: era la que verificaba
  que toda herramienta tuviera ejecutor, y ese papel lo hace ahora
  `verificar_registro_operaciones()` mejor —comprueba además que la función exista y tenga
  la firma correcta—.

## 7. Riesgos y problemas encontrados

- **`ia_resumen_accion` y `ia_texto_resultado` siguen ramificando.** Son presentación —el
  texto de la tarjeta de confirmación y el de la respuesta— y el plan no las incluye en
  esta fase. Consecuencia honesta: agregar una herramienta **de escritura directa** es un
  `INSERT` + un envoltorio + dos ramas de presentación; agregar una **de lectura** sí es
  solo el `INSERT` y el envoltorio. Sacarlas del núcleo es la Fase A7b.
- **La verificación estática se perdió, como el plan anticipaba.** Antes, una herramienta
  mal enchufada se veía leyendo el `CASE`; ahora hay que correr el verificador. Por eso
  quedó dentro de la batería de pruebas y no como una función suelta que nadie ejecuta.
- **`op_enlace_portal` no es `STABLE`**: crea un enlace de un solo uso. Está clasificada
  como lectura para el asistente porque no cambia datos de negocio y solo le da al propio
  usuario su enlace, que es como funcionaba antes. Queda anotado en la migración.

## 8. Desviaciones respecto al plan

- Se agregó `funcion_borrador`; el plan mencionaba solo `funcion` y `modulo`.
- Se desmontó también el `CASE` de `ia_leer`, que el plan no nombraba.
- El plan pedía «una regresión manual por cada una de las 25 herramientas». Se hizo
  automatizada y comparando salidas byte a byte, que es más fuerte que revisarlas a ojo.

## 9. Trabajo pendiente

- Nada de A5 queda abierto.
- Pendiente de A2: el salto de línea de la tarjeta de borrador (`079:249-251`).
- Siguen A6 (subir al núcleo la orquestación del alta de paciente) y A7a (convención de
  cabecera, que las migraciones nuevas ya vienen cumpliendo).
