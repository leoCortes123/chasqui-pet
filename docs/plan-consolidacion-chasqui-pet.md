# Plan por fases: consolidar Chasqui Pet y completar el producto

> Documento vigente desde el 12 de agosto de 2026. Sustituye a los planes archivados en
> `docs/archivo/`. El §Anexo recoge las reglas y la batería de pruebas que siguen en vigor y
> que antes vivían en `plan_complementacion_asistente_chasqui.md`.

## Contexto

Chasqui Pet tiene el MVP terminado y el asistente «Habla con Chasqui» a medio camino
(fases 1–5 del plan del asistente escritas, fase 6 sin empezar). El análisis previo del
sistema arrojó tres conclusiones que ordenan este plan:

1. **La arquitectura se mantiene.** El núcleo en PostgreSQL no está sobrecargado por la IA:
   `ia_escribir` (`078_chasqui_ia.sql:478`) llama a `llamar_siguiente`, `salida_medicamento` y
   `registrar_pago` sin un solo adaptador. El core ya funciona como pool de herramientas y eso
   quedó demostrado empíricamente cuando el agente lo reusó como tercer canal.
2. **Las falencias reales son de herramental, no de diseño**: no hay versionado de migraciones,
   no hay pruebas, y el ruteo del agente está escrito a mano en un `CASE` que cada fase
   reescribe entera.
3. **Falta producto**: agenda, control, remisiones y seguimiento de resultados no existen —
   ni siquiera como funciones. Son módulos de negocio, no trabajo de IA.

El objetivo es un producto **especializado en clínicas veterinarias**, listo para entrar al
mercado. La escalabilidad multi-negocio se atiende **como disciplina, no como abstracción**:
ver §Multi-negocio al final. La integración con Factus/DIAN queda fuera de este plan.

**Orden general:** Bloque A cierra las falencias y deja el terreno firme. Bloque B agrega las
funciones que le faltan al producto. El bloque A va primero porque el B escribe migraciones
nuevas sobre una base con datos reales, y hoy no hay forma de saber qué está aplicado.

---

# BLOQUE A — Cimientos

## Fase A0 — Ordenar la documentación ✅ HECHA (12-ago-2026)

Queda un solo documento de plan vigente, para no trabajar contra papeles superados.

- Este plan vive en `docs/plan-consolidacion-chasqui-pet.md`.
- Se creó `docs/archivo/` y se movieron allí, cada uno con cabecera de «documento archivado»:
  `plan_complementacion_asistente_chasqui.md`, `plan_ejecucion_chasquipet.md`,
  `Plan de incorporación de Chasqui Pet a StrictContext.md` y `avance-analisis-strictcontext.md`.
- Se rescataron al §Anexo las reglas C6.5 / C6.8 / C6.9 / C6.12, la batería de pruebas y el
  estado de las fases del asistente, que siguen en vigor.
- Se actualizaron las referencias de `CLAUDE.md` (estructura del repositorio, *Protected Areas*,
  *Testing*, tabla de documentación y contradicciones) y se añadió una nota de reenvío en los
  cuatro `docs/reporte-fase*.md`.

Los `docs/reporte-fase1|3|4|5-*.md` **se quedan donde están**: son evidencia de pruebas, no
planes. El reporte de fase 2 que produce A2 se suma a ellos.

---

## Fase A1 — Versionado y aplicación de migraciones ⬅ bloquea todo lo demás

**Problema:** no hay migrador ni tabla de versiones. Las migraciones se aplican una sola vez
vía `/docker-entrypoint-initdb.d` cuando el volumen está vacío. En una base ya inicializada,
`079`–`083` **no se aplican solas** y no hay forma de verificar cuáles corrieron. Ya produjo
una dependencia de orden estricta `079 → 081 → 082 → 083` sin red de seguridad.

**Alcance:**
- Migración nueva con `schema_version(version text PK, nombre text, hash text, aplicada_at timestamptz)`.
- `scripts/migrar.sh`: recorre `db/migrations/*.sql` en orden alfabético, aplica en transacción
  solo las no registradas, usa `ADMIN_DATABASE_URL`. Registra `hash` para detectar que un
  archivo ya aplicado cambió (debe fallar ruidosamente: la regla del proyecto es no editar
  migraciones existentes).
- Un `.sh` con prefijo posterior a `900_superadmin.sh` que, en instalación limpia, siembra
  `schema_version` con todo lo que initdb acaba de aplicar. Así los dos caminos —volumen nuevo
  y base viva— convergen.
- **Retro-registro en la base viva**: sembrar como aplicadas `010`–`078` y `080`, `085`–`110`
  sin ejecutarlas; luego aplicar `079`, `081`, `082`, `083` en ese orden si no lo están.
  Este paso toca producción: hacer respaldo antes y verificar con las consultas de §Verificación.

**Archivos:** `db/migrations/<siguiente>_schema_version.sql`, `db/migrations/9xx_registrar_versiones.sh`,
`scripts/migrar.sh`, `README.md` (sección de puesta en marcha).

**Tamaño:** M. **No empezar nada más antes de esto.**

---

## Fase A2 — Cerrar formalmente la fase 2 del asistente

**Problema:** `079_chasqui_ia_consulta.sql` (661 líneas) está implementado y arquitectónicamente
correcto —`preparar_consulta_clinica`, validación de rangos del examen físico, borrador que
nunca firma— pero no tiene reporte, no está marcado como completado y **no está en git**.
`docs/reporte-fase3-despacho-recetas.md:79` ya lo registra como riesgo.

**Alcance:**
- Ejecutar la batería del §Anexo A2 contra `079` con datos demo: caso exitoso, datos inválidos,
  permisos insuficientes, ausencia de datos, idempotencia, rollback, auditoría, confirmación
  humana.
- Escribir `docs/reporte-fase2-borrador-consulta.md` con el formato de los reportes hermanos.
- Marcar la Fase 2 como completada en el §Anexo A3.
- Commit de `079`, `081`, `082`, `083`, `worker/src/tareas/enviar_aviso_dueno.js` y los reportes,
  **con rutas explícitas**. Nunca `git add -A`: `opencode.json` tiene una credencial real y no
  está en `.gitignore`.

**Tamaño:** S. Va inmediatamente después de A1 porque es el riesgo vivo más concreto.

---

## Fase A3 — Corregir propuestas huérfanas y purgar `ia_accion_pendiente`

**Problema (defecto real, no deuda):** en `worker/src/tareas/chasqui_responder.js:278-289` el
`for` sobre las tool calls **no hace `break`**. Si el modelo emite tres escrituras en un turno,
se insertan tres filas en `ia_accion_pendiente` y se muestra **una sola tarjeta**. Las otras dos
quedan en estado `pendiente` para siempre: nadie las cancela, `bot_ia_callback` no las limpia,
y `088_mantenimiento.sql` no toca esa tabla. La expiración es perezosa: solo se marca `expirada`
si alguien toca el botón tarde (`078:1020-1024`).

**Alcance:**
- En el worker: una vez que hay `pendiente`, las siguientes tool calls de escritura del mismo
  turno **no llegan a `ia_llamar`**. Se le devuelve al modelo un resultado explicando que hay
  una acción esperando confirmación y que no proponga más. Evita crear la basura en el origen,
  en vez de limpiarla después.
- Migración nueva: `ia_purgar_pendientes()` y enganche **aditivo** en `mantenimiento_diario()`
  (`CREATE OR REPLACE` que conserve todo lo previo — regla del proyecto para funciones de
  enganche).

**Archivos:** `worker/src/tareas/chasqui_responder.js`, `db/migrations/<siguiente>_ia_purga.sql`.

**Tamaño:** S.

---

## Fase A4 — Pruebas de los invariantes del núcleo

**Problema:** cero pruebas automatizadas. Todo se verifica a mano con `psql` contra una base
viva. Las fases A5 y A6 **refactorizan código que funciona**, y refactorizar lógica de negocio
sin pruebas es la forma de trabajo con peor historial que existe.

**Alcance deliberadamente mínimo.** No se busca cobertura: se busca blindar los invariantes que,
si se rompen, rompen el producto o su cumplimiento legal.

- Arnés con pgTAP en un contenedor efímero levantado **desde las migraciones**. Efecto
  secundario valioso: cada corrida valida también el migrador de A1.
- Invariantes a cubrir:
  - `exigir_permiso` rechaza en cada función de escritura de negocio (turnos, inventario,
    clínico, cobro, compras).
  - Append-only: `UPDATE`/`DELETE` sobre `pago`, `descuento`, `movimiento_inventario`,
    `evento_auditoria` falla (`090_grants.sql` + triggers).
  - FEFO: `salida_medicamento` sobre un lote que no es el primero devuelve
    `motivo: 'fefo_sin_justificacion'` (`045_inventario.sql:530-555`).
  - Consulta firmada no se edita (trigger `consulta_inmutable`, `050:247`).
  - Caja cuadra: `cerrar_caja` contra los pagos del día.
  - Consentimiento: no sale aviso a dueño sin `consentimiento_datos` (Ley 1581).
  - IA: toda herramienta con `escribe = true` deja propuesta y **no ejecuta** (C6.9).
- `README.md`: cómo correr las pruebas.

**Tamaño:** L. Es la fase con peor relación esfuerzo/visibilidad y la que más protege todo lo
que viene después. No saltarla.

---

## Fase A5 — Convertir el ruteo del agente en datos

**Problema:** `ia_llamar`, `ia_escribir` y `ia_texto_resultado` se reescriben **completas** en
`079`, `081`, `082` y `083` (copiar-pegar-extender el `CASE`). Agregar una herramienta exige
reescribir cuatro funciones. La tabla `ia_herramienta` ya es declarativa para nombre, permiso,
`escribe`, `critica` y esquema JSON — **lo único que no es dato es qué función SQL ejecuta cada
herramienta**.

**Alcance:**
- Columnas nuevas en `ia_herramienta`: `funcion text` (destino) y `modulo text` (para la
  disciplina multi-negocio; ver §Multi-negocio).
- **Firma uniforme por envoltorio.** Cada operación obtiene un wrapper delgado
  `op_<nombre>(p_actor uuid, p_sede uuid, p_args jsonb) RETURNS jsonb`. Los cuerpos salen
  mecánicamente de las ramas del `CASE` actual, una por una — trabajo aburrido y revisable.
  Ganancia lateral: cada rama pasa a ser una función con nombre, testeable de forma aislada.
- `ia_llamar` deja de ramificar: busca la fila y ejecuta
  `EXECUTE format('SELECT %I($1,$2,$3)', h.funcion)` con `USING`. `%I` cita el identificador, así
  que no hay inyección; y como el nombre sale de una tabla que solo el administrador escribe, no
  hay superficie nueva.
- `verificar_registro_operaciones()`: comprueba que cada `funcion` registrada existe con la
  firma esperada. Se corre en las pruebas de A4 — es lo que compensa la pérdida de verificación
  estática del `CASE`.
- **No se mecanizan** las seis herramientas con borrador propio (`ia_alta_paciente_borrador`,
  `ia_consulta_borrador`, `ia_despacho_borrador`, y las de `082`/`083`): normalizan lenguaje de
  mostrador a códigos del sistema y ese trabajo es legítimo, no repetición. Siguen siendo el
  destino registrado de su herramienta.

**Resultado:** agregar una herramienta pasa a ser **un `INSERT` y un wrapper**. Desaparece la
dependencia de orden entre migraciones de fase. Y cuando aparezca un segundo canal, lee el mismo
registro en vez de escribir un tercer `CASE`.

**Archivos:** `db/migrations/<siguiente>_registro_operaciones.sql`.

**Tamaño:** L. Es el desacople de mayor retorno de todo el plan.

---

## Fase A6 — Subir al núcleo la orquestación que hoy vive en el bot

**Problema:** `bot_cli_crear_paciente` (`056_bot_clinico.sql:815`) orquesta `crear_dueno` +
`crear_paciente` con la regla de "dueño nuevo o existente", y `bot_cli_texto` (`056:337-360`)
implementa la detección de duplicados. Cuando se construyó el asistente **no pudo reusar nada de
eso** y lo reimplementó como `ia_alta_paciente_borrador` (`078:622-800`). La duplicación ya
ocurrió una vez; el bloque B agrega tres módulos nuevos y la repetiría tres veces más.

**Alcance:**
- Función de negocio nueva `alta_paciente(p_actor uuid, p_args jsonb) RETURNS jsonb`: la
  transacción completa —dueño nuevo o existente, detección de duplicados, paciente— con
  `exigir_permiso` y `auditar`.
- `bot_cli_crear_paciente` y `ia_alta_paciente_ejecutar` pasan a delegar en ella. Cambio
  **aditivo**: verificar que no se pierda nada de las versiones previas.
- Las pruebas de A4 cubren la función nueva una vez, en vez de dos veces por canal.

**Tamaño:** M.

---

## Fase A7 — Higiene de fronteras (baja prioridad, alto valor futuro)

Dos cosas de costo muy distinto:

**a) Convención de cabecera en migraciones nuevas — hacerlo desde ya, cuesta cero.**
Cada migración nueva declara en su comentario de cabecera si es `NÚCLEO` (identidad, permisos,
auditoría, cola, config, inventario, cobro, compras, admin) o `VERTICAL` (turnos veterinarios,
pacientes, consulta clínica, agenda de citas). Es una línea de texto y es lo que evita tener que
arqueologizar 25 archivos el día que haga falta.

**b) Sacar presentación del núcleo — opcional, hacerlo si sobra tiempo.**
`recibo_texto` (`060_cobro.sql:503-565`) genera HTML de Telegram dentro de una migración de
negocio; `emoji_especie` (`050:328`), `pesos()` (`060:242`), `fmt_cant()` (`045:141`) son
formateo puro en la capa de datos. Se resuelve creando los equivalentes en la capa `bot_*` y
dejando los originales como envoltorios. **Riesgo bajo, valor bajo hoy.** No bloquea nada.

**Explícitamente fuera de alcance:** renumerar migraciones existentes, partirlas en esquemas de
Postgres, o mover código ya aplicado. Eso sí sería reingeniería, y sin beneficio presente.

**Tamaño:** S (solo a), M (a+b).

---

# BLOQUE B — Producto

## Fase B1 — Agenda de citas

**Estado actual:** las tablas `cita` (`050_pacientes.sql:126`) y `disponibilidad` (`050:144`)
existen como **cascarón vacío**: no hay una sola función que las lea o escriba, y
`consulta.cita_id` (`050:181`) siempre queda `NULL`. El propio archivo lo declara en `050:16-17`:
«Agendamiento — fuera del MVP: se modela el terreno, no se expone».

**Alcance:**
- Revisar si la forma de las tablas aguanta lo que se necesita antes de escribir nada encima.
- Funciones de negocio: `crear_cita`, `reprogramar_cita`, `cancelar_cita`, `confirmar_asistencia`,
  `agenda_del_dia`, `horarios_disponibles`. Contrato uniforme del proyecto: `(p_actor, …args,
  p_canal)` → `jsonb {ok, mensaje, …}`, `exigir_permiso` primero, `auditar` al final.
- Permisos nuevos `agenda.ver` y `agenda.gestionar`, sembrados por rol.
- Enlazar `consulta.cita_id` cuando el turno viene de una cita agendada.
- Canales: vista en el portal, flujo en el bot, y herramienta del asistente — que tras A5 es un
  `INSERT` + un wrapper.
- Avisos de recordatorio al dueño vía `tarea_async`, reutilizando `enviar_aviso_dueno.js` y su
  validación de consentimiento.

**Tamaño:** L. Es la brecha de producto más grande y la que más se nota frente a un competidor.

---

## Fase B2 — Control y recordatorios

**Estado actual:** `consulta.proxima_revision` (`050:201`) se captura por botón en el bot
(`056:439-443`, opciones de 8/15/30 días) y **nadie la lee jamás**: no existe ninguna función con
`WHERE proxima_revision <= hoy`. Es un dato muerto.

**Alcance:**
- Al fijar `proxima_revision`, ofrecer crear la `cita` correspondiente (unifica con B1 en vez de
  construir un segundo mecanismo de agenda).
- Job programado que encuentra controles próximos y encola el aviso al dueño, respetando
  consentimiento y chat vinculado (las tres capas de validación de la Ley 1581 que ya existen:
  borrador, ejecución y worker — no debilitar ninguna).
- Extender a recordatorios de vacunación y desparasitación si el modelo de datos lo permite sin
  inventar un módulo nuevo; si no, dejarlo anotado y no forzarlo.

**Depende de:** B1. **Tamaño:** M.

---

## Fase B3 — Remisiones externas y seguimiento de resultados

**Estado actual:** solo existe la columna de texto libre `consulta.remision_externa`
(`050:200`). No hay catálogo de exámenes, ni laboratorio destino, ni estado de la remisión, ni
nada que persiga una remisión sin resultado. `reporte_pacientes` (`080_reportes.sql:328`) solo
mide *ex post* si el paciente volvió.

**Alcance:**
- Módulo nuevo: `remision` (paciente, consulta, destino, exámenes solicitados, estado
  `pendiente → recibida → anulada`, fechas) y `resultado` (adjunto o texto, quién lo cargó).
- Funciones de negocio con el contrato uniforme + permisos propios.
- Alerta de remisiones vencidas sin resultado (mismo patrón que `alertas_inventario`).
- Aviso al dueño cuando el resultado llega, reutilizando F5.
- Herramienta del asistente para registrar remisión y consultar pendientes.

**Independiente de B1/B2.** **Tamaño:** L.

---

## Fase B4 — Plan multi-tarea con confirmación mixta

**Problema que resuelve:** hoy un mensaje largo del médico («registra a Rocky, abre la consulta,
despacha la receta y agenda control en 10 días») es imposible: el bucle del modelo corta en la
primera confirmación (`chasqui_responder.js:208`) y la conversación no se reanuda —el usuario
debe repetir todo, petición por petición. La única multiplicidad que el sistema maneja es
**dentro de una herramienta** (`despachar_receta_multiple` con `items[]`), que es batching por
esquema, no orquestación.

**Alcance:**
- `plan_id` + `orden` en `ia_accion_pendiente`: las N propuestas de un turno se cuelgan de un
  plan en vez de competir.
- Una tarjeta que muestra el plan completo, con **un botón para el bloque clínico** (paciente →
  consulta → control) y **un botón propio por cada paso `critica = true`** (inventario, cobro).
  La distinción ya es dato: la columna `critica` de `ia_herramienta`.
- **Ejecución secuencial con dependencias**: el `paciente_id` del paso 1 alimenta el paso 2, el
  `consulta_id` el paso 3. Esto hoy no existe en ninguna forma y es el trabajo técnico central
  de la fase.
- Plan reanudable: tras confirmar un paso, se retoma el siguiente sin que el usuario reescriba.

**Riesgo a aceptar de entrada:** con confirmación humana intercalada, **la transacción
todo-o-nada no está disponible entre pasos**. Un plan a medias es un estado normal, no un error.
El modelo de datos ya lo tolera —una `consulta` se queda en `borrador`, una `cuenta` se queda
`abierta`— pero cada paso debe ser válido por sí solo y el plan debe poder retomarse.

**Depende de:** A3 (la limpieza de huérfanas), A5 (el registro), y de que existan B1–B3 para que
haya algo que orquestar. **Tamaño:** L.

---

## Fase B5 — Fase 6 del asistente: métricas

`analizar_ocupacion`, `analizar_rendimiento_medico` y `analizar_rentabilidad_lotes` no existen
(cero coincidencias fuera del plan). Pero la base está lista: `080_reportes.sql` ya trae
`reporte_ocupacion_consultorio` (`:161`), `reporte_turnos_hora` (`:145`), `reporte_consumo`
(`:79`), `reporte_margen`, todas `STABLE` y sin `exigir_permiso` —el control lo hace quien
llama—, y la exportación a CSV ya está resuelta por el patrón de `web/src/app/api/reportes/`.

Tras A5 esto es casi gratis: tres wrappers de solo lectura, tres `INSERT` en el registro con
permiso `reportes.operativos` / `reportes.financieros`, y cerrar el plan del asistente.

**Tamaño:** S. Se puede intercalar donde convenga; no bloquea ni depende de nada del bloque B.

---

# Multi-negocio: la puerta abierta, sin adelantarse

El objetivo es no tener que hacer reingeniería el día que aparezca otro rubro. Eso **no** se
consigue construyendo abstracciones ahora — se consigue con cuatro disciplinas de costo cero:

1. **Contrato uniforme, sin excepciones.** Toda función de negocio nueva:
   `(p_actor_id uuid, …args, p_canal text DEFAULT 'telegram') RETURNS jsonb {ok, mensaje, motivo?, <entidad>}`,
   `exigir_permiso` como primera línea, `auditar` antes de retornar, motivos de error tipados
   legibles por máquina (el modelo de `salida_medicamento`, `045:530-555`).
2. **Cabecera `NÚCLEO` / `VERTICAL` en cada migración nueva** (Fase A7a).
3. **Vocabulario del vertical fuera del núcleo.** Nada de `especie`, `paciente` o `consulta`
   dentro de inventario, cobro, compras o identidad. Hoy se cumple: `grep -c "<b>\|esc("` sobre
   las migraciones de negocio da cero, y la separación de dominio es igual de limpia.
4. **La columna `modulo` del registro de operaciones** (Fase A5): el día que haga falta, "qué
   sabe hacer esta instalación" es una consulta, no una lectura de 25 archivos.

**Explícitamente NO hacer ahora:** modelo de tenants, parametrizar el vertical, esquemas de
Postgres separados, renumerar migraciones, ni una API HTTP de negocio. Todo eso es reingeniería
prematura y ninguna de esas piezas se vuelve más cara por esperar — al contrario, la Fase A5 es
justamente lo que las abarata si algún día se necesitan.

---

# Verificación

**Después de A1** (solo lectura, contra la base viva):

```sql
-- ¿Qué versión de ia_llamar está realmente aplicada?
SELECT prosrc LIKE '%preparar_aviso_dueno%' AS tiene_083 FROM pg_proc WHERE proname = 'ia_llamar';

-- ¿El registro de versiones refleja la realidad?
SELECT version, nombre, aplicada_at FROM schema_version ORDER BY version;
```

**Después de A3:** `SELECT estado, count(*), min(created_at) FROM ia_accion_pendiente GROUP BY estado;`
— no deben acumularse `pendiente` viejas. Prueba manual: pedirle al asistente dos escrituras en
un mensaje y confirmar que se crea **una** sola fila.

**Después de A4:** la suite pgTAP corre en verde desde un contenedor limpio construido a partir
de las migraciones.

**Después de A5:** `SELECT verificar_registro_operaciones();` sin hallazgos, y una regresión
manual por cada una de las 25 herramientas del catálogo — el `CASE` desmontado es el punto de
mayor riesgo de todo el plan.

**Después de cada fase del bloque B:** la batería del §Anexo A2 y su reporte en
`docs/reporte-*.md` con tabla PASS/FAIL. Es el estándar del proyecto.

**Si se tocó la web:** `cd web && npm run typecheck && npm run build`.
**Si se tocó el worker:** `cd worker && npm run check` (solo valida `src/index.js`; los archivos
de `src/tareas/` hay que verificarlos aparte con `node --check`).

---

# Resumen de secuencia

| Orden | Fase | Tamaño | Bloquea a |
|---|---|---|---|
| 0 | A0 Ordenar la documentación | S | — |
| 1 | A1 Versionado de migraciones | M | **todo** |
| 2 | A2 Cerrar fase 2 del asistente | S | — |
| 3 | A3 Huérfanas + purga | S | B4 |
| 4 | A4 Pruebas de invariantes | L | A5, A6 |
| 5 | A5 Registro declarativo de operaciones | L | B1–B5 (los abarata) |
| 6 | A6 Orquestación al núcleo | M | B1–B3 |
| 7 | A7a Convención de cabecera | S | — |
| 8 | B1 Agenda de citas | L | B2 |
| 9 | B2 Control y recordatorios | M | — |
| 10 | B3 Remisiones y resultados | L | — |
| 11 | B4 Plan multi-tarea | L | — |
| 12 | B5 Métricas del asistente | S | — |

A7b (higiene de presentación) es opcional y no entra en la secuencia.

---

# Anexo — Reglas y estándares vigentes

Rescatado de `plan_complementacion_asistente_chasqui.md` antes de archivarlo. **Sigue en vigor
tal cual** y aplica a todo lo de este plan, no solo al asistente.

## A1 — Reglas arquitectónicas obligatorias

**C6.5 — Autorización en SQL.** Toda función de negocio empieza validando autorización con
`PERFORM exigir_permiso(p_actor_id, 'modulo.accion');`. La autorización **no** se traslada al
agente, al bot, al worker ni al código de aplicación. Las comprobaciones en la web y en el bot
son una segunda cerradura, nunca la única.

**C6.9 — Confirmación humana.** La IA nunca ejecuta directamente una escritura. El flujo
obligatorio es:

```
IA → herramienta de preparación → propuesta estructurada → ia_accion_pendiente
   → tarjeta Telegram → [Confirmar] / [Cancelar] → ejecución SQL → auditoría
```

La IA puede preparar la operación; la mutación real requiere confirmación humana explícita.

**C6.12 — Lógica de negocio en PostgreSQL.** El bot, n8n y el worker se limitan a recibir
eventos, despachar operaciones, transportar datos, consumir resultados y presentar respuestas.
No se duplica lógica de negocio en TypeScript, n8n ni ninguna otra capa.

**C6.8 — Procesamiento asíncrono.** Las operaciones pesadas y las notificaciones externas usan
`tarea_async` y las procesa el worker. El bot no es un ejecutor de procesos pesados.

## A2 — Batería de pruebas mínima por fase

Una fase **no** está terminada porque el código compile o porque las funciones existan. Como
mínimo hay que demostrar, con evidencia:

- caso exitoso;
- datos inválidos;
- permisos insuficientes;
- ausencia de datos;
- duplicación / idempotencia cuando corresponda;
- rollback ante error;
- auditoría;
- confirmación humana para escrituras;
- respuesta correcta al usuario;
- integración con los componentes involucrados (bot, worker, portal, n8n).

Las pruebas usan datos representativos, **no destruyen información real** y limpian las trazas
que generen.

**Criterio de finalización.** Una fase se marca completada solo cuando: la funcionalidad está
implementada; respeta la arquitectura existente; no hay bloqueos abiertos; las incertidumbres
relevantes están resueltas; las funciones SQL tienen autorización; las escrituras pasan por
confirmación humana; las operaciones que lo requieren tienen auditoría; lo pesado usa
`tarea_async`; las pruebas principales y los casos de error se ejecutaron; no se introdujeron
cambios fuera del alcance; la integración correspondiente fue verificada; y existe evidencia.

**Reporte obligatorio** (formato de `docs/reporte-fase*.md`): resumen, archivos modificados,
base de datos, integraciones, pruebas ejecutadas con tabla PASS/FAIL, incertidumbres, riesgos,
dependencias y estado (`COMPLETED` / `COMPLETED_WITH_WARNINGS` / `BLOCKED`). No se marca
`COMPLETED` si existe un bloqueo funcional real, y **no se ocultan problemas** para poder
cerrar una fase.

## A3 — Estado de las fases del asistente «Habla con Chasqui»

| Fase | Alcance | Estado |
|---|---|---|
| 1 | `preparar_alta_paciente` — alta de paciente y dueño | ✅ `docs/reporte-fase1-pacientes-duenos.md` |
| 2 | `preparar_consulta_clinica` — borrador de consulta, nunca la firma | ✅ `docs/reporte-fase2-borrador-consulta.md` (cerrada por la Fase A2, 12-ago-2026) |
| 3 | `despachar_receta_multiple` — despacho múltiple con FEFO atómico | ✅ `docs/reporte-fase3-despacho-recetas.md` |
| 4 | `cargar_paquete_servicios`, `aplicar_descuento_asistido` | ✅ `docs/reporte-fase4-paquetes-cobros.md` |
| 5 | `preparar_aviso_dueno` — con consentimiento Ley 1581 | ✅ `docs/reporte-fase5-avisos-duenos.md` |
| 6 | `analizar_ocupacion`, `analizar_rendimiento_medico`, `analizar_rentabilidad_lotes` | ⬜ No empezada → es la Fase B5 de este plan |

## A4 — Regla de trabajo

Antes de implementar cualquier fase hay que inspeccionar lo que ya existe: esquema, tablas,
funciones SQL, permisos, auditoría, `ia_herramienta`, `ia_accion_pendiente`, `tarea_async`,
worker, integración con Telegram y portal. **No duplicar funcionalidades existentes. No crear
tablas o funciones nuevas si el mecanismo ya existe. No reemplazar una implementación existente
sin justificarlo.**

Ante una inconsistencia entre el plan y el código real, no resolverla con una suposición
silenciosa: clasificarla (`BLOCKER`, `HIGH_RISK`, `UNCERTAINTY`, `NON_BLOCKING`), indicar qué se
encontró, dónde, por qué afecta, qué alternativas hay y cuál se recomienda. Si puede provocar un
cambio arquitectónico, detener esa parte y pedir resolución.
