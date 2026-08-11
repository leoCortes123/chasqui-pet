# IMPLEMENTACIÓN DEL PLAN DE COMPLEMENTACIÓN — CHASQUI IA

## Objetivo

Implementar progresivamente el plan de expansión de capacidades del asistente conversacional de Chasqui Pet.

El objetivo es ampliar las capacidades de "Habla con Chasqui" sin romper la arquitectura existente, manteniendo PostgreSQL como fuente de verdad y como núcleo de la lógica de negocio.

El plan funcional de referencia se encuentra en:

`plan_complementacion_asistente_chasqui.md`

Debes tratar ese documento como especificación funcional inicial, pero NO asumir que todo lo indicado allí debe crearse desde cero.

---

# 1. REGLAS ARQUITECTÓNICAS OBLIGATORIAS

Debes respetar estrictamente las siguientes reglas:

### C6.5 — Autorización SQL

Toda función de negocio debe comenzar validando autorización mediante:

`PERFORM exigir_permiso(p_actor_id, modulo.accion);`

No debes trasladar autorización al agente, bot, worker o código de aplicación cuando corresponda a una operación de negocio.

### C6.9 — Confirmación humana

La IA nunca ejecuta directamente una operación de escritura.

El flujo obligatorio para una escritura es:

IA
→ herramienta de preparación
→ propuesta estructurada
→ `ia_accion_pendiente`
→ tarjeta Telegram
→ `[Confirmar]` / `[Cancelar]`
→ ejecución SQL
→ auditoría

La IA puede preparar la operación, pero la mutación real requiere confirmación humana explícita.

### C6.12 — Lógica de negocio en PostgreSQL

Toda lógica de negocio debe permanecer en PostgreSQL.

El bot, n8n y el worker deben limitarse a:

* recibir eventos;
* despachar operaciones;
* transportar datos;
* consumir resultados;
* presentar respuestas.

No debes introducir lógica de negocio duplicada en TypeScript, Python, n8n u otra capa.

### C6.8 — Procesamiento asíncrono

Las operaciones pesadas o las notificaciones externas deben utilizar `tarea_async` y ser procesadas por el worker.

No conviertas al bot en un ejecutor de procesos pesados.

---

# 2. REGLA FUNDAMENTAL: INSPECCIONAR ANTES DE MODIFICAR

Antes de implementar cualquier fase debes inspeccionar la implementación existente.

Debes localizar y comprender, como mínimo:

* esquema PostgreSQL;
* tablas relacionadas con la funcionalidad;
* funciones SQL existentes;
* permisos;
* auditoría;
* `ia_herramienta`;
* `ia_accion_pendiente`;
* `tarea_async`;
* worker;
* integración Telegram;
* flujo de interpretación de lenguaje natural;
* tarjetas y botones de confirmación;
* Portal Web cuando corresponda.

También debes comprobar si ya existen funciones, herramientas o flujos equivalentes a los requeridos por la fase.

NO dupliques funcionalidades existentes.

NO crees tablas o funciones nuevas si la arquitectura existente ya proporciona el mecanismo necesario.

NO reemplaces una implementación existente sin justificarlo.

---

# 3. CONTROL DE INCERTIDUMBRE

Si encuentras una inconsistencia entre:

* el plan;
* el esquema actual;
* las funciones existentes;
* los contratos existentes;
* los agentes;
* los permisos;
* el worker;
* Telegram;
* el Portal Web;

NO debes resolverla mediante una suposición silenciosa.

Clasifica la situación como:

* `BLOCKER`
* `HIGH_RISK`
* `UNCERTAINTY`
* `NON_BLOCKING`

Para cada incertidumbre indica:

1. qué encontraste;
2. dónde lo encontraste;
3. por qué afecta la implementación;
4. qué alternativas existen;
5. cuál recomiendas.

Si la incertidumbre puede provocar una modificación arquitectónica, DETÉN la implementación de esa parte y solicita resolución.

---

# 4. ALCANCE

Debes ejecutar únicamente la fase asignada.

No debes:

* implementar fases futuras;
* realizar refactors generales;
* cambiar arquitectura;
* modificar funcionalidades no relacionadas;
* introducir dependencias innecesarias;
* modificar contratos existentes sin justificación.

Si durante la implementación descubres que otra fase es necesaria como dependencia, documenta la dependencia antes de implementarla.

---

# 5. IMPLEMENTACIÓN

Para la fase asignada debes:

1. analizar dependencias;
2. localizar implementaciones existentes;
3. diseñar la solución compatible con la arquitectura;
4. implementar únicamente lo necesario;
5. aplicar autorización;
6. aplicar confirmación humana cuando corresponda;
7. aplicar auditoría;
8. aplicar idempotencia cuando corresponda;
9. aplicar transacciones atómicas;
10. utilizar `tarea_async` cuando corresponda;
11. integrar con Telegram/Portal/worker únicamente donde sea necesario.

---

# 6. PRUEBAS

Una fase NO se considera terminada porque el código compile o porque las funciones existan.

Debes ejecutar pruebas que demuestren el comportamiento real.

Como mínimo debes comprobar:

* caso exitoso;
* datos inválidos;
* permisos insuficientes;
* ausencia de datos;
* duplicación/idempotencia cuando corresponda;
* rollback ante error;
* auditoría;
* confirmación humana para escrituras;
* respuesta correcta al usuario;
* integración con los componentes involucrados.

Las pruebas deben utilizar datos representativos y no deben destruir información real.

---

# 7. CRITERIO DE FINALIZACIÓN

Una fase solamente puede marcarse como completada cuando:

[ ] La funcionalidad está implementada.
[ ] La implementación respeta la arquitectura existente.
[ ] No existen BLOCKER abiertos.
[ ] Las incertidumbres relevantes fueron resueltas.
[ ] Las funciones SQL tienen autorización.
[ ] Las escrituras pasan por confirmación humana.
[ ] Las operaciones necesarias tienen auditoría.
[ ] Las operaciones pesadas utilizan `tarea_async`.
[ ] Las pruebas principales fueron ejecutadas.
[ ] Los casos de error fueron probados.
[ ] No se introdujeron cambios fuera del alcance.
[ ] La integración correspondiente fue verificada.
[ ] Existe evidencia de las pruebas realizadas.

---

# 8. REPORTE OBLIGATORIO AL FINAL

Al finalizar debes entregar:

## Resumen

Qué se implementó.

## Archivos modificados

Lista exacta de archivos modificados.

## Base de datos

Funciones, tablas, índices, permisos, triggers o migraciones creados/modificados.

## Integraciones

Qué se modificó en bot, worker, Telegram, Portal o n8n.

## Pruebas ejecutadas

Indicar:

* prueba;
* resultado esperado;
* resultado obtenido;
* PASS/FAIL.

## Incertidumbres

Listado de cualquier incertidumbre restante.

## Riesgos

Problemas potenciales detectados.

## Dependencias

Qué necesita estar disponible para probar completamente la funcionalidad.

## Estado

Uno de:

`COMPLETED`
`COMPLETED_WITH_WARNINGS`
`BLOCKED`

No marques `COMPLETED` si existe un bloqueo funcional real.

---

# 9. ACTUALIZACIÓN DE STRICTCONTEXT

Antes de comenzar:

`get_task("<TASK_ID>")`

y:

`get_agent_context("<AGENT_ID>")`

Debes verificar el contexto específico del agente y de la tarea antes de modificar código.

Al finalizar:

* actualizar el estado de la tarea en `.strictcontext.db`;
* actualizar el estado correspondiente en el plan;
* registrar las evidencias relevantes.

No marques una tarea como completada únicamente porque el código fue escrito.

---

# 10. ORDEN DE EJECUCIÓN

El orden definido es:

### Fase 1

`asistente-f1-pacientes-duenos` — ✅ **COMPLETADA** (ver reporte: `docs/reporte-fase1-pacientes-duenos.md`)

### Fase 2

`asistente-f2-borrador-consulta`

### Fase 3

`asistente-f3-despacho-recetas`

### Fase 4

`asistente-f4-paquetes-cobros`

### Fase 5

`asistente-f5-avisos-duenos`

### Fase 6

`asistente-f6-metricas-analytics`

No avances automáticamente a la siguiente fase.

Cada fase debe terminar con su propio reporte y validación.

---

# 11. ESPECIFICACIÓN FUNCIONAL

Utiliza como fuente funcional el archivo:

`plan_complementacion_asistente_chasqui.md`

Debes conservar sus objetivos y restricciones.

Sin embargo, antes de implementar cada punto debes comprobar cómo encaja con la arquitectura real existente.

En particular:

## Fase 1

Implementar:

`preparar_alta_paciente`

y:

`ia_alta_paciente_borrador`

Debe permitir estructurar los datos de paciente y propietario y producir una propuesta de alta que requiera confirmación humana.

Debe comprobarse auditoría.

## Fase 2

Implementar:

`preparar_consulta_clinica`

Debe producir un borrador de consulta asociado al paciente.

La consulta no puede considerarse cerrada/finalizada hasta que el veterinario realice la firma requerida.

Debe existir revisión antes del cierre.

## Fase 3

Implementar:

`despachar_receta_multiple`

La resolución de inventario debe ser atómica.

Debe aplicar FEFO cuando la información disponible lo permita.

Debe probarse:

* múltiples productos;
* múltiples lotes;
* cantidades parciales;
* vencimientos;
* inventario insuficiente;
* rollback;
* confirmación;
* auditoría.

## Fase 4

Implementar:

`cargar_paquete_servicios`

y:

`aplicar_descuento_asistido`

Los descuentos deben estar sujetos a permisos.

La operación económica debe respetar el modelo append-only existente.

La propuesta debe mostrar claramente subtotal, descuento y total antes de confirmar.

## Fase 5

Implementar:

`preparar_aviso_dueno`

Las notificaciones externas deben procesarse mediante `tarea_async` cuando corresponda.

Debe existir vista previa y confirmación.

Debe validarse el consentimiento requerido para protección de datos.

## Fase 6

Implementar herramientas de solo lectura:

`analizar_ocupacion`

`analizar_rendimiento_medico`

`analizar_rentabilidad_lotes`

Los resultados deben poder presentarse de forma resumida en Telegram y exportarse a CSV.

Las consultas analíticas NO deben introducir mutaciones de negocio.

---

# 12. REGLA FINAL

Tu prioridad no es "hacer que el plan parezca implementado".

Tu prioridad es que cada capacidad quede:

ARQUITECTÓNICAMENTE CORRECTA
+
FUNCIONALMENTE IMPLEMENTADA
+
AUTORIZADA
+
AUDITADA
+
IDEMPOTENTE CUANDO CORRESPONDA
+
PROBADA
+
INTEGRADA

Si no puedes demostrar alguno de estos puntos, debes indicarlo explícitamente en el reporte.

No ocultes problemas para poder marcar la fase como completada.
