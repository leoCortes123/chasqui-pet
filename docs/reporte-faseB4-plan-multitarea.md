# Reporte — Fase B4: plan multi-tarea con confirmación mixta

**Fecha:** 13 de agosto de 2026
**Depende de:** A3 (purga de propuestas huérfanas), A5 (registro de
operaciones) y de que existan B1–B3, que es lo que hay para orquestar.

---

## 1. Cambios realizados

Antes de esta fase, un mensaje largo del médico era imposible. `ia_llamar`
dejaba **una** propuesta en `ia_accion_pendiente` y devolvía
`requiere_confirmacion`; el worker abandonaba el turno del modelo ahí mismo
y descartaba el resto de las llamadas del lote, respondiéndoles «ya hay una
acción esperando confirmación». La única multiplicidad que el sistema
manejaba era **dentro** de una herramienta (`despachar_receta_multiple` con
`items[]`), que es batching por esquema, no orquestación.

Ahora «registra a Rocky, ábrele consulta, despacha la receta y agéndale
control en 10 días» es un **plan** de cuatro pasos:

1. **`ia_plan` + `plan_id`/`orden` en `ia_accion_pendiente`.** Las N
   propuestas de un turno se cuelgan de un plan en vez de competir. Un paso
   **es** una propuesta —con su resumen, su expiración y su confirmación—,
   no una entidad paralela.
2. **Estado `planeada` y materialización tardía.** Un paso se anota con los
   argumentos crudos y un título; se prepara —referencias resueltas,
   borrador corrido, resumen calculado, ventana de 10 minutos arrancando—
   **cuando le llega el turno**. Es lo que hace que la tarjeta de un paso
   crítico diga las cifras de ese instante y no las de hace cinco minutos.
3. **Referencias `@pasoN.campo`.** El modelo no puede inventar el UUID de
   algo que todavía no existe: escribe `"@paso1.paciente_id"` y
   `ia_plan_resolver` lo sustituye por el valor real del resultado del paso
   1. **Este es el trabajo técnico central de la fase**: hasta hoy no
   existía ninguna forma de encadenar dependencias entre acciones.
4. **Confirmación mixta.** Un botón para la corrida de pasos no críticos
   (el bloque clínico: paciente → consulta → control) y **un botón propio
   por cada paso `critica = true`** (inventario, cobro), con su tarjeta y
   sus cifras. La distinción ya era dato: la columna `critica` de
   `ia_herramienta`.
5. **Plan reanudable.** Tras confirmar, saltar o cancelar un paso, la
   tarjeta se vuelve a pintar y el plan sigue donde iba. La persona no
   reescribe nada.

**El caso común no cambia.** Un plan de un solo paso se **desarma** al
cerrarse: el paso se suelta de la cabecera, el plan se borra y de ahí en
adelante recorre exactamente el camino de 078 —misma tarjeta
(`bot_ia_tarjeta_confirmacion`), mismos callbacks `ia:ok` / `ia:no` /
`ia:cobrar`—. Una sola escritura no se entera de que hubo plan.

---

## 2. Archivos modificados

| Archivo | Qué |
|---|---|
| `db/migrations/200_plan_multitarea.sql` | **Nuevo.** Toda la fase. Ámbito: NÚCLEO. |
| `worker/src/tareas/chasqui_responder.js` | El bucle deja de abandonar el turno en la primera propuesta; usa `ia_llamar_plan` y cierra con `ia_plan_cerrar`. Instrucciones del modelo ampliadas. |
| `db/pruebas/094_plan_multitarea.sql` | **Nuevo.** 22 invariantes. |
| `docs/reporte-faseB4-plan-multitarea.md` | Este reporte. |

No se tocó ningún workflow de n8n (el enrutador llama
`bot_modulo_callback`, cuya firma no cambia), ni la web, ni ninguna
migración anterior.

---

## 3. Base de datos

### Tablas

| Objeto | Qué |
|---|---|
| `ia_plan` | **Nueva.** Cabecera: `chat_id`, `usuario_id`, `sede_id`, `estado` (`armando → en_curso → completado/cancelado/expirado`), `expira_at`. Deliberadamente flaca. |
| `ia_accion_pendiente.plan_id` | **Nueva columna.** FK a `ia_plan`, `ON DELETE CASCADE`. NULL = propuesta suelta. |
| `ia_accion_pendiente.orden` | **Nueva columna.** Posición del paso; es lo que referencian los `@pasoN`. |
| `ia_accion_pendiente_estado_check` | Rehecho: se suman `planeada` y `omitida` a los cuatro estados de 078, que se conservan tal cual. |
| `idx_ia_paso_plan_orden` | Único sobre `(plan_id, orden)`: `@paso2` tiene que señalar a uno solo. |
| `ia_herramienta.titulo` | **Nueva columna.** Etiqueta corta con emoji para la lista del plan, poblada para las 14 herramientas de escritura. Dato, no `CASE` (disciplina de la Fase A5). |
| `config.ia_plan_minutos` (60), `config.ia_plan_max_pasos` (6) | Parámetros nuevos, editables desde el portal. |

### Funciones nuevas

| Función | Qué |
|---|---|
| `jsonb_buscar_clave(jsonb, text)` | Primer valor escalar con esa clave en cualquier nivel. Resuelve `@pasoN.campo` sin que el modelo conozca nuestras rutas. |
| `ia_plan_resolver(uuid, jsonb)` | Sustituye recursivamente las referencias. **Lanza** si no se puede resolver. |
| `ia_paso_titulo(text)` | Título del catálogo, con respaldo. |
| `ia_plan_agregar(uuid, bigint, uuid, uuid, text, jsonb)` | Anota un paso. Mismas tres rejas y en el mismo orden que `ia_llamar`. |
| `ia_llamar_plan(uuid, bigint, uuid, text, jsonb, uuid)` | La puerta del worker: lecturas se ejecutan, escrituras se anotan. |
| `ia_plan_materializar(uuid)` | Prepara un paso cuando le llega el turno. |
| `ia_plan_paso_actual(uuid)`, `ia_plan_actualizar_estado(uuid)`, `ia_plan_lista(uuid)` | Estado y presentación del plan. |
| `bot_ia_tarjeta_plan(uuid)` | La tarjeta: de bloque, de paso crítico o de cierre. |
| `ia_plan_cerrar(uuid)` | Cierra el armado: 0 pasos → nada; 1 → se desarma; N → plan. |
| `ia_plan_confirmar_bloque(uuid, uuid)` | Corre los pasos no críticos que vienen; se detiene ante el primer crítico y ante el primer fallo. |
| `ia_plan_confirmar_paso(uuid, uuid, boolean)` | Un paso crítico, con o sin el atajo «💳 Cobrar y cerrar». |
| `ia_plan_saltar(uuid, uuid)`, `ia_plan_cancelar(uuid, uuid)` | Saltar ≠ cancelar; la tarjeta final distingue los dos. |

### Funciones reemplazadas (de forma aditiva)

| Función | Qué se le sumó |
|---|---|
| `bot_ia_callback` | Cinco ramas nuevas (`ia:pblo`, `ia:pok`, `ia:pcob`, `ia:psalt`, `ia:pno`). El cuerpo de 082 va entero y palabra por palabra: `ia:abrir`, `ia:salir`, `ia:limpiar`, `ia:ok`, `ia:no`, `ia:cobrar` (con su recibo) y el botón «🩺 Seguir esta consulta». Verificado por diferencia. |
| `ia_purgar_pendientes` | Expira los planes vencidos y los pasos que cuelgan de ellos, y borra las cabeceras sin pasos. Los dos pasos de 130 quedan igual. |

### Permisos

**No estrena ninguno.** Cada paso sigue exigiendo el suyo tres veces, en
los mismos lugares: el catálogo (`ia_herramienta.permiso`), la comprobación
previa (ahora en `ia_plan_agregar`) y el `exigir_permiso` de la función de
negocio, que es la que manda. `ia_plan` se concede a `chasquipet_app`
(CRUD) y a `chasquipet_lectura` (SELECT).

### Migración

`200_plan_multitarea.sql`, idempotente (`CREATE TABLE IF NOT EXISTS`,
`ADD COLUMN IF NOT EXISTS`, `DROP CONSTRAINT IF EXISTS` antes de `ADD`,
`ON CONFLICT DO NOTHING`, `CREATE OR REPLACE`), con cabecera de ámbito
**NÚCLEO** como exige `scripts/migrar.sh`. Aplicada con
`bash scripts/migrar.sh`.

---

## 4. Integraciones

| Integración | Estado |
|---|---|
| **Worker** | `chasqui_responder.js` reescrito en su bucle de herramientas. Reconstruido y en marcha. Sigue sin saber qué es un turno: solo reenvía a `ia_llamar_plan` y pide la tarjeta. |
| **Bot (Telegram)** | Cinco callbacks nuevos, todos dentro de `bot_ia_callback`, que ya estaba enganchado en `bot_modulo_callback`. |
| **n8n** | Sin cambios. No hay que reimportar. |
| **Portal web** | Sin cambios. |
| **Cola `tarea_async`** | Sin cambios: el asistente ya se encolaba y sigue igual. |
| **Purga diaria** | `mantenimiento_diario()` llama a `ia_purgar_pendientes()`, que ahora también barre planes. |

---

## 5. Pruebas ejecutadas

**Batería completa:** `bash scripts/pruebas.sh` — 13 archivos, **todo en
verde**, incluidas las 264 pruebas anteriores (sin regresiones; en
particular `070_ia_confirmacion` y `verificar_registro_operaciones()`
siguen pasando con la columna `titulo` nueva).

`db/pruebas/094_plan_multitarea.sql` — 22 pruebas, todas PASS:

| # | Prueba | Esperado | Obtenido | PASS/FAIL |
|---|---|---|---|---|
| 1 | Anotar el paso 1 | `ok:true`, no ejecuta | igual | PASS |
| 2 | Posición del paso 1 | 1 | 1 | PASS |
| 3 | Paso 2 con `@paso1.paciente_id` | queda anotado como 2 | 2 | PASS |
| 4 | Estado del paso 2 | `planeada` | `planeada` | PASS |
| 5 | Paso 3 (crítico) se anota igual | 3 | 3 | PASS |
| 6 | **C6.9 en el plan**: mascotas creadas al anotar | 0 | 0 | PASS |
| 7 | **C6.9 en el plan**: salidas de inventario al anotar | 0 | 0 | PASS |
| 8 | Idempotencia: paso idéntico repetido | `repetida:true`, no duplica | igual | PASS |
| 9 | **Permisos**: actor sin permiso anota | `ok:false` | `ok:false` | PASS |
| 10 | Cierre del plan | 3 pasos | 3 | PASS |
| 11 | Tarjeta con botón de bloque | contiene `ia:pblo:` | sí | PASS |
| 12 | Bloque: pasos ejecutados | 2 (se detiene en el crítico) | 2 | PASS |
| 13 | El paso 1 creó la mascota | 1 | 1 | PASS |
| 14 | **Encadenamiento**: la consulta es de esa mascota | 1 | 1 | PASS |
| 15 | El paso crítico NO se ejecutó con el botón del bloque | 0 salidas | 0 | PASS |
| 16 | Al llegarle el turno, el crítico se prepara y pide `ia:pok:` | sí | sí | PASS |
| 17 | **Plan ajeno**: otro usuario confirma | «Ese plan no es tuyo.» | igual | PASS |
| 18 | Saltar un paso crítico | `ok:true` | `ok:true` | PASS |
| 19 | **Rollback parcial**: el plan se cierra solo | `completado` | `completado` | PASS |
| 20 | **Auditoría** del bloque | evento `ia_plan/confirmar_bloque` | existe | PASS |
| 21 | Plan de un solo paso | `pasos:1` | 1 | PASS |
| 22 | …y su cabecera desaparece | 0 filas en `ia_plan` | 0 | PASS |

**Verificación manual sobre la base de desarrollo** (dos guiones dentro de
`BEGIN … ROLLBACK`, sin dejar rastro):

| # | Escenario | Resultado |
|---|---|---|
| 23 | Plan de 3 pasos (alta → consulta → cita) con referencias | Tarjeta correcta: «Plan de 3 pasos», botón «✅ Hacer los pasos 1 a 3» | PASS |
| 24 | Un paso con argumentos malos (fecha ausente) | El bloque hace 2 de 3, se detiene y la tarjeta muestra el motivo bajo el paso fallido | PASS |
| 25 | Plan de 4 pasos con un crítico en medio | El bloque hace 1–2, para; el crítico muestra su tarjeta con lote, vencimiento, «Hay 30 → quedarían 28» y botones `ia:pok`/`ia:psalt`/`ia:pno` | PASS |
| 26 | Saltar el crítico y seguir | El plan retoma en el paso 4, lo ejecuta y cierra «3 de 4 pasos» con ⏭️ en el saltado | PASS |
| 27 | **Ausencia de datos**: referencia a un paso que no se hizo | El paso se cancela con «El paso N no se hizo, así que no hay de dónde sacar el …» y el plan sigue | PASS |

**Comandos de verificación:** `bash scripts/pruebas.sh` (verde),
`node --check` sobre el worker (OK), `bash scripts/migrar.sh` (aplicada).
No se corrió `npm run typecheck`/`build`: **no se tocó la web**.

---

## 6. Decisiones tomadas

1. **Los pasos viven en `ia_accion_pendiente`, no en una tabla nueva.** Un
   paso de plan es una propuesta: tiene resumen, expiración, confirmación,
   auditoría y purga. Duplicar todo eso en una tabla paralela habría dejado
   dos verdades sobre lo mismo, y la que se desincronizaría es la que dice
   «esto todavía no se ha ejecutado».
2. **Materialización tardía, con una excepción: el paso 1.** El primer paso
   no puede depender de nadie, así que se prepara al anotarlo. La razón no
   es de eficiencia: si su validación falla («falta el nombre de la
   mascota»), el modelo se entera **en ese mismo turno** y se lo pregunta a
   la persona. Ese ida y vuelta existía con `ia_llamar` y perderlo habría
   sido un retroceso.
3. **Referencias por nombre del dato, no por ruta.** `@paso1.paciente_id`
   y no `@paso1.paciente.paciente_id`. Las rutas cambian entre funciones y
   son asunto nuestro; pedirle al modelo que las conozca es pedirle que
   adivine nuestra estructura.
4. **Un plan de un paso se desarma.** Alternativa descartada: dejar el plan
   y hacer que `ia_confirmar` supiera cerrarlo. Habría metido el concepto
   de plan dentro del camino de un solo paso, que es el 90% del uso, a
   cambio de nada.
5. **Botón de bloque = corrida de pasos no críticos consecutivos**, no
   «todos los no críticos del plan». Ejecutar 1, 2 y 4 saltándose el 3 y
   volviendo después habría desordenado las dependencias y, sobre todo,
   habría sido imposible de contar en una tarjeta.
6. **«⏭️ Saltar» además de «✖️ Cancelar».** El plan admite explícitamente
   estados a medias; «la receta se la doy después, pero el control sí
   agéndalo» es el caso real. Cancelar el plan entero por un paso que no
   aplica habría empujado a la persona a repetir todo, que es justo lo que
   la fase vino a quitar.
7. **Cada paso se ejecuta por `ia_confirmar`**, la misma puerta del camino
   de un solo paso. No se reimplementaron los chequeos de dueño, de
   expiración ni la auditoría por acción.
8. **Tope de 6 pasos por plan** (`ia_plan_max_pasos`) y vida de 60 minutos
   (`ia_plan_minutos`), ambos configurables. Un modelo enredado no puede
   anotar veinte escrituras, y un plan olvidado no se queda vivo un día.

---

## 7. Incertidumbres restantes

1. **Qué tan bien usa el modelo la convención `@pasoN.campo`.** Está en el
   prompt del sistema con dos ejemplos, y el catálogo no la declara por
   herramienta (los esquemas JSON siguen diciendo «UUID de la mascota»).
   Si en uso real el modelo la ignora y busca el dato con
   `buscar_paciente`, el plan seguirá funcionando —encontrará la mascota
   recién creada— pero gastará una llamada de más. **Solo se sabe
   observando conversaciones reales**; no se quiso tocar los esquemas de
   catorce herramientas antes de tener esa evidencia.
2. **Cuántos pasos propone de más.** La instrucción es «anota solo los
   pasos que te pidieron». La guarda de duplicados cubre la repetición
   literal, no la iniciativa.
3. **`ia_resumen_accion` sigue ramificando con un `CASE`** (Fase A7b
   pendiente). Los pasos no críticos sin borrador propio dependen de él
   para su resumen; una herramienta nueva sin rama cae en «Acción: x», que
   ahora se ve además en la lista del plan. El respaldo es
   `ia_herramienta.titulo`, que sí es dato.

---

## 8. Riesgos y problemas encontrados

1. **Sin transacción todo-o-nada entre pasos.** Es el riesgo que la fase
   **acepta de entrada** y está en el plan: con confirmación humana
   intercalada no hay atomicidad posible. Mitigación: cada paso es válido
   por sí solo (una `consulta` en borrador y una `cuenta` abierta ya eran
   estados legítimos), el bloque se detiene ante el primer fallo en vez de
   seguir con datos rotos, y la tarjeta final dice qué se hizo, qué no y
   por qué.
2. **Una escritura del asistente ya no se ejecuta al vuelo… y nunca lo
   hizo.** Se verificó explícitamente (pruebas 6, 7 y 15) que anotar pasos
   no toca ninguna tabla de negocio, y que el botón del bloque **no**
   arrastra un paso crítico. Era el riesgo mayor de la fase: un solo botón
   que despachara inventario «de paso» habría roto C6.9.
3. **`bot_ia_callback` se reescribe entera cada vez que una fase le agrega
   una rama** (078 → 079 → 082 → 200). Es una limitación de Postgres, no
   una decisión; se mitiga copiando el cuerpo anterior palabra por palabra
   y dejándolo dicho en el comentario. Es la cuarta copia y ya pesa: vale
   la pena considerar un despachador por dato, como el de la Fase A5.
4. **Se re-aplicó `200_plan_multitarea.sql` sobre la base de desarrollo.**
   Durante la fase, la verificación manual mostró que la tarjeta no decía
   por qué había fallado un paso. En vez de crear una migración `201` que
   parchara una función nacida diez minutos antes en la misma fase, se
   corrigió el archivo, se borró su fila de `schema_version` y se volvió a
   aplicar (la migración es idempotente). **La regla «una migración
   aplicada no se edita» se saltó a conciencia y solo por eso**: base única,
   de desarrollo, sin commit de por medio. En cualquier otro ambiente esto
   habría sido una migración nueva.

---

## 9. Desviaciones respecto al plan

| Plan | Implementado | Por qué |
|---|---|---|
| «`plan_id` + `orden` en `ia_accion_pendiente`» | Eso, **más** la tabla `ia_plan` | Sin cabecera no había dónde poner el estado del plan, su expiración ni de quién es. Los pasos siguen donde el plan los pedía. |
| «un botón para el bloque clínico» | Un botón por **corrida de pasos no críticos**, no por «bloque clínico» | Lo clínico no es una categoría del sistema; `critica` sí, y ya era dato. El resultado en el caso del plan (paciente → consulta → control) es exactamente el descrito. |
| — | Se agregó «⏭️ Saltar este paso» | Ver decisión 6. |
| — | Se agregó `ia_herramienta.titulo` | Un paso anotado necesita etiqueta antes de tener resumen. Se resolvió como dato, no como `CASE`. |

Nada del alcance quedó fuera.

---

## 10. Trabajo pendiente

- **Observar conversaciones reales** para decidir si la convención
  `@pasoN.campo` merece entrar en los esquemas JSON de las herramientas
  (incertidumbre 1).
- **Fase A7b**: sacar `ia_resumen_accion` y `ia_texto_resultado` del
  núcleo. Ahora tienen un consumidor más (la lista del plan).
- **Un despachador por dato para `bot_ia_callback`**, si aparece una quinta
  fase que le agregue ramas (riesgo 3).
- **Fase B5** (métricas del asistente) sigue sin empezar; no depende de
  esta fase ni la bloquea.
- El plan multi-tarea **solo existe en el bot**. El portal web no muestra
  planes en curso; no estaba en el alcance.
