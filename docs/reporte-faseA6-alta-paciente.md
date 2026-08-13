# Reporte — Fase A6: La orquestación del alta de paciente sube al núcleo

**Plan:** `docs/plan-consolidacion-chasqui-pet.md` → Bloque A, Fase A6
**Estado:** `COMPLETED`
**Fecha de verificación:** 2026-08-12
**Banco de pruebas:** base efímera levantada desde `db/migrations/` con pgTAP
(`scripts/pruebas.sh`), más aplicación de la migración a la base de trabajo con
`scripts/migrar.sh`.

## 1. Resumen

Dar de alta una mascota nunca fue «insertar un paciente»: es una transacción con reglas
—dueño nuevo o dueño ya registrado, no duplicar al dueño, avisar del posible duplicado antes
de crear (§8.1)—. Esas reglas estaban escritas **dos veces**, una por canal:

- `bot_cli_crear_paciente` (`056_bot_clinico.sql:815`) para el flujo de botones;
- `ia_alta_paciente_ejecutar` (`078_chasqui_ia.sql:743`) para el asistente.

Ahora hay **una sola función de negocio**, `alta_paciente(p_actor, p_args, p_canal)`, y los
dos caminos anteriores quedaron como envoltorios que solo traducen entrada y salida a su
canal. El bot sigue encadenando con la consulta y dibujando la ficha; el asistente sigue
devolviendo el `jsonb` que espera `ia_texto_resultado`. Ninguno de los dos vuelve a decidir
nada sobre dueños ni duplicados.

Efecto medible: los tres módulos del bloque B que crearán pacientes o dueños llaman a esta
función en vez de escribir una tercera, cuarta y quinta copia de la misma regla.

## 2. Archivos

| Archivo | Cambio |
|---|---|
| `db/migrations/150_alta_paciente.sql` | **Nueva.** `alta_paciente()` y las dos versiones nuevas —delegantes— de `ia_alta_paciente_ejecutar` y `bot_cli_crear_paciente`. Cabecera `VERTICAL` (convención A7a). |
| `db/pruebas/080_alta_paciente.sql` | **Nuevo.** 17 pruebas del alta: éxito, reutilización de dueño, duplicados, sin dueño, datos inválidos, auditoría y contrato de los dos canales. |
| `db/pruebas/010_permisos.sql` | Una prueba más: `alta_paciente` exige permiso (28 → 29). |
| `scripts/pruebas.sh` | El corredor compara el plan declarado contra las pruebas corridas y falla si no cuadran (ver §7). |

Sin cambios en `worker/`, `web/` ni `n8n/`: ninguno llama a estas funciones directamente.

## 3. Diseño

**Contrato de salida aditivo.** `alta_paciente` devuelve lo que devolvía `crear_paciente`
—`{ok, paciente}`— más tres datos que solo ella conoce: `dueno` (la ficha completa),
`dueno_reutilizado` y `duplicados`. Por eso `ia_texto_resultado`, que lee
`p_resultado->'paciente'->>'nombre'`, no necesitó tocarse: es exactamente la comprobación de
la prueba 16 del archivo nuevo.

**Los fallos se devuelven tal cual.** Cuando falla `crear_dueno` o `crear_paciente`, se
propaga su `jsonb` con su `motivo` y su `mensaje`, porque los dos canales ya sabían mostrar
eso. Los `motivo` propios de la función nueva son `sin_nombre`, `dueno_inexistente` y
`sin_dueno`.

**Tres rejas de permiso, no una.** `alta_paciente` exige `pacientes.editar` **antes de
escribir nada**; `crear_dueno` y `crear_paciente` la vuelven a exigir por su cuenta. La de
arriba existe para que la operación completa falle antes de crear medio registro, no para
sustituir a las otras dos.

**Qué NO se movió.** La detección de duplicados *conversacional* de `bot_cli_texto`
(`056:900-926`) se quedó donde está: no es la regla de negocio, es una pregunta al operador
—«¿es alguno de estos?»— construida con `buscar_dueno` para ahorrarse dos pasos del
formulario. La regla de negocio es `posibles_duplicados`, que ya vivía en el núcleo y ahora
la llama un solo sitio. `ia_alta_paciente_borrador` tampoco se tocó: normaliza lenguaje de
mostrador y arma la tarjeta, que es el trabajo legítimo que el plan excluye de la
mecanización.

## 4. Base de datos

| Objeto | Qué |
|---|---|
| `alta_paciente(uuid, jsonb, text)` | **Nueva.** `GRANT EXECUTE` a `chasquipet_app`. Comentario de función registrado. |
| `ia_alta_paciente_ejecutar(uuid, jsonb)` | Reemplazada por `CREATE OR REPLACE`. Misma firma; cuerpo de una línea. |
| `bot_cli_crear_paciente(uuid, bigint, jsonb, bigint)` | Reemplazada por `CREATE OR REPLACE`. Misma firma; conserva el encadenado con la consulta y la ficha. |

Sin tablas, columnas ni permisos nuevos. La migración es idempotente (solo
`CREATE OR REPLACE` y un `GRANT` repetible) y quedó registrada en `schema_version` como
`150`, aplicada a la base de trabajo con `scripts/migrar.sh`.

Auditoría: `crear_dueno` y `crear_paciente` siguen auditando cada uno lo suyo.
`alta_paciente` agrega **un evento más**, `('paciente', id, 'alta')`, con
`{dueno_id, dueno_reutilizado, duplicados_advertidos}`. Es lo que antes no se podía
reconstruir después: si se advirtió de un duplicado y aun así se creó.

## 5. Pruebas ejecutadas

`bash scripts/pruebas.sh` — base construida desde cero con las 31 migraciones, ocho archivos,
todo en verde.

| # | Prueba | Esperado | Obtenido | Resultado |
|---|---|---|---|---|
| 1 | Alta con dueño nuevo | `ok:true`, paciente y dueño creados y enlazados | Igual | PASS |
| 2 | Devuelve el paciente | `paciente.nombre` presente | Igual | PASS |
| 3 | Dueño enlazado | `dueno.dueno_id` no nulo | Igual | PASS |
| 4 | Dueño creado, no reutilizado | `dueno_reutilizado:false` | Igual | PASS |
| 5 | Segunda mascota, mismo teléfono (con espacios) | `dueno_reutilizado:true` | Igual | PASS |
| 6 | Y no se crea un dueño nuevo | `count(dueno)` igual | Igual | PASS |
| 7 | Las dos mascotas del mismo dueño | mismo `dueno_id` | Igual | PASS |
| 8 | Repetir mascota + dueño no bloquea | `ok:true` | Igual | PASS |
| 9 | Pero avisa del duplicado | `duplicados` no vacío | Igual | PASS |
| 10 | Mascota sin dueño (`sin_dueno`) | `paciente.dueno_id` nulo | Igual | PASS |
| 11 | Sin nombre de mascota | `motivo:'sin_nombre'` | Igual | PASS |
| 12 | Y no queda nada a medias | `count(paciente)` igual | Igual | PASS |
| 13 | `dueno_id` que ya no existe | `motivo:'dueno_inexistente'` | Igual | PASS |
| 14 | Sin datos de dueño ni `sin_dueno` | `motivo:'sin_dueno'` | Igual | PASS |
| 15 | Auditoría del acto completo | evento `paciente/alta` con `dueno_reutilizado` | Igual | PASS |
| 16 | Contrato del asistente | `ia_alta_paciente_ejecutar` devuelve `paciente.nombre` | Igual | PASS |
| 17 | Contrato del bot | `bot_cli_crear_paciente` termina en la ficha de la mascota | Igual | PASS |
| 18 | Permisos (`010_permisos.sql`) | `alta_paciente` lanza `42501` con Don Nadie | Igual | PASS |
| 19 | Regresión, resto de la batería | las 99 pruebas previas en verde (117 en total) | Igual | PASS |
| 20 | Instalación limpia | la base se construye desde `db/migrations/` sin error | Igual | PASS |
| 21 | Migración sobre base viva | `migrar.sh` aplica `150` y registra la versión | Igual | PASS |
| 22 | Registro de operaciones intacto | `verificar_registro_operaciones()` → `ok:true` | Igual | PASS |

Cobertura contra el Anexo A2 del plan: caso exitoso (1-4), datos inválidos (11-14), permisos
insuficientes (18), ausencia de datos (10, 14), idempotencia de la migración (20-21),
«rollback» —nada creado a medias— (12), auditoría (15), confirmación humana (sin cambios:
`070_ia_confirmacion.sql` sigue en verde), respuesta al usuario (16-17) e integración (19,
22).

## 6. Decisiones tomadas

1. **El flujo de botones ahora también reutiliza dueños.** Es el único cambio de conducta
   visible. Antes, el bot creaba un dueño nuevo siempre que no hubiera `dueno_id`, aunque el
   teléfono ya estuviera registrado; el asistente sí lo reutilizaba. Se unificó hacia el
   comportamiento del asistente porque §8.1 pide buscar antes de crear, y porque tener dos
   conductas distintas para la misma regla era justamente el problema de la fase. Queda
   visible en la respuesta (`dueno_reutilizado`) y en la auditoría.
2. **El documento manda sobre el teléfono** al buscar un dueño existente: un teléfono se
   comparte en una familia, un documento no.
3. **Los duplicados avisan, no bloquean.** La clínica sabe mejor que la base si hay dos
   «Firulais» de la misma familia. Se devuelven en `duplicados` para que el canal los muestre.
4. **`p_canal` como parámetro con valor por defecto `'telegram'`**, en vez de fijarlo dentro:
   el día que el portal web dé de alta pacientes, la auditoría lo va a distinguir sin tocar
   la función.
5. **Un evento de auditoría propio del acto completo**, aunque las dos funciones internas ya
   auditen. Lo que agrega es lo que ninguna de las dos sabe: si hubo duplicados advertidos y
   si el dueño se reutilizó.

## 7. Riesgos y problemas encontrados

- **El corredor de pruebas no detectaba un `plan(n)` desalineado — corregido.**
  `scripts/pruebas.sh` contaba líneas `^ok ` y `^not ok`; cuando un archivo declaraba
  `plan(15)` y corría 17 pruebas, pgTAP lo reportaba como diagnóstico
  (`# Looks like you planned…`), no como fallo, y el corredor lo daba por verde. Se detectó al
  escribir `080`. El corredor ahora compara el plan declarado (`1..n`) contra las pruebas
  corridas y falla en los tres casos: plan de menos, plan de más y archivo sin plan.
  Es un retoque del arnés de la Fase A4, hecho aquí porque sin él las pruebas de esta fase no
  probaban lo que decían probar.
- El cambio de conducta de la decisión 1 puede sorprender a quien registre dos mascotas de
  personas distintas que comparten teléfono: la segunda queda colgada del primer dueño. Es la
  conducta que el asistente ya tenía desde la Fase 1 y no ha dado problemas; si molesta, el
  arreglo natural es pedir el documento en el flujo de botones, no volver a duplicar dueños.

## 8. Desviaciones respecto al plan

- El plan describía la firma como `alta_paciente(p_actor uuid, p_args jsonb)`. Se agregó un
  tercer parámetro `p_canal text DEFAULT 'telegram'` (decisión 4). Las llamadas con dos
  argumentos siguen siendo válidas.
- El plan mencionaba mover también «la detección de duplicados de `bot_cli_texto`». Se movió
  la regla (`posibles_duplicados`, ahora invocada en un solo sitio) pero **no** la pregunta
  conversacional con `buscar_dueno`, que es interfaz del flujo de botones y no tiene
  equivalente en el asistente. Sacarla habría sido mover presentación al núcleo, justo lo
  contrario de la Fase A7b.

## 9. Trabajo pendiente

- Fase A7 del plan: (a) convención de cabecera en migraciones nuevas —ya aplicada en `150`—;
  (b) sacar presentación del núcleo.
