# Plan de incorporación de Chasqui Pet a StrictContext

## Objetivo

Realizar un barrido completo del repositorio actual de Chasqui Pet y registrar en StrictContext todo el conocimiento verificable necesario para que futuros agentes puedan trabajar sobre el proyecto sin depender de archivos Markdown de contexto.

Esta tarea es exclusivamente de **descubrimiento, análisis, clasificación y registro de contexto**.

### Restricción principal

NO implementar funcionalidades nuevas.

NO modificar la arquitectura existente.

NO refactorizar código.

NO corregir problemas encontrados, salvo que una corrección sea estrictamente necesaria para poder ejecutar el proceso de análisis y haya autorización explícita.

NO convertir automáticamente el plan futuro del proyecto en conocimiento de funcionalidades existentes.

El resultado debe representar el estado real del proyecto en el momento del análisis.

---

# 1. Principios de trabajo

Durante todo el proceso deben respetarse estas reglas:

### 1.1 El código es la fuente primaria

Cuando exista una contradicción entre:

- documentación
- plan de desarrollo
- comentarios
- código
- esquema de base de datos

el agente debe registrar la discrepancia y utilizar el código/esquema real como evidencia del estado actual.

No debe corregir silenciosamente la documentación.

### 1.2 Diferenciar estado actual y estado futuro

Toda información encontrada debe clasificarse como:

- `EXISTING`: existe actualmente y puede comprobarse.
- `DECISION`: decisión arquitectónica vigente y verificable.
- `CONVENTION`: patrón repetido en el código.
- `RULE`: comportamiento que debe respetarse.
- `CONSTRAINT`: condición verificable automáticamente.
- `PLANNED`: aparece en documentación/plan pero todavía no existe.
- `UNKNOWN`: no existe evidencia suficiente.

Nunca registrar una funcionalidad planificada como existente.

### 1.3 No inventar contexto

Si una decisión no puede demostrarse mediante el repositorio, documentación o evidencia técnica suficiente:

```text
NO asumir.
NO completar.
NO inferir como hecho.
```

Registrar `UNKNOWN` o una observación pendiente.

### 1.4 Preservar evidencia

Cada elemento importante registrado en StrictContext debe poder relacionarse con una evidencia:

- archivo
- función
- tabla
- migración
- configuración
- test
- documentación
- commit, cuando sea relevante.

El objetivo es poder responder posteriormente:

> ¿Por qué StrictContext considera que esta regla existe?

---

# 2. Fase 0 — Preparación

Antes de analizar el proyecto:

1. Identificar la raíz del repositorio.
2. Identificar estructura de directorios.
3. Identificar stack tecnológico.
4. Identificar archivos de configuración.
5. Identificar migraciones.
6. Identificar scripts.
7. Identificar tests.
8. Identificar documentación existente.
9. Identificar configuración de n8n.
10. Identificar worker.
11. Identificar aplicación web.
12. Identificar código relacionado con Telegram.
13. Identificar cualquier integración externa.

No modificar archivos durante esta fase.

---

# 3. Fase 1 — Inventario físico del proyecto

Crear un inventario del repositorio actual.

Analizar como mínimo:

```text
db/
worker/
web/
n8n/
scripts/
tests/
configuración
documentación
package.json
docker*
.env.example
tsconfig*
configuración de PostgreSQL
configuración de n8n
```

No asumir que estos directorios existen exactamente con esos nombres.

Primero descubrir la estructura real.

Para cada componente registrar:

```text
component
path
technology
responsibility
entry points
dependencies
status
evidence
```

Resultado esperado:

```text
DATABASE
WORKER
TELEGRAM
N8N
WEB
EXTERNAL INTEGRATIONS
TESTING
INFRASTRUCTURE
```

ajustado a la estructura real encontrada.

---

# 4. Fase 2 — Análisis de la base de datos

Esta es una de las fases prioritarias.

Analizar:

- tablas
- columnas
- tipos
- constraints
- índices
- foreign keys
- triggers
- funciones
- procedimientos
- vistas
- migraciones
- enums
- permisos
- auditoría
- tablas append-only
- colas
- estados
- relaciones entre dominios.

Identificar especialmente patrones como:

```text
exigir_permiso()
tiene_permiso()
auditar()
encolar_tarea()
hoy_bogota()
ahora_bogota()
```

o sus equivalentes reales si los nombres difieren.

No asumir que deben existir solamente porque aparecen en la documentación.

Buscar su implementación real.

---

# 5. Fase 3 — Reconstrucción de la arquitectura real

A partir del repositorio construir un modelo de:

```text
componente
    ↓
responsabilidad
    ↓
dependencias
    ↓
flujo de datos
```

Determinar:

- cuál es la fuente de verdad
- dónde vive la lógica de negocio
- cómo se comunican los componentes
- cómo se ejecutan operaciones asíncronas
- cómo se procesan mensajes
- cómo funciona el portal
- cómo se manejan autenticación y autorización
- cómo se manejan errores
- cómo se manejan integraciones externas.

No registrar una arquitectura únicamente porque está descrita en documentación.

Debe comprobarse contra la implementación.

---

# 6. Fase 4 — Identificar patrones repetidos

Buscar patrones que aparezcan repetidamente en el código.

Ejemplos:

```text
funciones SQL que validan permisos
funciones que auditan
operaciones idempotentes
uso de JSONB
patrones de transacción
manejo de errores
callbacks Telegram
FSM
naming conventions
migraciones
manejo de fechas
colas
retries
validaciones
route handlers
componentes Next.js
```

Cada patrón debe incluir:

```text
pattern
evidence
frequency
scope
confidence
```

No convertir un único caso aislado en una convención global.

---

# 7. Fase 5 — Detectar reglas de negocio y reglas técnicas

Buscar reglas existentes en:

- SQL
- constraints
- triggers
- validaciones
- código del worker
- Telegram
- Next.js
- configuración
- tests.

Clasificarlas.

## MUST

Comportamientos obligatorios demostrados por el código.

## MUST_NOT

Comportamientos prohibidos por arquitectura, seguridad o integridad.

## SHOULD

Convenciones fuertes pero no necesariamente absolutas.

## PREFERENCE

Convenciones de estilo o preferencias débiles.

No crear reglas basadas exclusivamente en preferencias del agente.

---

# 8. Fase 6 — Detectar constraints automatizables

Buscar reglas que puedan convertirse posteriormente en validaciones automáticas.

Ejemplos:

```text
imports prohibidos
archivos prohibidos
patrones de código obligatorios
funciones SQL obligatorias
tests obligatorios
operaciones prohibidas
tablas append-only
uso obligatorio de determinadas funciones
```

Clasificar cada constraint como:

```text
BLOCKER
ERROR
WARNING
```

Solo registrar como `BLOCKER` algo cuya violación pueda causar:

- corrupción de datos
- vulnerabilidad de seguridad
- violación arquitectónica crítica
- pérdida de integridad
- comportamiento irreversible peligroso.

No utilizar BLOCKER para convenciones menores.

---

# 9. Fase 7 — Reconstruir las decisiones arquitectónicas

Crear ADRs únicamente para decisiones que expliquen:

> por qué el sistema funciona de determinada manera.

Ejemplos de posibles ADRs a investigar:

- fuente de verdad
- ubicación de lógica de negocio
- separación entre n8n y PostgreSQL
- utilización del worker
- arquitectura Telegram
- modelo de permisos
- auditoría
- idempotencia
- append-only
- manejo temporal
- arquitectura del portal
- integraciones externas.

Antes de registrar cada ADR verificar que existe evidencia.

Cada ADR debe contener:

```text
title
component
pattern
decision_rationale
constraints
status
evidence
confidence
```

No crear un ADR simplemente porque una tecnología está siendo utilizada.

---

# 10. Fase 8 — Reconstruir los agentes

Determinar qué roles de ingeniería serían necesarios para trabajar correctamente sobre el repositorio.

Como punto inicial investigar estos roles:

```text
planner
sql-engineer
telegram-engineer
backend-engineer
frontend-engineer
integration-engineer
reviewer
```

No crear agentes innecesarios.

Para cada agente definir:

```text
name
role
objective
responsibilities
allowed_tools
forbidden_tools
required_skills
review_required
```

El agente debe basarse en las responsabilidades reales encontradas en el proyecto.

---

# 11. Fase 9 — Crear los skills

Construir skills basados en dominios reales del proyecto.

Como candidatos iniciales investigar:

```text
architecture
postgres-business-logic
telegram
worker
nextjs-admin
security
testing
external-integrations
```

No crear un skill si no existe suficiente conocimiento específico que justifique separarlo.

Cada skill debe dividirse en secciones apropiadas:

```text
overview
patterns
anti_patterns
examples
migrations
testing
security
references
```

El contenido debe describir:

1. qué existe
2. cómo funciona
3. cómo debe extenderse
4. qué debe evitarse
5. cómo comprobar cambios.

---

# 12. Fase 10 — Crear relaciones Agent ↔ Skill

Para cada agente determinar los skills necesarios.

Ejemplo conceptual:

```text
sql-engineer
    architecture
    postgres-business-logic
    security
    testing

telegram-engineer
    architecture
    telegram
    postgres-business-logic
    worker
    testing

frontend-engineer
    architecture
    nextjs-admin
    security
    testing
```

No cargar todos los skills a todos los agentes.

El objetivo es minimizar contexto irrelevante.

---

# 13. Fase 11 — Analizar los comandos de desarrollo

A partir del workflow real del proyecto determinar qué operaciones repetitivas deberían convertirse en commands de StrictContext.

Como candidatos:

```text
inspect
plan
implement
test
verify
review
session
session-report
```

Para cada command definir:

```text
name
description
prompt_template
required_context
required_agent
required_skills
validation_requirements
```

No implementar todavía los comandos de ejecución si la herramienta actual no los soporta.

Primero registrar su especificación.

---

# 14. Fase 12 — Separar el plan futuro del estado actual

Leer el plan de desarrollo del proyecto únicamente después de haber terminado el análisis del repositorio.

Comparar:

```text
CURRENT STATE
vs
PLANNED STATE
```

Para cada elemento del plan determinar:

```text
ALREADY_EXISTS
PARTIALLY_EXISTS
DOES_NOT_EXIST
UNKNOWN
```

No registrar tareas futuras como funcionalidades existentes.

Esta fase debe producir una matriz:

```text
planned feature
current implementation
gap
dependencies
required agent
required skills
relevant rules
relevant constraints
```

---

# 15. Fase 13 — Crear las tareas futuras

Una vez finalizado el inventario, transformar el plan de desarrollo en tareas StrictContext.

Mantener la separación entre:

```text
context
```

y:

```text
work to be performed
```

Cada tarea debe contener:

```text
title
description
assigned_agent
required_skills
dependencies
acceptance_criteria
status = PENDING
```

Los criterios de aceptación deben ser verificables.

Evitar criterios vagos como:

```text
"implementar correctamente"
```

Preferir:

```text
"existe la función X"
"existe la tabla Y"
"se verifica permiso Z"
"se registra auditoría"
"se ejecuta prueba A"
"no se modifica comportamiento B"
```

---

# 16. Fase 14 — Poblar StrictContext

Después de completar el análisis, insertar los registros.

Orden obligatorio:

```text
1. Project/context base
2. Architecture decisions
3. Skills
4. Skill sections
5. Rules
6. Constraints
7. Agents
8. Agent-Skill relationships
9. Commands
10. Tasks
```

No crear tareas antes de haber terminado el contexto base.

---

# 17. Fase 15 — Validación del contexto generado

Una vez poblada la BD, NO asumir que el trabajo terminó.

Ejecutar consultas de validación.

Comprobar:

### Cobertura

¿Los principales componentes del proyecto tienen contexto?

### Consistencia

¿Existen reglas contradictorias?

### Duplicación

¿Hay múltiples reglas que expresan lo mismo?

### Orfandad

¿Hay skills sin agentes?

¿Hay agentes sin skills?

¿Hay tasks sin agente?

¿Hay constraints sin scope?

### Estado

¿Se registraron accidentalmente funcionalidades futuras como existentes?

### Evidencia

¿Las decisiones importantes tienen evidencia?

### Prioridad

¿Las reglas realmente críticas tienen prioridad adecuada?

---

# 18. Fase 16 — Prueba de recuperación

No basta con comprobar que la BD contiene registros.

Probar el mecanismo real que utilizará OpenCode.

Para cada agente ejecutar conceptualmente:

```text
get_agent_context(agent)
```

y comprobar:

```text
agent
+ relevant skills
+ relevant rules
+ relevant constraints
+ relevant ADRs
+ relevant commands
```

El resultado debe ser suficiente para que el agente pueda comenzar una tarea sin necesitar los antiguos archivos Markdown.

---

# 19. Fase 17 — Pruebas de validate_action()

Crear casos deliberadamente problemáticos.

### Caso A

Intentar modificar una tabla protegida.

Esperado:

```text
INVALID
```

### Caso B

Intentar almacenar secretos en código.

Esperado:

```text
INVALID
BLOCKER
```

### Caso C

Intentar implementar lógica de negocio fuera del componente permitido.

Esperado:

```text
INVALID
```

### Caso D

Intentar una operación permitida.

Esperado:

```text
VALID
```

Registrar los resultados.

---

# 20. Fase 18 — Informe final

Al finalizar producir un informe estructurado con:

## Contexto descubierto

- agentes
- skills
- reglas
- constraints
- ADRs
- commands

## Estado del proyecto

- componentes existentes
- funcionalidades existentes
- funcionalidades parciales
- funcionalidades futuras

## Incertidumbres

Lista explícita de todo lo que no pudo determinarse.

## Contradicciones

Documentación vs código.

## Problemas detectados

No corregirlos durante esta misión.

Solamente reportarlos.

## Recomendaciones

Qué debería resolverse antes de comenzar el desarrollo de nuevas funcionalidades.

## Calidad del contexto

Indicar:

```text
coverage
confidence
unknowns
unresolved_conflicts
```

---

# Reglas especiales para esta misión

## Regla 1 — No desarrollar

Esta misión termina cuando StrictContext está correctamente poblado.

No debe terminar con nuevas funcionalidades implementadas.

## Regla 2 — No refactorizar

Encontrar código mejorable no autoriza a modificarlo.

## Regla 3 — No inventar

Cuando no exista evidencia suficiente:

```text
UNKNOWN
```

## Regla 4 — No confundir documentación con realidad

El plan futuro no representa automáticamente el estado actual.

## Regla 5 — Preservar contradicciones

Si existe una contradicción entre documentación y código, registrarla.

No resolverla silenciosamente.

## Regla 6 — Evidencia obligatoria

Las reglas, constraints y ADRs importantes deben poder rastrearse a evidencia.

## Regla 7 — Cambios mínimos

La única modificación permitida al repositorio durante esta misión es la necesaria para registrar el contexto en StrictContext y ejecutar las pruebas necesarias.

---

# Criterios de finalización

La misión se considera terminada solamente cuando:

- [ ] El repositorio fue inspeccionado completamente.
- [ ] La arquitectura real fue documentada.
- [ ] La estructura de PostgreSQL fue analizada.
- [ ] Worker fue analizado.
- [ ] Telegram fue analizado.
- [ ] n8n fue analizado.
- [ ] Next.js fue analizado.
- [ ] Integraciones externas fueron identificadas.
- [ ] Convenciones fueron identificadas.
- [ ] Reglas fueron registradas.
- [ ] Constraints fueron registradas.
- [ ] ADRs fueron registrados.
- [ ] Agentes fueron definidos.
- [ ] Skills fueron definidos.
- [ ] Agent-Skill relationships fueron registradas.
- [ ] Commands fueron definidos.
- [ ] El plan futuro fue separado del estado actual.
- [ ] Las tareas futuras fueron registradas.
- [ ] StrictContext fue poblado.
- [ ] Se comprobó `get_agent_context()`.
- [ ] Se comprobaron reglas críticas.
- [ ] Se comprobó `validate_action()`.
- [ ] Se identificaron contradicciones.
- [ ] Se identificaron incertidumbres.
- [ ] No se implementaron funcionalidades nuevas.
- [ ] No se realizaron refactors.
- [ ] Se generó un informe final.

---

# Resultado esperado

Al terminar esta misión debe ser posible eliminar conceptualmente la dependencia de los antiguos archivos Markdown.

Un agente nuevo debería poder recibir:

```text
"Ejecuta la tarea X"
```

y obtener desde StrictContext:

```text
Task
    ↓
Agent
    ↓
Skills
    ↓
Architecture Decisions
    ↓
Rules
    ↓
Constraints
    ↓
Acceptance Criteria
```

sin necesitar que otro agente le explique manualmente la arquitectura del proyecto.

El objetivo no es almacenar todo el repositorio en StrictContext.

El objetivo es almacenar **el conocimiento necesario para razonar correctamente sobre el repositorio**.