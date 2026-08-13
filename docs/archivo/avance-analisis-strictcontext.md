> **DOCUMENTO ARCHIVADO.** Superado el 12 de agosto de 2026 por `docs/plan-consolidacion-chasqui-pet.md`.
> Corresponde a la herramienta externa StrictContext, ajena a la aplicación.
> Se conserva como referencia histórica; no es la fuente vigente.

---

# Avance — Incorporación de Chasqui Pet a StrictContext

Documento de control para repartir el análisis en varias sesiones (una fase por sesión) y conservar el contexto entre sesiones.

## Objetivo

Registrar en StrictContext todo el conocimiento verificable del repositorio de Chasqui Pet, sin implementar funcionalidades nuevas, sin refactorizar y sin inventar contexto (ver plan: `~/Descargas/Plan de incorporación de Chasqui Pet a StrictContext.md`).

## Restricciones principales

- NO implementar funcionalidades nuevas.
- NO refactorizar código existente.
- NO corregir problemas encontrados (solo reportarlos).
- NO confundir documentación/plan futuro con estado actual.
- Sin evidencia suficiente → registrar `UNKNOWN`.

## Roles de análisis

Jerarquía de agentes especializados usados durante el análisis:

```
project-analyst
       │
       ├── database-analyst
       ├── backend-analyst
       ├── telegram-analyst
       ├── frontend-analyst
       ├── integration-analyst
       └── security-analyst
                │
                ▼
       context-architect
                │
                ▼
       context-reviewer
```

## Estado global

- **Sesión actual**: 19
- **Fase actual**: Fase 18 — Informe final (agente: context-reviewer) (`completada`)
- **Última fecha**: 2026-08-10
- **Próxima sesión**: — (misión completa; StrictContext poblado y validado; pendientes reportados en el informe final, no requieren más fases)

## Tabla maestra de fases

| Fase | Sesión | Agente principal | Agentes de apoyo | Estado | Notas / resumen |
|------|--------|------------------|------------------|--------|-----------------|
| 0 Preparación | 1 | project-analyst | — | completada | Inventario preliminar del repositorio completo |
| 1 Inventario físico | 2 | project-analyst | todos los *-analyst | completada | 8 componentes inventariados; correcciones de conteos; trabajo git desincronizado detectado |
| 2 Análisis base de datos | 3 | database-analyst | — | completada | Esquema completo: 41 tablas, 4 vistas (corrige "0" de Fase 1), 0 enums (text+CHECK), 68 índices, 35 triggers, 282 funciones únicas (310 sentencias); cola, dedup, auditoría, append-only, roles; 4 directivas resueltas |
| 3 Reconstrucción arquitectura real | 4 | project-analyst | backend, telegram, frontend, integration | completada | Arquitectura "PostgreSQL-centric" verificada (no la doc): lógica 100% en 282 funciones SQL; n8n/worker/web son capas delgadas; pipeline Telegram completo (router 040 + despacho modular + acciones JSONB → n8n); cola tarea_async con 11 manejadores y 3 jobs; portal/sesión/authz 3 capas; errores jsonb-ok; DeepSeek solo en worker con confirmación por bot; 2 incertidumbres nuevas (N8N_INTERNAL_URL, editarMensaje sin callsites) |
| 4 Patrones repetidos | 5 | backend-analyst | database-analyst | completada | 27 patrones con evidencia y frecuencia verificadas (grep + lectura directa): firma canónica p_actor_id+p_canal (94 rejas), contrato JSONB {ok,motivo,mensaje} (156/79), auditar x66, RAISE con ERRCODE semántico (20; no P0001 — corregido), ON CONFLICT+UNIQUE parcial (24), triggers en 3 familias (35), normalizar+GENERATED STORED (8), FSM estado_guardar (75), encolar_tarea con clave compuesta (10), stubs de bot+COALESCE (8 archivos), puerta IA de 3 rejas; worker 11 manejadores idénticos sin transacciones; n8n webhook tubería lineal + jobs solo-SQL; web Server Actions uniformes y route handlers de cabecera fija; scripts con preámbulo común. Correcciones a conteos de subagentes (consultar 42→5) | |
| 5 Reglas de negocio y técnicas | 6 | backend-analyst | telegram, frontend, security | completada | 15 MUST, 12 MUST_NOT, 9 SHOULD, 5 PREFERENCE con evidencia path:line; 6 incertidumbres, 5 contradicciones y 5 problemas de seguridad/robustez reportados (SECURITY DEFINER sin search_path, GRANT EXECUTE amplio, interpolación de env sin escapar, kiosco tablet PLANNED, sesión web sólida) |
| 6 Constraints automatizables | 7 | security-analyst | project-analyst | completada | 23 constraints con check automático y remediación: 9 BLOCKER (append-only real, no purgar auditoría/inventario, numeric no-float, advisory lock vs MAX+1, exigir_permiso en toda escritura, rol chasquipet_app, secretos fuera de git, webhook <1s→cola, confirmación explícita en dinero/inventario), 9 ERROR (SECURITY DEFINER sin search_path, nuevo append-only en 090, SQL crudo en web, cabeceras de route handlers, prefijo de callback, rate limit en puertas públicas, contrato de manejadores worker, sin password/HTTP externo, defensa real en tablas inmutables) y 5 WARNING (GRANT EXECUTE amplio, imágenes fijas, N8N_BLOCK_ENV_ACCESS_IN_NODE, auditoría en escrituras, verificación mínima). Sin evidencia de max_complexity ni forbidden_import → no inventados; 6 incertidumbres |
| 7 Decisiones arquitectónicas (ADRs) | 8 | context-architect | project-analyst | completada | 12 ADRs con evidencia verificada (postgres-centric, lógica en SQL, n8n transporte, cola+worker, router Telegram, permisos como datos, auditoría, idempotencia, append-only, manejo temporal, portal delgado, integraciones aisladas); 3 ADRs descartados sin rationale demostrable; incertidumbres conservadas |
| 8 Reconstruir agentes | 9 | context-architect | — | completada | 7 agentes de ingeniería definidos sobre responsabilidades reales (planner, sql-engineer, telegram-engineer, backend-engineer, frontend-engineer, integration-engineer, reviewer): los 7 candidatos del plan §10 con evidencia; sin agentes añadidos de más; mapeo a la tabla `agents` de StrictContext para Fase 14; 5 incertidumbres (frontera sql↔telegram, fusión posible integration↔backend, destino de los 9 agentes de análisis, herramientas conceptuales, alcance IA sin código commiteado) |
| 9 Crear skills | 10 | context-architect | — | completada | 8 skills definidos con contenido por secciones (los 8 candidatos del plan §11, ninguno descartado ni añadido): architecture, postgres-business-logic, telegram, worker, nextjs-admin, security, testing, external-integrations; cada uno con qué-existe/cómo-funciona/cómo-extender/qué-evitar/cómo-comprobar + evidencia; secciones del plan mapeadas a las columnas de skills/skill_sections para Fase 14; incertidumbres sobre registro real (Fase 14), frontera sql↔telegram, testing automatizado, deuda reportada como no-normativa |
| 10 Relaciones Agent ↔ Skill | 11 | context-architect | — | completada | 7 agentes × skills mapeados minimizando contexto irrelevante (ningún agente carga los 8, ninguno carga 0); todos los skills tienen al menos un dueño (sin órfanos); seguridad y testing en todos los agentes (transversales); frontera sql↔telegram resuelta sobre el prefijo de módulo del bot (`bot_*` → telegram-engineer) con la evidencia de 058 (auth mezcla dominio+bot) y el orquestador COALESCE de 078; 5 incertidumbres (esquema de registro de la relación para Fase 14, destino de los 9 agentes de análisis, solapamiento sql↔telegram sin prefijo, autoridad de planner sin skills de dominio, build de skills por agente) |
| 11 Comandos de desarrollo | 12 | context-architect | — | completada | 8 commands especificados desde el workflow real (los 8 candidatos del plan §13, ninguno añadido ni descartado): inspect, plan, implement, test, verify, review, session, session-report; cada uno con name/description/prompt_template/required_context/required_agent/required_skills/validation_requirements; workflow fuente = ciclos por etapa de git (pasos 1–8), verificación mínima C6.23 y protocolo de sesión del avance; desajuste encontrado: esquema real `commands` (steps/preconditions/expected_output/rollback_steps) vs campos del plan §13 (prompt_template/required_context/required_skills/validation_requirements) → mapeo para Fase 14; runtime solo con get_command_steps → solo especificación, sin implementar ejecución (plan §13: "no implementar todavía") |
| 12 Separar plan futuro del estado actual | 13 | context-architect | project-analyst | completada | Matriz de 19 elementos del plan futuro (chasquipet.md §3 + plan_ejecucion F1/F2 sesiones 1–20) vs estado actual: MVP completo; PARTIALLY_EXISTS citas/disponibilidad (tablas 050:126-170 sin lógica/UI) y kiosco tablet (canal en CHECK 030:64); DOES_NOT_EXIST presupuestos, DIAN/Factus, carnet digital, canal cliente (modo dueño), marketing, reportes F1/F2 y WhatsApp (S20 ordena solo documentar); UNKNOWN/EXCLUIDO medicamentos de control especial y features §3 sin detalle. 5 contradicciones plan-vs-código identificadas (P0001 vs ERRCODEs semánticos, stubs+COALESCE vs editar router/020, SQL directo en worker vs funciones SQL, rutas web fuera de (portal), /reservar como comando vs callbacks) + 1 confirmación (siguiente_numero_recibo con advisory lock). Agentes/skills/rules/constraints por sesión mapeados. 5 incertidumbres nuevas (webhook Factus S8, dueño de PDF carnet, reportes, features §3 sin plan, kiosco) |
| 13 Crear tareas futuras | 14 | context-architect | — | completada | 20 tareas futuras especificadas (19 de implementación alineadas a las sesiones F1/F2 + 1 de documentación WhatsApp); cada una con title/description/assigned_agent/required_skills/dependencies/acceptance_criteria verificables (criterio C6.23) y status PENDING; las 5 contradicciones del plan vs código de Fase 12 integradas en las descripciones para no heredar errores; decisión tomada para F1-S8 (webhook Factus → frontend-engineer) y F2-S14 (PDF carnet → backend-engineer); excluidas como NO-tarea: features §3 sin detalle, kiosco tablet, medicamentos de control especial. Registro en BD queda para Fase 14 (paso 10) |
| 14 Poblar StrictContext | 15 | context-architect | — | completada | BD poblada (.strictcontext.db): 12 ADRs, 8 skills + 64 skill_sections, 41 rules (15 MUST / 12 MUST_NOT / 9 SHOULD / 5 PREFERENCE→SHOULD prio 90), 23 constraints C6, 7 agents de ingeniería + tabla agent_skills (26 filas, matriz Fase 10), 8 commands, 20 tasks PENDING; verificaciones de consistencia OK (0 skills sin secciones, 0 deps inválidas, conteos por tipo/severidad correctos) |
| 15 Validación del contexto | 16 | context-reviewer | — | completada | Validación SQL del contenido poblado: cobertura completa (16/8/64/41/23/12/8/20/26 verificados), 0 contradicciones, 0 duplicados (condition/action), 0 orfandad (skills/tasks/constraints/deps), 0 estado futuro como existente, evidencia path:line en 41 rules y 23 constraints, prioridades coherentes; sanity get_agent_context OK (sql-engineer, frontend-engineer); 4 incertidumbres menores (required_agent commands, check_sql NULL, active de 9 analistas, tools conceptuales) |
| 16 Prueba de recuperación | 17 | context-reviewer | — | completada | get_agent_context OK en los 7 agentes de trabajo (agent + 41 rules + 23 constraints + instruction); get_skill/get_task/get_command_steps hidratan OK; 2 hallazgos: (1) validate_action() se rompe: C6.13.check_pattern tiene `**` (regex inválida "multiple repeat") y aborta toda la validación, (2) get_agent_context NO devuelve skills/ADRs/commands (el runtime solo devuelve agent+reglas+constraints) — el plan §18 los pide, gap reportado; commands.required_agent NULL en 8/8 |
| 17 Pruebas de validate_action() | 18 | context-reviewer | — | completada | Precondición de Fase 16 satisfecha: C6.13.check_pattern arreglado (`**`→`.*`), 23/23 regex compilan, validate_action ya no lanza. Casos A–D ejecutados sobre el MCP real: A (tabla protegida)→INVALID vía rule 16 no_editar_append; B (secretos)→INVALID+BLOCKER vía C6.7 (solo por frase literal); C (lógica fuera del componente)→INVALID vía C6.16; D (operación permitida: función canónica, route handler, callback con prefijo)→VALID. Confirmado además que C6.13 sí detecta force-static. 5 hallazgos de calidad de check_pattern reportados sin corregir (misión no refactoriza): C6.1/C6.2 no detectan DELETE literal (check_sql en patrón / lenguaje natural), C6.16 falso positivo por alternancia sin agrupar, C6.7 no casa tokens reales (Telegram `:`/sk-), C6.10 inexacto, runtime casa por details libre sin check_sql (NULL 23/23) |
| 18 Informe final | 19 | context-reviewer | project-analyst | completada | Informe final §20 verificado en vivo (conteos BD + get_agent_context + validate_action A–D con B realista como falso negativo reproducido). Contexto descubierto completo: 16 agents (9 análisis + 7 trabajo), 8 skills/64 secciones, 41 rules, 23 constraints (9/9/5), 12 ADR, 8 commands, 20 tasks PENDING, 26 agent_skills. Estado del proyecto: MVP completo + 2 parciales (citas, kiosco) + 20 futuras. 20+ incertidumbres, 12 contradicciones y ~10 problemas reportados sin corregir. Recomendaciones: commitear trabajo no versionado, cerrar deuda seguridad (search_path, N8N env, GRANT, scripts) y mejorar check_pattern antes de desarrollar F1. Calidad: coverage ALTA, confidence ALTA (runtime MEDIA), unknowns no-bloqueantes, conflicts conservadas. Misión completa |

Estados posibles: `pendiente`, `en_progreso`, `completada`, `bloqueada`.

## Protocolo para iniciar/continuar una sesión

1. Leer este archivo y el plan completo.
2. Verificar en la tabla maestra cuál es la próxima fase `pendiente`.
3. Actualizar `Estado global` (fase `en_progreso`) antes de empezar.
4. Ejecutar la fase con el agente principal indicado.
5. Al terminar, volcar hallazgos en la sección de la fase correspondiente.
6. Actualizar la tabla maestra (estado = `completada`) y el `Estado global`.
7. No avanzar a la siguiente fase hasta que la fase actual esté registrada.

## Registro por fase

### Fase 0 — Preparación

- **Fecha / sesión**: 2026-08-09 / sesión 1
- **Agente**: project-analyst
- **Hallazgos del inventario preliminar**:
  - **Raíz del repositorio**: `/mnt/datos/Programacion/chasquiPet`, branch `master`, 9 commits (etapas 1–8 del build).
  - **Stack tecnológico**: PostgreSQL 16 (alpine) como fuente de verdad y dueña de la lógica de negocio; n8n 2.31.5 (versión fija) como orquestador de webhooks/jobs; Node.js 22 para worker (JS ESM, deps: `pg`, `openai`) y web (Next.js 16 App Router, React 19, TypeScript 5.9 strict); Telegram Bot API por webhook; Caddy 2 (proxy); cloudflared (túnel HTTPS); DeepSeek API (compatible OpenAI) como única IA externa.
  - **Configuración**: `docker-compose.yml` (8 servicios: db, n8n, worker, web, backup, proxy, + cloudflared y registrador bajo perfil `local`), `.env.example` (~30 variables), `web/next.config.ts` (output `standalone`, `pg` como `serverExternalPackages`), `web/tsconfig.json`, `proxy/Caddyfile`, Dockerfiles de web y worker (node:22-alpine, TZ Bogotá, no root).
  - **Migraciones**: `db/migrations/` — 27 archivos con prefijo alfabético 000→900 (000_n8n_db.sh, 010_base.sql, 020_identidad.sql, 030_turnos.sql, 035_aviso_turno.sql, 040_bot_turnos.sql, 045_inventario.sql, 046_bot_inventario.sql, 050_pacientes.sql, 056_bot_clinico.sql, 058_auth_web.sql, 060_cobro.sql, 066_bot_cobro.sql, 070_compras.sql, 076_bot_compras.sql, 077_portal_enlace.sql, 078_chasqui_ia.sql, 080_reportes.sql, 085_admin.sql, 088_mantenimiento.sql, 090_grants.sql, 100_seed_roles.sql, 110_seed_operativo.sql, 900_superadmin.sh). Los `.sh` y `.sql` conviven en `/docker-entrypoint-initdb.d` (solo primera inicialización).
  - **Scripts**: `scripts/` — 7 scripts (backup.sh con retención de 14 días, cargar-demo.sh, configurar-bot.sh, crear-superadmin.sh, importar-n8n.sh, registrar-publico.sh, restaurar.sh).
  - **Tests**: NO existen tests automatizados en el proyecto (los archivos `*test*` hallados pertenecen a `vendor/` de `.strictcontext`, no al sistema).
  - **Documentación existente**: `chasquipet.md` (especificación del producto, 24 KB), `README.md`, `web/README.md`, `worker/README.md`, `docs/` (modelo-datos.md, guia-operacion.md, reporte-tecnico.md, datos-actuales.md, plan_ejecucion_chasquipet.md).
  - **n8n**: `n8n/workflows/` — 4 workflows versionados: 01-telegram-webhook.json (5 nodos: webhook→postgres→code→telegram→postgres), 02-job-turnos.json (cada minuto), 03-job-inventario.json (diario 7:30), 04-job-mantenimiento.json (diario 3:15).
  - **Worker**: `worker/src/` — index.js (ciclo cola), telegram.js (fetch nativo, sin librerías), log.js y 13 manejadores en `worker/src/tareas/` que procesan la cola `tarea_async` (reclamar_tareas, fallar_tarea, completar_tarea, rescatar_tareas_colgadas viven en SQL).
  - **Web**: `web/src/` — App Router: pantalla pública de turnos (SSE + polling), `entrar` (auth por código de 6 dígitos vía Telegram), portal `(portal)` (panel, consultas, pacientes, consulta con historia clínica, inventario/catálogo, compras, reportes, admin/usuarios/config/auditoría/tareas). `lib/` (db, pantalla, notificaciones, sesion, clinico, reportes, formato). Solo hace fetch hacia sus propias rutas API (sin llamadas HTTP externas).
  - **Telegram**: distribuido entre n8n (webhook 01), worker (telegram.js + manejadores que envían/editan mensajes) y SQL (migraciones 040/046/056/066/076/058; auth web en 058).
  - **Integraciones externas**: Telegram Bot API (entrada webhook + salidas del worker), DeepSeek API vía worker (migración 078_chasqui_ia + tarea `chasqui_responder`), Cloudflare Tunnel (infraestructura). No existe facturación electrónica DIAN (advertencia legal en README).
- **Evidencia clave**:
  - `README.md` (estado, funcionalidades, estructura, dónde vive la lógica).
  - `docker-compose.yml` (servicios, red `chasquipet`, volumes `pgdata`/`n8ndata`/`caddydata`, perfiles).
  - `.env.example` (todas las variables y sus contratos).
  - `db/migrations/` orden alfabético; `090_grants.sql` (roles `chasquipet_app` y `chasquipet_lectura`, append-only real).
  - `web/README.md`, `worker/README.md` (contratos y reparto de responsabilidades).
  - `n8n/workflows/*.json` (nodos y argumentos de cada workflow).
  - `proxy/Caddyfile` (enrutado `/webhook/*` → n8n, resto → web).
- **Incertidumbres**:
  - El contenido del `.env` real no se revisa (secretos): solo `.env.example` como evidencia.
  - No hay tests automatizados; habrá que confirmar en Fase 1 si existe estrategia de verificación alternativa (p.ej. pruebas con `psql` contra las funciones SQL).

### Fase 1 — Inventario físico del proyecto

- **Fecha / sesión**: 2026-08-09 / sesión 2
- **Agente**: project-analyst (con apoyo de database-analyst, backend-analyst, telegram-analyst, frontend-analyst, integration-analyst)
- **Componentes identificados**:

#### DATABASE

- **component**: PostgreSQL 16 — fuente única de verdad y dueña de la lógica de negocio.
- **path**: `db/migrations/` (24 archivos: 22 `.sql` + 2 `.sh`), `db/demo/` (5 SQL), `db/seeds/` (**vacío**).
- **technology**: PostgreSQL 16-alpine; extensiones `pgcrypto`, `pg_trgm`, `unaccent`; 41 tablas, 282 funciones únicas, 35 triggers, 68 índices, 0 vistas, 0 enums (estados como columnas `text`).
- **responsibility**: esquema completo, reglas de negocio, validaciones, permisos, auditoría, cola de tareas, deduplicación Telegram, reportes y seeds.
- **entry points**: `/docker-entrypoint-initdb.d` (solo primera inicialización, orden alfabético `000`→`900`; los `.sh` crean la BD n8n y las contraseñas de los roles de app). Rol `chasquipet_app` (aplicación) y `chasquipet_lectura` (solo lectura) definidos en `090_grants.sql` con append-only real (REVOKE UPDATE/DELETE/TRUNCATE sobre `evento_auditoria`, `movimiento_inventario`, `pago`, `descuento`).
- **dependencies**: ninguna externa; depende de Postgres 16 y de las variables del `.env`.
- **status**: EXISTENTE (completo; pendiente de análisis de schema en Fase 2).
- **evidence**: `db/migrations/` (010_base.sql: colas + telegram_update; 020_identidad.sql: permisos; 090_grants.sql: roles append-only).

#### WORKER

- **component**: Worker de tareas asíncronas (Node.js).
- **path**: `worker/` — `src/index.js`, `src/log.js`, `src/telegram.js`, `src/tareas/index.js` + **11 manejadores** (no 13: la Fase 0 sobreestimó): `abrir_cuenta_turno`, `agregar_linea_cuenta`, `alertas_inventario`, `chasqui_responder`, `enviar_recibo`, `enviar_resumen_consulta`, `notificar_inicio_sesion`, `notificar_superadmin`, `notificar_turno_llamado`, `notificar_turnos_proximos`, `recordar_llamado_vencido`.
- **technology**: Node 22 ESM (`"type":"module"`), deps `pg ^8.13.1` y `openai ^7.4.0` (solo para DeepSeek); Dockerfile `node:22-alpine`, `USER node`, TZ Bogotá.
- **responsibility**: drenar la cola `tarea_async` (`reclamar_tareas`/`completar_tarea`/`fallar_tarea`/`rescatar_tareas_colgadas`), enviar mensajes de Telegram diferidos y responder con la IA DeepSeek. Sin estado en memoria; réplicas sin coordinación.
- **entry points**: `worker/src/index.js` (entrypoint); env `DATABASE_URL`, `TELEGRAM_BOT_TOKEN`, `WORKER_*`.
- **dependencies**: Postgres (DB), Telegram Bot API (salidas), DeepSeek (IA, via SDK OpenAI). No recibe webhooks.
- **status**: EXISTENTE — con **evidencia de trabajo no commiteado**: `src/tareas/chasqui_responder.js` está `untracked`, y `index.js`, `package.json`, `package-lock.json` modificados sin commit.
- **evidence**: `worker/src/index.js`, `worker/src/tareas/*.js`, `worker/README.md`.

#### TELEGRAM

- **component**: Implementación del bot (distribuida: n8n + SQL + worker + web).
- **path**: difuso — webhook en `n8n/workflows/01-telegram-webhook.json`; lógica en SQL (`040_bot_turnos.sql` enrutador `bot_manejar_update`, más `046/056/058/066/076/077/078`); salidas en `worker/src/telegram.js`; login en `058_auth_web.sql` + `web/src/app/entrar/`; registro de webhook en `scripts/configurar-bot.sh` y `scripts/registrar-publico.sh`.
- **technology**: Telegram Bot API (webhook + fetch nativo sin librerías en el worker), n8n como receptor HTTP, SQL como árbol de decisión/estado conversacional (`conversacion_estado`).
- **responsibility**: recibir updates (>1 s, respuesta en línea vía n8n), resolver perfil/permisos, menús y callbacks, notificaciones push, login al portal, chat IA.
- **entry points**: webhook HTTPS `https://api.telegram.org/bot<token>/...` → Caddy `/webhook/*` → n8n.
- **dependencies**: Telegram Bot API, Postgres (lógica), worker (envíos diferidos).
- **status**: EXISTENTE; el flujo completo está verificado end-to-end. El worker usa `editMessageText` pero no tiene callsites activos en los manejadores.
- **evidence**: `n8n/workflows/01-telegram-webhook.json`, `worker/src/telegram.js`, `db/migrations/040_bot_turnos.sql:258`, `058_auth_web.sql`.

#### N8N

- **component**: Orquestador de webhooks y jobs.
- **path**: `n8n/workflows/` (4 JSON versionados): `01-telegram-webhook.json` (5 nodos: webhook→postgres→code→telegram→postgres), `02-job-turnos.json` (cron 1 min), `03-job-inventario.json` (cron 7:30), `04-job-mantenimiento.json` (cron 3:15).
- **technology**: n8n `2.31.5` (versión fija), base n8n separada en el mismo Postgres, credencial `chasquipet-postgres`.
- **responsibility**: capa fina de transporte: el webhook contesta 200 al instante, llama 2 funciones SQL (dedup + resolución) y traduce las `acciones` JSONB a llamadas REST de la Bot API. Los jobs solo encolan tareas o llaman funciones SQL. **No guarda estado de negocio ni lógica.**
- **entry points**: docker-compose `n8n` (puerto 5679 local); import con `scripts/importar-n8n.sh`.
- **dependencies**: Postgres (negocio y su propia base n8n), Telegram Bot API (nodo httpRequest), `.env` (`TELEGRAM_BOT_TOKEN` vía `$env`).
- **status**: EXISTENTE. Incertidumbre menor: si `bot_manejar_update` devuelve `acciones: []`, el nodo "Marcar procesado" podría no ejecutarse y el update quedar `procesado=false` (no afecta dedup).
- **evidence**: `n8n/workflows/*.json`, `docker-compose.yml:73`, `scripts/importar-n8n.sh`.

#### WEB

- **component**: Portal administrativo + pantalla pública de turnos.
- **path**: `web/` — `src/app/` (App Router), `src/lib/` (7 módulos).
- **technology**: Next.js 16 App Router, React 19, TypeScript 5.9 (strict), `pg 8.16.3` directo (sin ORM), `output: standalone`, `serverExternalPackages: ['pg']`. Deps: solo `next`, `react`, `react-dom`, `pg`.
- **responsibility**: salud, pantalla SSE (con fallback a polling 5 s), login por código de 6 dígitos vía Telegram, portal (panel, consultas, pacientes, consulta clínica, inventario/catálogo, compras, reportes con CSV, admin: usuarios/config/auditoría/tareas). **Sin llamadas HTTP externas**: los fetch son solo a rutas API propias; la única URL externa generada es el deep-link `t.me/...?start=web-<id>`.
- **entry points**: `web/Dockerfile` (standalone, `CMD node server.js`); rutas `api/*`, Server Actions (`'use server'` en consulta/inventario/admin), SSE.
- **dependencies**: Postgres (pool + `LISTEN` dedicado vía `DATABASE_URL_DIRECTA`), Telegram solo para login (deep-link, no fetch).
- **status**: EXISTENTE. Excepciones al "solo llama funciones SQL": SQL crudo inline en `lib/clinico.ts:154` (`consultasRecientes`) y `admin/config/page.tsx:42`.
- **evidence**: `web/src/**`, `web/next.config.ts`, `web/README.md`, `web/tsconfig.json`, `web/Dockerfile`.

#### EXTERNAL INTEGRATIONS

- **Telegram Bot API**: IMPLEMENTADA — entrada por webhook (n8n), salida por worker (`worker/src/telegram.js`, fetch nativo, manejo 429/403/400) y por n8n (nodo HTTP, `neverError`). Token nunca versionado (solo `$env`).
- **DeepSeek (compatible OpenAI)**: IMPLEMENTADA — única IA; solo el worker (`worker/src/tareas/chasqui_responder.js`, SDK `openai`, base `api.deepseek.com`, modelo configurable en `config.ia_modelo`, seed `deepseek-v4-pro`). n8n y web nunca llaman al modelo. `DEEPSEEK_API_KEY` vacía = el bot avisa y sigue.
- **Cloudflare Tunnel**: IMPLEMENTADA (infraestructura) — `cloudflared` + `registrador` en perfil `local`; publica el proxy Caddy; TLS externo, HTTP interno.
- **Facturación electrónica DIAN / Factus**: NO IMPLEMENTADA — solo planes en `docs/plan_ejecucion_chasquipet.md` (migración propuesta `130_dian_factus.sql` inexistente). El recibo es declarado documento interno no fiscal (`110_seed_operativo.sql:23`).
- **Otras (pasarelas de pago, medidas etc.)**: sin evidencia de código.
- **status**: según lo anterior.
- **evidence**: `worker/src/tareas/chasqui_responder.js`, `docker-compose.yml:159-166,275-317`, `.env.example:196,206,210`, `docs/reporte-tecnico.md:394`.

#### TESTING

- **component**: estrategia de verificación.
- **path**: ninguno (`web/` no tiene tests, `worker/` no tiene tests, no hay `.github/` ni CI/CD, no hay carpetas `test/`/`spec/`; los `*test*` hallados pertenecen a `.strictcontext/vendor/`).
- ****status**: NO EXISTEN tests automatizados. Estrategia de verificación real: `web` tiene `npm run typecheck` (`tsc --noEmit`) y `npm run build`; `worker` tiene `npm run check` (`node --check`); la verificación funcional es manual con `scripts/cargar-demo.sh` + `db/demo/` y consultas `psql` contra las funciones SQL (incertidumbre de la Fase 0 **respuesta**).
- **evidence**: `web/package.json:13-14`, `worker/package.json:13`, `docs/reporte-tecnico.md:423` ("Sin pruebas automatizadas (sin tests, sin CI)"), `db/demo/*.sql`.

#### INFRASTRUCTURE

- **component**: orquestación y despliegue.
- **path**: `docker-compose.yml`, `proxy/Caddyfile`, `web/Dockerfile`, `worker/Dockerfile`, `scripts/` (7 scripts), `.env.example` (~35 variables).
- **technology**: Docker Compose (8 servicios: db, n8n, worker, web, backup, proxy + `cloudflared` y `registrador` en perfil `local`), Caddy 2 (proxy), Cloudflare (`cloudflared`), volúmenes `pgdata`/`n8ndata`/`caddydata`, red `chasquipet` bridge.
- **responsibility**: inicialización de BD (migraciones montadas `:ro`), exponer webhook y portal por un solo hostname (Caddy enruta `/webhook/*`→n8n, el resto→web; el editor de n8n NO se publica), backup diario (`backup.sh`, retención 14 días), registro del webhook y `portal_url` (`registrar-publico.sh` en bucle de 60 s).
- **entry points**: `docker compose up -d` (con `COMPOSE_PROFILES=local` por defecto en `.env.example`); gestión manual con `scripts/` (cargar-demo, crear-superadmin, importar-n8n, restaurar, configurar-bot).
- **dependencies**: puertos anfitrión 5433/5679/3100/8081; convive con el sistema Chasqui original en la misma máquina.
- **status**: EXISTENTE.
- **evidence**: `docker-compose.yml`, `proxy/Caddyfile`, `scripts/*.sh`, `.env.example`, `web/worker Dockerfiles`.

- **Incertidumbres**:
  - **Número de migraciones**: la Fase 0 dijo "27 archivos"; el listado real (`ls db/migrations`) tiene **24** (22 SQL + 2 .sh). Contradicción con el propio registro de la Fase 0 → corregir en el registro acumulado.
  - **Número de manejadores del worker**: la Fase 0 dijo "13"; el registro real de `worker/src/tareas/index.js` tiene **11**. Contradicción con el registro de la Fase 0.
  - **Trabajo no commiteado**: `worker/src/tareas/chasqui_responder.js` (untracked) y las migraciones `077_portal_enlace.sql` y `078_chasqui_ia.sql` (untracked) son funcionalidad existente en disco pero fuera del historial git; `git status` además muestra modificaciones en `.env.example`, `README.md`, `docker-compose.yml`, `scripts/configurar-bot.sh` y `web/src/app/entrar/*` sin commit. El repositorio `master` (8c8a989) está 11 cambios por detrás del disco.
  - **Modelo de IA en producción**: el seed usa `deepseek-v4-pro`, el `.env` real no se inspecciona; no se pudo verificar que el nombre del modelo exista en el provider (configurable en `config.ia_modelo`).
  - **`worker/README.md` desactualizado**: documenta 10 manejadores (falta `chasqui_responder`) y referencia `worker/sql/010_aviso_turno.sql` que no existe (la tabla real viene de `db/migrations/035_aviso_turno.sql`).
  - **`TELEGRAM_BOT_USERNAME` y `SUPERADMIN_TELEGRAM_USER_ID`** se inyectan al worker (`docker-compose.yml:154-155`) pero el código del worker no las consume.
  - **`db/seeds/`**: existe pero está vacío; no forma parte del orden de migraciones.
  - **Enums**: no hay tipos enum; los estados son columnas `text` (confirmar convención en Fase 2).
  - **`este` detalle de n8n**: el nodo "Marcar procesado" podría no ejecutarse con `acciones: []` (update quedaría `procesado=false`); no afecta a la deduplicación.

### Fase 2 — Análisis de la base de datos

- **Fecha / sesión**: 2026-08-09 / sesión 3
- **Agente**: database-analyst
- **Directiva**: investigar, mediante el esquema, migraciones, funciones, triggers y el código que las utiliza, el significado real de cada observación de Fase 1 que toca la base de datos. No asumir ni inventar significado: la evidencia es la migración, la función, el trigger o el call-site. Incertidumbres de Fase 1 investigadas: (1) convención de estados como `text`, (2) propósito de `db/seeds/`, (3) semántica de `telegram_update.procesado`, (4) contrato de `config.ia_modelo` y pares de `config`. Todas resueltas (ver "Directiva: resolución de incertidumbres").
- **Hallazgos** (escapado — la BD no estaba levantada al analizar; todo deriva del esquema en `db/migrations/`):

  **Inventario general** (conteos verificados con grep sobre las migraciones):
  - 41 tablas, **4 vistas** (CORRECCIÓN a Fase 1, que decía "0 vistas"): `v_usuario_permiso` (020:75), `v_cola_actual` (030:648), `v_lote_disponible` (045:228), `v_stock_medicamento` (045:242). Ninguna materializada.
  - **0 tipos enum**; 68 índices (49 `CREATE INDEX` + los de PK/UNIQUE/parciales); 35 triggers; 310 sentencias `CREATE OR REPLACE FUNCTION` → **282 funciones únicas** (8 redefiniciones: stubs de acoplamiento del bot `bot_modulo_callback`/`bot_modulo_texto`/`bot_menu_extra`/`bot_texto_ayuda`/`bot_modulo_media`, más `pesos`, `accion_editar`, `bot_tarjeta_turno`). Sin esquema adicional: todo vive en `public`.
  - Volatilidad: 24 `IMMUTABLE`, 140 `STABLE`, 146 sin declarar (`VOLATILE` por defecto). `STRICT`: 5. Lenguajes: 167 `plpgsql`, 143 `sql`.

  **Dominios** (tabla → migración):
  - **Base**: `config` (010:41), `sede` (010:72), `consultorio` (010:86), `evento_auditoria` (010:103), `telegram_update` (010:145), `tarea_async` (010:210), `rate_limit` (010:344).
  - **Identidad**: `usuario`, `rol`, `permiso`, `rol_permiso`, `usuario_rol`, `usuario_permiso`, `conversacion_estado`, `auth_challenge`, `sesion` (020).
  - **Turnos**: `tipo_servicio`, `sesion_consultorio`, `turno` (030); `aviso_turno_enviado` (035).
  - **Inventario**: `medicamento`, `lote`, `movimiento_inventario` (045).
  - **Pacientes/clínico**: `dueno`, `paciente`, `disponibilidad`, `cita`, `consulta`, `consulta_adenda` (050).
  - **Cobro**: `tarifa`, `cierre_caja`, `cuenta`, `cuenta_linea`, `descuento`, `pago` (060).
  - **Compras**: `proveedor`, `entrada_inventario`, `entrada_linea` (070).
  - **IA**: `ia_mensaje`, `ia_accion_pendiente`, `ia_herramienta` (078).
  - FKs agregadas en migraciones posteriores (no en su tabla padre): `turno.dueno_id/paciente_id/consulta_id/cuenta_id` (050/060), `movimiento_inventario.consulta_id/paciente_id/cuenta_linea_id` (050/060), `lote.entrada_id` (070).

  **Estados: convención `text` + CHECK** (ver resolución de directiva n.º 1). Estados principales:
  - `tarea_async.estado` = `pendiente|procesando|completada|fallida` (010:215).
  - `turno.estado` = `en_espera|llamado|en_atencion|finalizado|ausente|cancelado` (030:59-61); `turno.canal_origen` = `qr_telegram|recepcion_manual|tablet_kiosco`.
  - `cuenta.estado` = `abierta|cerrada|anulada` (060:109-110); `paciente.estado` = `activo|fallecido|inactivo`; `consulta.estado` = `borrador|firmada|anulada` (050:203-204); `cita.estado` = `programada|confirmada|cumplida|cancelada|no_asistio`; `entrada_inventario.estado` = `borrador|confirmada|descartada` (070:80-81); `auth_challenge.estado` = `pendiente|aprobado|rechazado|expirado|consumido` (020:219-220); `ia_accion_pendiente.estado` = `pendiente|confirmada|cancelada|expirada` (078:99-100).
  - Canal transversal: `telegram|web|sistema|job` (auditoría, movimiento, cobro, compras).
  - Excepciones de texto libre (con/sin comentario): `telegram_update.tipo`, `aviso_turno_enviado.tipo` (comentario "proximo|llamado|…"), `conversacion_estado.flujo/paso`, `medicamento.presentacion/concentracion/categoria`.

  **Tablas append-only** (090_grants.sql:39-63, DO loop sobre `evento_auditoria`, `movimiento_inventario`, `pago`, `descuento`):
  - A `chasquipet_app`: REVOKE `UPDATE, DELETE, TRUNCATE` → solo `SELECT, INSERT`.
  - A `chasquipet_lectura`: REVOKE ALL → solo `SELECT`.
  - `telegram_update`: REVOKE `DELETE, TRUNCATE` de la app (conserva UPDATE para marcar `procesado`); purga solo vía `mantenimiento_diario` (SECURITY DEFINER).
  - Protección a nivel de trigger además del rol: `movimiento_inmutable` (045:220, ERRCODE 0A000 "sólo agregar"), `pago_inmutable`/`descuento_inmutable` (060:377,379), `consulta_no_editar_firmada` (050:277). Corrección por *reverso* (`descuento.tipo reverso`, `pago.tipo reverso`) o por adenda, nunca editando la fila.

  **Roles de PostgreSQL** (090_grants.sql:14-23, condicionados a no existir):
  - `chasquipet_app` (LOGIN, operativo n8n/worker/portal): CONNECT, USAGE schema, CRUD sobre todas las tablas (menos append-only), USAGE+SELECT secuencias, EXECUTE funciones, y `ALTER DEFAULT PRIVILEGES` para objetos futuros (090:77-84).
  - `chasquipet_lectura` (LOGIN, BI/reportes): solo SELECT sobre tablas (sin secuencias ni EXECUTE).
  - Contraseñas fijadas por env (`.env`) vía `900_superadmin.sh`; el CREATE ROLE no trae PASSWORD.
  - Los roles de negocio (`rol`, `permiso`, `rol_permiso`) son **datos** en `020_identidad.sql`, no roles de PostgreSQL — confusión a evitar.
  - Grants puntuales fuera de 090: `035:39` (aviso_turno_enviado → app), `078:1066-1069` (tablas IA → app/lectura).

  **Auditoría**:
  - `evento_auditoria` (010:103-116): `entidad text`, `entidad_id text`, `accion text`, `usuario_id uuid` (FK lógica sin REFERENCES), `canal` CHECK, `datos_antes/datos_despues jsonb`, `detalle text`, `ip inet`, `created_at`. Índices por entidad, usuario y fecha.
  - Único punto de escritura: `auditar(...)` (010:122-138, SECURITY DEFINER vía 090:68), invocada en ~78 sitios (PERFORM auditar). La columna `ip` **existe pero nunca se puebla** por `auditar()` (no hay parámetro).
  - No hay trigger de auditoría; es procedimental.

  **Cola `tarea_async`** (resumen en Punto A de la directiva): 4 estados, `FOR UPDATE SKIP LOCKED` en `reclamar_tareas` (010:268), backoff exponencial `LEAST(30*2^(intentos-1),3600)` (010:316), dead-letter → `fallida` + auditoría + encola `notificar_superadmin` al agotar `max_intentos` (010:298-312), rescate de colgadas ≥15 min (010:326-339). Idempotencia del encolado vía UNIQUE parcial `idx_tarea_clave_unicidad` + `ON CONFLICT DO NOTHING` (010:234-235). No existe otra cola ("tarea" como tabla no existe).

  **Deduplicación Telegram**: atómica con `ON CONFLICT (update_id) DO NOTHING` + `RETURN FOUND` (010:159-195). Detalle en directiva n.º 3.

  **Trigger de caché (patrón dominante)**: el estado materializado se mantiene con triggers en vez de recomputar en cada lectura:
  - `touch_updated_at` → 17 triggers `*_touch` (sellan `updated_at`).
  - `movimiento_validar`/`movimiento_aplicar`/`movimiento_inmutable` (045) — validan, aplican el signo de stock a `lote.cantidad_actual` e inmutabilidad.
  - `cuenta_recalcular_trigger` (060:324) tras línea/descuento/pago recalcula `cuenta.subtotal/descuento/total/pagado`; `cuenta_exigir_abierta` (060:342) y `cuenta_linea_no_editar` (060:385) impiden operar cuentas no abiertas.
  - `entrada_recalcular_trigger` (070:158) y `entrada_exigir_borrador` (070:125) solo en `borrador`.
  - `consulta_inmutable` (050:277) — firmadas/anuladas no se editan.

  **Columnas GENERATED STORED**: `medicamento.busqueda` (normalizar), `dueno.busqueda` y `dueno.telefono_digitos`, `paciente.busqueda`, `proveedor.busqueda`, `cuenta_linea.valor_total`, `entrada_linea.valor_total`. Búsquedas con GIN `pg_trgm` (`idx_*_busqueda`).

  **SECURITY DEFINER**: solo `auditar` y `mantenimiento_diario` (090:68,74), ambas **sin `SET search_path`** → riesgo de hijacking de search_path (reportado, no corregido). El resto corre como invocador. `mantenimiento_diario` (088:34, autorizado 090:70-73) es el único que purga `telegram_update`, `conversacion_estado`, `auth_challenge`, `tarea_async`; jamás toca `evento_auditoria` ni `movimiento_inventario`.

  **Patrones transversales observados** (para Fases 4/5):
  - Toda función de escritura firma `p_actor_id uuid` primero y `p_canal text DEFAULT 'telegram'` al final, valida con `exigir_permiso` al inicio y devuelve `jsonb {ok: …}`.
  - Los nombres de utilidades de la documentación existen literalmente (ver utilidades siguientes): la documentación coincide con el código en este punto.
  - Conteo Fase 0/1 "282 funciones únicas" es consistente con 310 sentencias (8 redefiniciones de interconexión entre módulos del bot).

- **Funciones utilitarias encontradas** (todas reales, con `archivo:línea`):
  - `exigir_permiso(p_usuario_id uuid, p_permiso text) → void` — **020_identidad.sql:101** (plpgsql STABLE; lanza excepción si `tiene_permiso` es falsa).
  - `tiene_permiso(p_usuario_id uuid, p_permiso text) → boolean` — **020_identidad.sql:92** (única verificadora; no existen `puede_*`/`es_*`).
  - `auditar(entidad, entidad_id, accion, usuario_id, canal, datos_antes jsonb, datos_despues jsonb, detalle) → bigint` — **010_base.sql:122** (SECURITY DEFINER por 090:68).
  - `encolar_tarea(tipo, payload jsonb, prioridad, clave_unicidad, retraso_seg, max_intentos) → bigint` — **010_base.sql:237**.
  - `hoy_bogota() → date` — **010_base.sql:14** · `ahora_bogota() → timestamp` — **010_base.sql:19** (sql STABLE; no hay `hoy_local`/`ahora_local`).
  - Lectura de configuración: `config_int / config_txt / config_bool` — **010_base.sql:54/59/64**.
  - Cola complementaria: `reclamar_tareas` (010:258), `completar_tarea` (010:278), `fallar_tarea` (010:288), `rescatar_tareas_colgadas` (010:326).
  - Telegram: `registrar_update_telegram` (010:161), `marcar_update_procesado` (010:197), `bot_manejar_update` (040:258) + `accion_enviar`/`accion_editar` (040:33/40) y la cadena de stubs `bot_modulo_callback/texto/media` → handlers por módulo.
  - FSM conversacional: `estado_guardar / estado_leer / estado_limpiar` — **020_identidad.sql:173/197/208**.
  - Reportes/admin: `mantenimiento_diario` (088:34), `auditoria_listado`, `salud_sistema`, `tareas_listado`, `resumen_tareas`, `reintentar_tarea`, `descartar_tarea` (085).

- **Directiva: resolución de las incertidumbres de Fase 1**:
  1. **Estados `text` (sin enums)** — RESUELTO. Es convención deliberada: 0 `CREATE TYPE AS ENUM`; cada columna de estado/tipo/canal fija su lista cerrada en un `CHECK`. Excepciones de texto libre documentadas arriba.
  2. **`db/seeds/` (vacío)** — PARCIALMENTE RESUELTO. No se monta en `docker-compose.yml` (solo `./db/migrations` se monta en `/docker-entrypoint-initdb.d`, compose:50), no aparece en scripts ni en README. El "seeding" real ocurre en las migraciones `100_seed_roles.sql` y `110_seed_operativo.sql` (dentro del orden alfabético), en el superadmin por env y en `db/demo/` cargada manualmente con `scripts/cargar-demo.sh`. **Propósito del directorio: UNKNOWN** (contenedor vacío sin referencias; probablemente residuo/alternativa descartada).
  3. **`telegram_update.procesado` ante `acciones:[]`** — RESUELTO. El workflow `01-telegram-webhook.json` es lineal e incondicional: el nodo "Marcar procesado" (executeOnce:true, `update_id` tomado del nodo Webhook) se ejecuta **siempre**, incluso con `acciones:[]` o con `duplicado:true`, y deja `procesado=true, error=NULL, procesado_at=now()` (010:200 `SET procesado = (p_error IS NULL)`). La duda de Fase 1 ("podría no ejecutarse") queda **descartada**: el update siempre queda marcado.
  4. **`config` y `ia_modelo`** — RESUELTO. Esquema `config(clave PK, valor, tipo CHECK(texto|entero|decimal|booleano|json), descripcion, editable_ui, updated_at)` (010:41-49); lectoras `config_int/txt/bool`; escritora `guardar_config` (085:251) con `exigir_permiso('config.editar')`, respeta `editable_ui` y valida tipo. **Inventario completo de claves seed** (véase Punto B de la directiva; agregado a Incertidumbres pendientes en el registro acumulado). Contrato de `ia_modelo`: valor texto, seed en `078_chasqui_ia.sql:49-50` que documenta `deepseek-v4-pro` (mejor) o `deepseek-v4-flash` (más barato); consumida por el worker vía `config_txt('ia_modelo','deepseek-v4-pro')` (`worker/src/tareas/chasqui_responder.js:185`) y editable en UI admin. **Residual UNKNOWN**: la existencia del nombre de modelo en el provider DeepSeek no es verificable sin una llamada a la API ni inspección del `.env` real.

- **Incertidumbres**:
  - Existencia real del modelo `deepseek-v4-pro` en el provider (no verificable sin llamada a la API; la descripción del seed documenta `deepseek-v4-pro`/`deepseek-v4-flash` como las dos opciones). → `UNKNOWN`.
  - Propósito de `db/seeds/` (directorio vacío, sin referencias en compose/scripts/docs). → `UNKNOWN`.
  - La BD no estaba ejecutándose durante el análisis; los conteos provienen de grep sobre migraciones, no de `information_schema` (se espera que coincidan; verificables al levantar el stack).

### Fase 3 — Reconstrucción de la arquitectura real

- **Fecha / sesión**: 2026-08-09 / sesión 4
- **Agente**: project-analyst (con apoyo de database-analyst, backend-analyst, telegram-analyst, frontend-analyst, integration-analyst)
- **Directiva**: reconstruir el modelo real componente → responsabilidad → dependencias → flujo de datos, comprobado contra la implementación (no contra la documentación). Se verificaron los flujos de mensajes Telegram, cola asíncrona, portal, authz y errores con lectura de migraciones SQL, worker y web.

- **Modelo de arquitectura real**:

  **Patrón general — "PostgreSQL-centric"**: PostgreSQL 16 es la fuente única de verdad y dueña de toda la lógica de negocio; los componentes periféricos (n8n, worker, web) son capas delgadas que solo invocan funciones SQL y traducen formatos. Ningún componente recalcula reglas de negocio fuera de la base (verificaciones por componente más abajo). Evidencia: migraciones 010→110 concentran la lógica; el webhook n8n ejecuta solo 2 funciones SQL y traduce acciones (`n8n/workflows/01-telegram-webhook.json:26-47`); el worker solo reclama/despacha/reporta (`worker/src/index.js:8-14`); la web llama funciones SQL para leer y para escribir (`web/src/lib/db.ts:57-72`, `web/src/app/(portal)/inventario/acciones.ts:43-68`).

  1. **Fuente de verdad**: Postgres 16 (`public`) vía `chasquipet_app`. Único origen de datos y de decisiones. Los estados materiales (stock, totales de cuenta) se mantienen con triggers en la base (Fase 2), no se recomputan en las apps.

  2. **Dónde vive la lógica de negocio**: en 282 funciones SQL de `public` (Fase 2). Cada dominio se expone como funciones de lectura (STABLE) y de escritura con firma `p_actor_id uuid` + `p_canal text DEFAULT 'telegram'`, que validan con `exigir_permiso` y devuelven `jsonb {ok: …}`. Excepciones a "todo en SQL": 2 puntos de SQL crudo inline en la web (`web/src/lib/clinico.ts:154`, `web/src/app/(portal)/admin/config/page.tsx:42`). El worker y n8n NO contienen lógica de negocio (solo despacho/transporte/IA).

  3. **Comunicación entre componentes** (red Docker `chasquipet` bridge, docker-compose.yml:327-330):
     - **Entrada Telegram**: Telegram → webhook HTTPS → cloudflared (túnel) → Caddy `:80` → `/webhook/*` → n8n:5678 (Caddyfile:22-24). El editor de n8n NO se publica; la BD no sale nunca (docker-compose.yml:238-242, 269-273).
     - **DB**: solo `127.0.0.1:5433` del anfitrión (docker-compose.yml:55); dentro de la red, cada servicio se conecta por su `DATABASE_URL` (pool `chasquipet_app`) o por sus variables PG.
     - **Web → DB**: pool directo (`lib/db.ts:36-54`); conexiones dedicadas `LISTEN` vía `DATABASE_URL_DIRECTA` (`lib/db.ts:28-30,78-85`) porque pgbouncer rompería LISTEN.
     - **Worker → DB**: pool con `application_name chasquipet-worker` (index.js:38-44). **Worker → Telegram**: salidas vía Bot API (fetch nativo, `telegram.js`). El worker no recibe webhooks.
     - **Web → Telegram**: solo deep links generados (`t.me/<bot>?start=web-<id>` en `api/entrar/route.ts:48`; enlace portal en `077:76`); no hace llamadas HTTP salientes a Telegram.
     - **Web → n8n**: ninguna llamada real; `N8N_INTERNAL_URL` se inyecta (`docker-compose.yml:193`) pero la web no lo usa (ver Incertidumbres).
     - **n8n → DB**: nodos Postgres con credencial `chasquipet-postgres` y `DATABASE_URL` (workflow 01:40-46); jobs de cron llaman funciones SQL o encolan tareas.
     - **n8n → Telegram**: salida sincrónica del webhook (nodo httpRequest, `01:62-86`).

  4. **Operaciones asíncronas** — cola `tarea_async` (010:210-339) + worker + jobs n8n:
     - El webhook debe responder en <1s; todo lo diferido se encola con `encolar_tarea(...)` (010:237-255). Origenes: **funciones SQL del negocio** (10 call sites) y **jobs n8n** (2 tipos). Tipos (11 manejadores del worker):
       `notificar_turno_llamado` (030:376), `notificar_turnos_proximos` (030:378), `abrir_cuenta_turno` (030:411), `agregar_linea_cuenta` (045:576), `notificar_inicio_sesion` (058:152), `enviar_resumen_consulta` (050:1268), `enviar_recibo` (060:1205), `notificar_superadmin` (060:1045 y dead-letter 010:308), `chasqui_responder` (078:987), `recordar_llamado_vencido` y `alertas_inventario` (encoladas por jobs 02/03).
     - Mecánica: `reclamar_tareas` con `FOR UPDATE SKIP LOCKED` (010:258-276, N workers sin coordinación); worker en bucle cada 2 s (lote 10, `index.js:23-24,164-180`), procesa en paralelo y reporta `completar_tarea`/`fallar_tarea` (index.js:101-148); backoff exponencial `LEAST(30·2^(intentos-1),3600)` y dead-letter → `notificar_superadmin` (010:298-313); rescate de colgadas ≥15 min (010:326-339) desde el worker (cada 5 min) y desde el job 02 (cada minuto).
     - Idempotencia del encolado: `clave_unicidad` + UNIQUE parcial + `ON CONFLICT DO NOTHING` (010:234-235,251). Dedup de avisos con `aviso_turno_enviado` (`marcarAviso`, index.js:72-93; 035).
     - Jobs n8n: 02 cada 1 min (encola `recordar_llamado_vencido` por sede + `rescatar_tareas_colgadas(15)`); 03 diario 7:30 (`bloquear_lotes_vencidos()` + encola `alertas_inventario` con clave por día); 04 diario 3:15 (`mantenimiento_diario()` + `ANALYZE`). No guardan estado: solo llaman SQL.

  5. **Procesamiento de mensajes de Telegram** (pipeline completo, verificado):
     - Entrada: n8n webhook `chasquipet-telegram` (01:6-23) contesta 200 al recibir; nodo "Registrar y resolver" ejecuta `registrar_update_telegram($payload)` (dedup atómico por update_id, 010:161-195) y, si es nuevo, `bot_manejar_update($payload)` (01:26-47).
     - `bot_manejar_update` (040:258-570) es el **router único**: extrae chat/from/texto/callback_data/message_id (040:279-283); resuelve identidad con `perfil_telegram` y vincula el chat (`vincular_chat_usuario`, 040:289-298). Tres ramas:
       - **A) Público sin usuario** (040:303-350): `/start web-*` se deniega sin revelar validez; `/start turno-<sede>` → `crear_turno_qr`; público con turno de hoy → tarjeta del turno; cualquier otro texto → mensaje del QR.
       - **B) Personal por texto** (040:355-392): `/cola`, `/ayuda`, media (→ `bot_modulo_media`), texto que responde a un flujo (→ `bot_modulo_texto`), y todo lo demás → `estado_limpiar` + menú principal (`bot_menu_principal`, 040:101-163).
       - **C) Personal por callback** (040:397-560): `menu`, `turno:*`, `consultorio:*` resueltos inline; lo demás → `bot_modulo_callback`; `insufficient_privilege` → alerta de permiso + menú.
     - **Despacho modular por encadenamiento** `CREATE OR REPLACE` + `COALESCE` (cada módulo responde NULL si el prefijo de `data`/texto no es suyo). Ordenes finales (078):
       - `bot_modulo_callback`: **ia → inv → cli → cob → com → por → auth** (078:1016-1023)
       - `bot_modulo_texto`: **auth → por → inv → cob → com → cli → ia** (078:1035-1042; IA al final para no robar flujos con estado)
       - `bot_menu_extra`: cli ‖ inv ‖ cob ‖ com ‖ por ‖ ia (078:1007-1009); `bot_modulo_media`: solo compras (076:880-885)
     - **Contrato de salida**: JSON `{acciones:[{tipo:'responder_callback'|'enviar'|'editar', …}], alerta}` construido por `accion_enviar`/`accion_editar` (040:33-47, redefinida 058:384-394) + `responder_callback` antepuesto (040:564-568). n8n traduce cada acción a `answerCallbackQuery`/`sendMessage`/`editMessageText` (01:50) y `marcar_update_procesado` al final (01:91-110).
     - **FSM conversacional**: `conversacion_estado` (020:158-211, `estado_guardar/leer/limpiar`, TTL 2 h). Flujos con estado: salida de inventario (046), consulta clínica (056), cobro (066), entrada de compras + foto de factura (076), chat IA (078). El router limpia estado al llegar al menú (040:389).

  6. **Portal web** (Next.js 16 App Router, React 19, TS strict; sin middleware):
     - **Sesión**: cookie HttpOnly `chasquipet_sesion` (30 días, `sesion.ts:16-19`); la base guarda solo el sha256 del token (`058:136-141`); cada request valida `sesion_por_token` (058:171-201) con refresco de `last_seen_at` por minuto. `(portal)/layout.tsx:25` exige sesión (cortada por el layout, no por cada página).
     - **Login (2 caminos que confluyen en `emitir_sesion_web`)**: (a) challenge de 6 dígitos creado por la web (`api/entrar` → `crear_challenge_web` 058:27-53, rate-limit 10/h) y aprobado por el bot (deep link `web-<id>` → `bot_auth_texto`/`bot_auth_callback` 058:253-344 → `resolver_challenge_web`); la web sondea `/api/entrar/[id]` cada 2 s (ingreso.tsx:59-78). (b) enlace directo desde el chat (`/portal` → `crear_enlace_portal` 077:36-80 crea un challenge ya aprobado de un solo uso de 5 min; se consume en GET `/entrar/enlace/[id]`). El token se devuelve una sola vez; reproducir la respuesta no sirve.
     - **Lecturas**: Server Components llaman funciones SQL vía `consultar`/`consultarUna` (dashboard→`dashboard()` (portal)/page.tsx:62-66; catálogo→`catalogo_medicamentos`; consultas→`consultasRecientes`; pacientes→`buscarPacientes`; reportes→`reporte_*` 080).
     - **Escrituras**: Server Actions (`'use server'`) que llaman funciones SQL con `$1 = actor` (inventario/acciones.ts:43-68, consulta/[id]/acciones.ts:77-117, admin/acciones.ts, pacientes/[id]/page.tsx:39-48) y `revalidatePath`.
     - **Pantalla pública**: Server Component inicial + SSE (`/api/pantalla/[sede]/stream`) vía `LISTEN pantalla_turnos` (canal emitido por `pg_notify` en 030:699) con multiplexor en `lib/notificaciones.ts` y fallback a polling 5 s (`vista-pantalla.tsx:8,114,147-150`).
     - **Reportes**: 13 reportes declarados en TS que apuntan a funciones `reporte_*` de 080 (lib/reportes.ts:38-259); CSV por `/api/reportes/[clave]` protegido con sesión + permiso (route.ts:21-32); parámetros pasados como bind, nunca concatenados.
     - La web **nunca decide permisos**: lee la lista ya resuelta por `v_usuario_permiso` y solo la compara (`exigirPermiso`, sesion.ts:59-65).

  7. **Autenticación y autorización** (tres capas):
     - **Roles de PostgreSQL**: `chasquipet_app` (operativo: CRUD + EXECUTE, 090:14-23,77-84) y `chasquipet_lectura` (solo SELECT). Contraseñas fijadas por env en 900_superadmin.sh.
     - **Roles de negocio (datos)**: `usuario/rol/permiso/rol_permiso/usuario_permiso` (020) — son datos, no roles de Postgres. Verificación central: `tiene_permiso` (020:92) + `exigir_permiso` (020:101) al inicio de cada función de escritura; vista `v_usuario_permiso` para la web. El bot y la web llaman las mismas funciones: no hay dos authz distintas.
     - **Append-only / inmutabilidad**: REVOKE UPDATE/DELETE/TRUNCATE sobre `evento_auditoria`, `movimiento_inventario`, `pago`, `descuento` (090:39-63) + triggers `*_inmutable` (045:220, 060:377-379, 050:277). Corrección por reverso/adenda, nunca editando la fila.
     - **Auditoría**: `auditar()` (010:122-138, SECURITY DEFINER) invocada en ~78 sitios; `evento_auditoria.ip` existe pero `auditar()` no la puebla (reportado Fase 2).

  8. **Manejo de errores**:
     - **SQL**: contrato de respuesta `jsonb {ok:boolean, motivo?, mensaje?}` para condiciones esperadas; excepciones (`RAISE`, CHECK, `exigir_permiso`) para fallos. El bot traduce ambas a mensajes/alerts (040:554-559).
     - **n8n**: `responseMode=onReceived` contesta 200 antes de procesar; `neverError` + `continueRegularOutput` hace tolerante el 400 "message is not modified" (01:62-86); "Marcar procesado" corre siempre (incluso con `acciones:[]`/duplicado).
     - **Worker**: `try/catch` por tarea → `fallar_tarea` (backoff en la base, el worker no reimplementa nada); Telegram 429 → espera `retry_after` y reintenta una vez, 403/400 no recuperables → completa con `{ok:false}` (telegram.js:7-16,95-113). Falla de DB en una pasada → reintenta sin morir (index.js:242-247). Fallos irrecuperables → `apagar` limpio.
     - **Web**: Server Actions devuelven `{ok, mensaje}` y los clientes lo pintan con `useActionState` (no hay `app/error.tsx`); errores SQL de validación se propagan (`r.mensaje`). `/health` hace `SELECT 1`. Errores de API → HTTP 429/401/403/503 según caso.

  9. **Integraciones externas**:
     - **Telegram Bot API**: entrada por webhook (n8n, token vía `$env`, nunca versionado), salidas desde n8n (webhook) y worker (fetch nativo, telegram.js). Deep links: `web-<id>` (login), `turno-<sede>` (QR público), `por:enlace` (portal).
     - **DeepSeek (compatible OpenAI)**: SOLO el worker (`chasqui_responder.js`); n8n y web nunca llaman al modelo. Flujo: bot encola `chasqui_responder` (078:987-992) → worker lee `ia_herramientas/ia_historial/ia_contexto` + `ia_modelo`/`ia_temperatura` (chasqui_responder.js:181-188) → bucle de ≤8 vueltas con `tools` (herramientas = catálogo `ia_herramienta` 078:125-246) → cada tool_call llama `ia_llamar` (078:656-711, puerta única, reja de permiso + `escribe=false`→lee / `escribe=true`→`ia_accion_pendiente`) → si requiere confirmación, tarjeta de confirmación por botón (078:848-865) que cierra el bot con `ia_confirmar` (078:714-762; el worker NUNCA escribe). Respuesta final se guarda con `ia_registrar`. Sin `DEEPSEEK_API_KEY` → aviso honesto y tarea completada sin quemar reintentos (chasqui_responder.js:166-176).
     - **Cloudflare Tunnel**: `cloudflared` publica el proxy (perfil `local`); `registrador` (registrar-publico.sh) descubre el hostname del quicktunnel cada 60 s, registra el webhook (`setWebhook`) y actualiza `config.portal_url` solo si cambió (script:50-88). Con dominio propio fijo, `WEBHOOK_URL_FIJA` anula el descubrimiento.
     - **Facturación DIAN/Factus**: NO implementada (solo plan futuro, Fase 1).

- **Incertidumbres de Fase 3**:
  - **`N8N_INTERNAL_URL` inyectado al web (`docker-compose.yml:193`)**: no se encontró ningún consumidor en `web/src` (sin fetch a n8n). Se desconoce si es residuo o hay uso futuro. → `UNKNOWN`.
  - **`accion_editar` del worker (`worker/src/telegram.js:145-153`) sin callsites activos**: ningún manejador importa `editarMensaje`; la edición de menús vive en SQL y la ejecuta n8n. Función muerta en la práctica (confirmar si se elimina es decisión futura, no de esta misión).
  - La base no estaba levantada durante esta fase; el modelo deriva de la lectura de migraciones + código (worker/web/n8n). Los comportamientos dinámicos (LISTEN/SSE, webhook, jobs) se infieren de su implementación, no de una ejecución en vivo.
  - Comandos `/turno` y `/turnos`: **no existen** como comandos de texto en ninguna migración (grep de la Fase 3); la operación de turnos es exclusivamente por botones/callbacks (`turno:*`). Si algo de la documentación los menciona, es doc vs código (se conserva para Fase 5).

### Fase 4 — Patrones repetidos

- **Fecha / sesión**: 2026-08-09 / sesión 5
- **Agente**: backend-analyst (con apoyo de database-analyst)
- **Directiva**: identificar los patrones que se repiten en el código con evidencia concreta y frecuencia, para poder (a) uniformar el contexto de los agentes, (b) crear skills y comandos, y (c) detectar duplicación consolidable. La investigación cubrió SQL (`db/migrations/`), worker, n8n, web y scripts. Los conteos vienen de grep sobre el repositorio en disco (la base no está levantada); cada frecuencia está acompañada del método de conteo.

- **Patrones** (patrón / evidencia / frecuencia / alcance / confianza):

  **SQL — capa de dominio (282 funciones)**
  1. **Firma canónica de escritura** — `p_actor_id uuid` (actor) como primer parámetro, `p_canal text DEFAULT 'telegram'` (o `'web'`) al final, cuerpo que abre con `PERFORM exigir_permiso(p_actor_id, 'modulo.accion')`. Evidencia: `050_pacientes.sql:674-688`, `060_cobro.sql:773-779`, `030_turnos.sql:390`, `085_admin.sql:50`. Frecuencia: 94 llamadas `exigir_permiso(...)` — 60 con `p_actor_id` (funciones de dominio) + 34 con `p_usuario_id` (callbacks de bot); ~57 firmas con `p_canal`. Alcance: todos los dominios. Confianza: alta (grep exacto).
  2. **Contrato de retorno JSONB `{ok, true|false}`** — éxito: `jsonb_build_object('ok', true, '<entidad>', <json_entidad>)`; fracaso: `('ok', false, 'motivo', <codigo_maquina>, 'mensaje', <texto_humano>)`. La clave `'datos'` NO es el estándar: solo `ia_leer` la usa (`078_chasqui_ia.sql:459`). Evidencia: `060_cobro.sql:582-583`, `050_pacientes.sql:705-709`, `046_bot_inventario.sql:408-412`. Frecuencia: `'ok', false` = **156**, `'ok', true` = **79** (grep exacto). Alcance: transversal. Confianza: alta.
  3. **Auditoría procedimental** — única firma `auditar(entidad, entidad_id, accion, usuario_id, canal [, antes, despues, detalle])` (`010_base.sql:122-138`), invocada siempre `PERFORM auditar(...)` (el `RETURNING` no se captura), a menudo con solo 5 argumentos. Evidencia: `060_cobro.sql:610`, `030_turnos.sql:609`. Frecuencia: **66** `PERFORM auditar(` (grep exacto; 0 con `SELECT`/asignación). Alcance: todos los dominios + seed + dead-letter. Confianza: alta.
  4. **Errores por `RAISE EXCEPTION` con ERRCODE semántico** — NO existe `P0001` ni `hint=` (corrige hipótesis del encargo). Frecuencia: **20** `RAISE EXCEPTION` (grep), de las cuales **12** usan `USING ERRCODE` con códigos semánticos: `42501` (permiso, `020:279`), `28000` (no autenticado, `020:106`), `23514` (check_violation de negocio, `045:178,184`, `060:353,397`, `070:662`), `0A000` (append-only, `045:216`, `060:373,391`, `070:134`). 8 `RAISE EXCEPTION 'texto'` simples sin `USING`. Complementario: *no* se devuelve `ok:false` desde `EXCEPTION WHEN unique_violation/check_violation` en ~15 puntos (`050:706-709`, `060:794-795`, `070:660-663`) en vez de lanzar. Confianza: alta (grep + lectura directa).
  5. **Idempotencia por `ON CONFLICT` + UNIQUE parcial** — tres variantes: `INSERT ... ON CONFLICT DO NOTHING` como decisión atómica (dedup `telegram_update` 010:191, avisos `035:1-16`); `DO UPDATE` para merges de estado (`estado_guardar` 020:184, `config`/`rate_limit` 010:359); UNIQUE parcial de infraestructura `idx_tarea_clave_unicidad ... WHERE clave_unicidad IS NOT NULL AND estado IN ('pendiente','procesando')` (`010_base.sql:234-235`). Frecuencia: **24** `ON CONFLICT` + **13** guardias `NOT EXISTS`/`IF NOT EXISTS` (grep). Alcance: base, seeds, estado, encolado. Confianza: alta.
  6. **Triggers de 3 familias** (35 `CREATE TRIGGER` en total): (A) **20 `*_touch`** de `updated_at` (BEFORE UPDATE, `touch_updated_at` 010:30-36); (B) **recálculo de caché** AFTER INSERT/DELETE — `movimiento_aplicar` (stock, 045:196-207), `cuenta_recalcular` (subtotal/descuento/total/pagado, 060:296-337), `entrada_recalcular` (valor_total, 070:149-168); (C) **validación/inmutabilidad** BEFORE — `movimiento_validar` (045:163-191), `*_inmutable` con `0A000` (045:212-221, 060:369-379), `consulta_no_editar_firmada` (050:277), `entrada_exigir_borrador` (070:125-145), `cuenta_exigir_abierta` (060:342-363), `cuenta_linea_no_editar` (060:385-403). Confianza: alta (lista exhaustiva).
  7. **Búsqueda con `normalizar()` + GENERATED STORED + GIN `pg_trgm`** — columna `busqueda = normalizar(coalesce(nombre,'')...)` (`normalizar` 010:25-28 = lower+unaccent+regexp) indexada `gin_trgm_ops`; variante numérica `telefono_digitos`. Frecuencia: **8** columnas GENERATED STORED (050:3, 070:2, 060:2, 045:1), **4** índices `gin_trgm_ops`, **25** usos de `normalizar(`. Alcance: dueno, paciente, medicamento, proveedor. Confianza: alta.
  8. **FSM conversacional** — tabla `conversacion_estado` (020:155-168, TTL 2 h) + `estado_guardar/leer/limpiar` (020:173-211). Patrón: entrada → `estado_limpiar` + guardar paso inicial; cada callback → `estado_leer` + merge `datos := datos || jsonb_build_object('campo', valor)`; `estado_guardar` UPSERT con merge superficial y `expira_at` por `p_ttl_min`. Frecuencia: **75** `estado_guardar(` (grep; 056:24, 076:23, 066:15, 046:10), `estado_leer(` 11, `estado_limpiar(` ~30. Flujos: salida, stock, consulta, paciente_nuevo, paciente_buscar, cobro, entrada, ia. Alcance: los 6 módulos de bot. Confianza: alta.
  9. **Encolado con clave compuesta** — `encolar_tarea(tipo, payload, prioridad, clave_unicidad [, retraso, max_intentos])` (010:237-255); claves `'prefijo_id'`: `notificar_inicio_sesion` `'sesion_'||id` (058:152), `agregar_linea_cuenta` `'linea_mov_'||id` (045:576), `enviar_resumen_consulta` `'resumen_consulta_'||id` (050:1268), `abrir_cuenta_turno` `'cuenta_'||id` (030:411), `notificar_turnos_proximos` (030:378), `enviar_recibo` `'recibo_'||id` (060:1205), `notificar_superadmin` (dead-letter 010:308 y cierre de caja 060:1045), `chasqui_responder` (078:987), `notificar_turno_llamado` (030:376). Frecuencia: **10** call sites (grep). Confianza: alta.
  10. **Bot por stubs encadenados + COALESCE** — hooks `bot_modulo_callback/texto/media/menu_extra` nacen vacíos en `040_bot_turnos.sql:63-95` (devuelven NULL si el prefijo no es de su módulo) y se redefinen en cada módulo con `CREATE OR REPLACE`; el enrutador solo llama a los hooks (040:258). Orquestador final en `078_chasqui_ia.sql`: `bot_modulo_callback` = COALESCE `ia→inv→cli→cob→com→por→auth` (078:1012-1024); `bot_modulo_texto` = COALESCE `auth→por→inv→cob→com→cli→ia` (078:1031-1043, comentario 1026-1030 explica por qué IA va de último); `bot_menu_extra` concatena menús (078:1004-1010). Cada `bot_<mod>_callback` abre con `IF v_partes[1] <> 'mod' THEN RETURN NULL` (046:339, 066:292, 078:877). Frecuencia: 8 archivos redefinen callbacks/texto; `string_to_array(p_data, ':')` x6, `v_partes[1]` x9. Confianza: alta.
  11. **Puerta única de IA (3 rejas)** — (1) catálogo `ia_herramientas` filtrado por `tiene_permiso` (078:268-279); (2) `ia_llamar` re-verifica permiso e inserta `ia_accion_pendiente` sin ejecutar para las de escritura (078:656-711); (3) `ia_confirmar` valida `FOR UPDATE`+estado, propiedad y expiración antes de `ia_escribir` (078:714-762). Herramientas: 19 registradas (13 lectura, 6 escritura `escribe=true`). Confianza: alta.
  12. **Normalización de entrada `NULLIF(trim(COALESCE(x, '')), '')`** — texto vacío → NULL antes de insertar. Frecuencia: **116** `NULLIF(` (grep). Alcance: transversal (050:690-698, 060:817, 070:40). Confianza: alta.
  13. **Rate-limit con clave `'dominio:sufijo'`** — `consumir_rate_limit` (010:351-370); sites: `login:ip:`/`login:tg:` (058:39,72), `turno:chat:` (030:219), `ia:<usuario>` (078:978), `portal:enlace:` (077:52). Frecuencia: 6. Confianza: alta.
  14. **Helpers del bot centralizados en 040** — `esc()` (escape HTML, 040:22-25), `accion_enviar`/`accion_editar` (040:33-47, 058:384-394), `pesos()` (040:28-31). Frecuencia: `accion_enviar` **28**, `accion_editar` **30**, `pesos` 9. Confianza: alta.
  15. **Duplicación de utilidades de formato** (hallazgo de consolidación): `pesos()` en 040 con formato `'FM999G999G999G999'` vs copia privada en `060:244` con `'FM999,999,999,999'`+translate; `signo_movimiento` (045:129) vs `signo_dinero` (060:232) — mismo rol, dos implementaciones cuasi idénticas. `to_char` de fechas disperso sin helper común. Confianza: alta.

  **WORKER — capa delgada (Node 22 ESM)**
  16. **Esqueleto de manejador** — contrato fijo `export const tipo` + `export async function manejar({ payload }, { db, log, marcarAviso })`; éxito = devolver objeto (va a `tarea_async.resultado` vía `completar_tarea`), fallo = lanzar Error (→ `fallar_tarea`, backoff lo decide la BD). Evidencia: `notificar_turno_llamado.js:13`, 11/11 manejadores. Datos casi siempre en una sola consulta `SELECT <func_sql>($1) AS alias` → `rows[0].alias` (`abrir_cuenta_turno.js:18-22`). Casos normales se completan con `{enviado:false, motivo:'...'}` sin error (turno sin chat_id: `notificar_turno_llamado.js:23-26`). Frecuencia: 11 manejadores (verificado). Confianza: alta.
  17. **Sin transacciones manuales ni estado** — 0 `BEGIN/COMMIT/ROLLBACK` y 0 `pool.connect()` en el worker; toda transacción/idempotencia vive en las funciones SQL (`reclamar_tareas` con SKIP LOCKED). Pool único con `application_name: 'chasquipet-worker'` + `setTypeParser(20, Number)` (index.js:31-44); `pool.on('error')` no tumba el proceso. Confianza: alta.
  18. **Envío Telegram centralizado en `telegram.js`** — `enviarMensaje` (sendMessage, `parse_mode:'HTML'`, `disable_web_page_preview:true`), `editarMensaje` (sin callsites activos, Fase 3), helper `teclado(filas)`, y `esc()`. `llamar()` define la política: 429 → espera `retry_after` (≤60 s) y reintenta 1 vez; 403 → `{ok:false, motivo:'bloqueado'}` sin reintento; 400 "chat not found/user is deactivated" → `{ok:false, motivo:'chat_invalido'}`; resto → `TelegramError` para reintento de la cola (telegram.js:64-119). Maniheros multi-destinatario acumulan `fallos[]` y solo lanzan si `enviados===0` (notificar_superadmin.js:48-63). Frecuencia: 9/11 manejadores usan `enviarMensaje`; 2 usan `teclado`. Confianza: alta.
  19. **Dedup de avisos `marcarAviso`** — `INSERT INTO aviso_turno_enviado ... ON CONFLICT DO NOTHING` (índice (turno_id, tipo)); ante `42P01` (tabla sin migrar) avisa una vez y prefiere duplicar a no avisar (index.js:72-93). `notificar_turnos_proximos` reserva antes de enviar y libera con DELETE si falla (39,57,83-91). Confianza: alta.
  20. **Logs de una línea a stdout** — `[YYYY-MM-DD HH:MM:SS] NIVEL mensaje`, hora Bogotá (`Intl.DateTimeFormat es-CO`), niveles INFO/AVISO/ERROR, sin colores ni archivo; `textoError()` para serializar excepciones (log.js:9-47). Confianza: alta.

  **N8N — capa de transporte (4 workflows)**
  21. **Webhook como tubería lineal** — `webhook(200 onReceived) → postgres(registrar_update_telegram + bot_manejar_update, queryReplacement={{JSON.stringify($json.body)}}) → code(traduce cada acción JSONB: respondercallback→answerCallbackQuery, enviar→sendMessage, editar→editMessageText; botones `a.botones`→inline_keyboard b.t/b.d) → http(api.telegram.org/bot$env.TELEGRAM_BOT_TOKEN, neverError+continueRegularOutput) → postgres(marcar_update_procesado, executeOnce)` (`01-telegram-webhook.json:6-111`). La lógica nunca vive en n8n. Confianza: alta.
  22. **Jobs = scheduler→SQL puro** — `scheduleTrigger` (timezone America/Bogota) → nodos postgres que solo llaman funciones SQL o encolan: 02/min encola `recordar_llamado_vencido` por sede + `rescatar_tareas_colgadas(15)` (02-job-turnos.json:29,51); 03/diario `bloquear_lotes_vencidos()` + encola `alertas_inventario` con clave `alertas_inv_<fecha>` (03:29,50); 04 `mantenimiento_diario()` + `ANALYZE` (04:28,49). Confianza: alta.

  **WEB — capa delgada (Next.js 16)**
  23. **Server Actions con firma uniforme** — `(previo: Resultado|null, FormData) => Promise<{ok, mensaje?}>`; orden: `exigirPermiso(permiso, ruta)` → traducir FormData → `consultarUna('SELECT <func_sql>($1, ...)', [sesion.usuario_id, ...])` con `$1`=actor y origen `'web'` → `revalidatePath` → `return fila?.r ?? {ok:false,...}`. Frecuencia: 4 archivos `'use server'` (admin/acciones.ts, inventario/acciones.ts, consulta/[id]/acciones.ts, pacientes/[id]/page.tsx), 13 acciones, 5 componentes con `useActionState`. Confianza: alta.
  24. **Route handlers con cabecera fija** — `runtime='nodejs'` + `dynamic='force-dynamic'` + `NextResponse.json(..., {Cache-Control: 'no-store'})`; sesión solo donde aplica (`reportes/[clave]`: `sesionActual()`+`puede()` → 401/403). `params: Promise<...>` con `await params` + validación `esUuid`. Frecuencia: 8 rutas (`api/entrar` [2], `api/pantalla/[sede]`+stream, `api/reportes/[clave]`, `health`, `salir`). Confianza: alta.
  25. **Lectura con `consultar`/`consultarUna`** — envoltorio delgado de pool cacheado en `globalThis` (db.ts:36-72) que llama `SELECT <func_sql>($1...) AS alias` sin ORM. **Corrección al conteo del agente**: los usos directos son **5** (db.ts:89, salir/route.ts:21, admin/acciones.ts:38/105/107, admin/page.tsx:29, (portal)/page.tsx:62); las páginas de listados/decols usan las *funciones envoltorio* de `lib/*` (p.ej. `consultasRecientes`, `buscarPacientes`, `reporte_*`) que a su vez llaman las funciones SQL. Confianza: alta.
  26. **SSE con multiplexor y fallback polling** — `lib/notificaciones.ts` mantiene UNA conexión `LISTEN pantalla_turnos` en `globalThis` (via `DATABASE_URL_DIRECTA`) y reparte NOTIFY a un `Set<Oyente>` con reconexión cada 3 s; `/stream` emite estado inicial + heartbeat 20 s + `retry: 3000`; cliente `vista-pantalla.tsx` usa `EventSource` con caída a polling 5 s y vigilante de reconexión. Confianza: alta.

  **SCRIPTS — operación**
  27. **Preámbulo común de shell** — 5 scripts bash usan `set -euo pipefail` + `cd "$(dirname "$0")/.."` + comprobación de `.env` + `set -a; . ./.env; set +a`; acceso a la BD siempre `docker compose exec -T db psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}"` (+`-v ON_ERROR_STOP=1`), nunca `DATABASE_URL` directa. Los 2 scripts de servicio en contenedor usan `set -eu` + `: "${VAR:?...}"` sin fuentear `.env`. Destructivas exigen confirmación escrita (CARGAR/RESTAURAR). Confianza: alta.

  **Patrones transversales de alto nivel** (para Fases 5/6/9):
  - **"PostgreSQL-centric"** como patrón dominante: la base decide (backoff, idempotencia, permisos, totales); worker/n8n/web/scripts solo invocan funciones SQL y traducen formatos. Cada servlet de periferia es un *adapter* a la región que le toca.
  - **Contrato `{ok:boolean, motivo?, mensaje?}`** es el lenguaje común entre SQL y las tres capas periféricas (bot lee `v_r->>'ok'`, web hace `return fila?.r`, worker devuelve `{enviado:false, motivo}`).
  - **Dos dialectos de error** según la capa: en SQL fracasos esperados → `ok:false` (156) y violaciones → `RAISE` con ERRCODE semántico (12); en el worker, límite de Telegram (403/400) → `ok:false` completado, resto → throw para reintento.
  - **Nomenclatura de canales**: `telegram|web|sistema|job` exactamente en las mismas columnas de canal de auditoría, movimientos, cobro y compras.

- **Incertidumbres**:
  - La base no estaba levantada: los conteos vienen de grep del repositorio en disco y de la lectura de archivos, no de `pg_stat`/`information_schema`; se espera que coincidan al levantar el stack (mismo criterio que Fases 2 y 3).
  - La hipótesis del encargo `errcode='P0001'`/`hint=` resultó **falsa**: el proyecto usa `23514` (check_violation) y `0A000` (append-only) como códigos de negocio, más `42501`/`28000` para permisos/auth. Este patrón quedó corregido en el registro.
  - Los conteos exactos de los agentes que difieren de la verificación directa (p.ej. `consultar/consultarUna` 42→5, `estado_guardar` 75 confirmado, triggers 41→35) se corrigieron arriba con la lectura directa.

### Fase 5 — Reglas de negocio y técnicas

- **Fecha / sesión**: 2026-08-09 / sesión 6
- **Agente**: backend-analyst (apoyo: telegram-analyst, frontend-analyst, security-analyst, database-analyst)
- **Directiva**: detectar reglas existentes en SQL (constraints, triggers, validaciones), worker, Telegram, Next.js, configuración y tests; clasificarlas en MUST / MUST_NOT / SHOULD / PREFERENCE. Cada regla con evidencia `path:line` o identificador. La base no está levantada: el código/disco es la fuente primaria. Nada se corrige en esta fase; los problemas de seguridad se reportan (no se arreglan).

- **MUST** (comportamientos obligatorios demostrados por el código):

  1. **Los permisos son datos y la frontera es SQL.** Toda función de escritura abre con `PERFORM exigir_permiso(p_actor_id, 'modulo.accion')`; el front y el bot solo eligen botones (`085_admin.sql:7-10,55,140,189`; `050_pacientes.sql:965,1047,1218`). Permisos almacenados como datos (`permiso/rol/rol_permiso/usuario_permiso`, `020_identidad.sql`), nunca hardcodeados.
  2. **Contrato de retorno `jsonb {ok, motivo?, mensaje?}`** en toda escritura (`060_cobro.sql:582-583`, `050_pacientes.sql:705-709`). Errores esperados → `ok:false` (156 sitios); violaciones → `RAISE EXCEPTION USING ERRCODE` semántico (`23514` negocio, `0A000` append-only, `42501`/`28000` permisos/auth; `020_identidad.sql:106`, `045_inventario.sql:178,184`, `060_cobro.sql:353,397`).
  3. **Dinero y stock derivado con `numeric`, nunca float.** Montos `numeric(12,2)` (`060_cobro.sql:113-115,181,198`, `045_inventario.sql:74`); `lote.cantidad_actual` es caché mantenida por trigger (`movimiento_aplicar`, `045:196-207`) con `CHECK (cantidad_actual >= 0)` (`045:73`); la verdad son los movimientos.
  4. **Append-only y corrección por reverso.** `evento_auditoria`, `movimiento_inventario`, `pago`, `descuento` sin UPDATE/DELETE/TRUNCATE para `chasquipet_app` (`090_grants.sql:49-59`) + triggers de defensa en profundidad (`045:212-221`, `060:377-380`); un pago se anula con fila `tipo='reverso'` (`060:1240-1248`); `descuento.motivo` NO vacío (`060:182`).
  5. **Confirmación explícita antes de persistir dinero/inventario** en el bot (siempre por callback, nunca en texto): salida `inv:confirmar`→`salida_medicamento` (`046:402-406`), doble confirmación de entrada `com:confirmar`→`com:confirmar2` (`076:552-557`), pago `cob:medio` tras tarjeta con Total (`066:404-414`), herramientas IA `escribe=true`→`ia_accion_pendiente` confirmable con botón (`078:692-709,714-762`).
  6. **El webhook responde <1 s; todo lo pesado se encola en `tarea_async`.** `responseMode:onReceived` devuelve 200 antes de procesar (`01-telegram-webhook.json:9-22`); IA/avisos/recibos van por `encolar_tarea` (`078:950-952,985-996`, `010:237-255`).
  7. **El estado conversacional vive en `conversacion_estado` (n8n no guarda estado)** con `estado_guardar/leer/limpiar` y TTL 2 h (`020:155-211`); si n8n se reinicia el usuario continúa el flujo.
  8. **Identidad y sesiones:** nadie se autoregistra — identidad = `telegram_user_id` provisionado por admin (`058_auth_web.sql:10-12`, `020:117-143`); el superadmin inicial por env (`110_seed_operativo.sql:72-99`) y solo un superadmin puede repartirlo, sin dejarse huérfano (`085_admin.sql:148-160`). Sesión web: token de un solo uso, en BD solo su sha256 (`058:17-19,111-114`), cookie HttpOnly 30 días (`web/src/lib/sesion.ts:16-19`).
  9. **Concurrencia/turnos:** numeración con `pg_advisory_xact_lock` (jamás `MAX(numero)+1` a pelo, `030:103-121`); cola con `FOR UPDATE SKIP LOCKED` (`010:258-276`); máximo 1 turno activo por chat/día (`030:97-101`); 1 sesión por consultorio (`030:42-47`).
  10. **Inmutabilidad clínica y de compras:** consulta firmada solo transiciona a `anulada` (corrección por adenda; `consulta_no_editar_firmada`, `050:244-278`); firmar exige motivo+diagnóstico+tratamiento (`050:1225-1251`); entradas solo editables en `borrador` (`entrada_exigir_borrador`, `070:122-145`); el único ingreso de stock es la confirmación de una entrada (`070`).
  11. **Autenticación web SOLO por Telegram** (código de 6 dígitos o enlace): cero formularios con `password` (`web/src/lib/sesion.ts:6-10`); `runtime='nodejs'` + `force-dynamic` + `no-store` en todo route handler (`api/*/*.ts`); `$1`=actor en las Server Actions (`admin/acciones.ts:38-41`); doble cerradura de permiso web+SQL (`inventario/acciones.ts:12-14`).
  12. **Rate limiting en cada puerta pública**: `login:ip`/`login:tg` 10/h (`058:39,72`), `portal:enlace` 5/h (`077:52`), `turno:chat` 1/60 s (`030:218-222`), `ia:<usuario>` (`078:978`).
  13. **Seguridad perimetral:** secretos solo en `.env` (git-ignored, `.gitignore:3-5`); token del bot por entorno (`docker-compose.yml:106-110`, nunca en el JSON del workflow); la app se conecta como `chasquipet_app` (no dueño, `090:16-22`); la BD solo se publica en `127.0.0.1` (`docker-compose.yml:55`); backup diario con retención (`docker-compose.yml:210-233`, `scripts/backup.sh`).
  14. **El worker delega en la BD:** no escribe `tarea_async` directo (solo `reclamar/completar/fallar/rescatar_tareas`, `worker/src/index.js:115,130,165,184`); backoff y dead-letter los decide la base (`010:286-323`); todo manejador exporta `{tipo, manejar}` (`tareas/index.js:4-6`).
  15. **Política Telegram en el worker:** 429 → esperar `retry_after` (≤60 s) y reintentar 1 vez (`telegram.js:96-101`); 403/`chat not found` → `ok:false` completado sin quemar reintentos (`telegram.js:104-113`); resto → lanzar (`telegram.js:115-118`).

- **MUST_NOT** (prohibido; evidenciado):

  1. **No editar ni borrar movimientos de inventario, pagos, descuentos ni auditoría** (`090_grants.sql:49-59`; corrección solo por reverso o adenda).
  2. **No purgar `evento_auditoria` ni `movimiento_inventario` jamás** (`088_mantenimiento.sql:16-18`); `telegram_update`/tareas solo se purgan vía `mantenimiento_diario()` (`090:61-63,70-74`).
  3. **No autoregistrarse** ni revelar a un Telegram sin usuario si un código era válido (`040:306-313`, `058:80-86`).
  4. **El QR nunca marca urgencia** (prioridad 0 y tipo restringido a `visible_qr`, `030:225-237`; `marcar_urgencia` exige `turnos.priorizar`).
  5. **No enviar recibo/resumen al dueño sin `consentimiento_datos` + `telegram_chat_id`** (habeas data; `worker/src/tareas/enviar_recibo.js:42-47`).
  6. **No login con usuario/contraseña** en el portal (`web/src/lib/sesion.ts:6-10`; NN1 frontend).
  7. **No llamadas HTTP externas desde el servidor web**; solo rutas `/api/*` propias (`web/src/lib/notificaciones.ts`, Server Actions; única URL externa = deep-link `t.me` como dato, `api/entrar/route.ts:48`).
  8. **No publicar el editor de n8n ni exponer la BD** (`proxy/Caddyfile:9-10,15-33`).
  9. **No registrar secretos ni credenciales en git** (`importar-n8n.sh:23-25,48-49` arma la credencial dentro del contenedor y la borra).
  10. **El worker no reimplementa backoff ni mantiene estado de negocio en memoria**, y no usa transacciones manuales (`worker/README.md:19,84-87`; grep `BEGIN|COMMIT|ROLLBACK` = 0 en `worker/src`).
  11. **No se ingresa mercancía vencida** (`parse_fecha` rechaza `< hoy_bogota()`, `076:739-745`).
  12. **No editar contenido de consulta firmada ni línea de cuenta** (quitar y re-agregar; `060:385-404`).

- **SHOULD** (convención fuerte):

  1. **`SECURITY DEFINER` debería fijar `SET search_path`** — hallazgo: no existe ningún `SET search_path` en `db/`; `auditar` (`090:68`) y `mantenimiento_diario` (`090:74`) corren elevadas sin fijarlo (ver Problemas).
  2. **Firma canónica de escritura** `p_actor_id uuid` primero + `p_canal text DEFAULT 'telegram'|'web'` al final (`050_pacientes.sql:674-688`). Reportes con `p_desde/p_hasta` opcionales = mes en curso (`080_reportes.sql:12,24-34`).
  3. **`auditar(...)` con `datos_antes/datos_despues` en toda edición** (`PERFORM auditar`, ~66 sitios; ediciones de admin en 085 lo cumplen).
  4. **Doble cerradura de permiso** (web exige con `exigirPermiso` + SQL re-exige con el actor; `085_admin.sql` vs `admin/acciones.ts`).
  5. **Prefijo de callback `<mod>:` como contrato de despacho** y enrutador por stubs encadenados + `COALESCE`: `turno:`, `inv:`, `cli:`, `cob:`, `com:`, `por:`, `ia:`, `aut:` (`078:1012-1024`; devolver NULL si el prefijo no es suyo, `046:339`).
  6. **FSM con `estado_guardar/leer/limpiar` y TTL 2 h** en todos los flujos con pasos (`046:370`, `056:582`, `066:313`, `076:424`).
  7. **Deduplicación de avisos con `marcarAviso`** (`INSERT ... ON CONFLICT DO NOTHING` en `aviso_turno_enviado`, `worker/src/index.js:62-93`, `035_aviso_turno.sql`); idempotencia de tareas con `clave_unicidad` + UNIQUE parcial (`010:234-235`).
  8. **Acotar la superficie de `GRANT EXECUTE ON ALL FUNCTIONS`** (`090:35`) y preferir menor privilegio (el registrador escribe `config.portal_url` con dueño, `docker-compose.yml:308-312`; debería ser rol acotado).
  9. **Responder todo `callback_query` con `answerCallbackQuery`** (Telegram exige; sino el botón queda girando) — antepuesto en `bot_manejar_update` (`040:562-568`).

- **PREFERENCE** (estilo débil):

  1. **Español (Colombia), hora `America/Bogota`, pesos con separador de miles sin decimales** (`pesos()` `040:28-31`; `Intl.NumberFormat('es-CO', COP)` `web/src/lib/formato.ts:10-14`; IA: "trata de tú", `chasqui_responder.js:74`).
  2. **Mensajes de bot cortos, máx 3 botones por fila, sin tablas ASCII** (`040:99-100`, `056:63-66`; topes de resultados Top 5; cola en viñetas `040:224-253`).
  3. **Versiones de imagen fijas** en el compose (`postgres:16-alpine`, `n8nio/n8n:2.31.5`; excepción `cloudflared:latest`, ver Contradicciones).
  4. **Comentarios en español con referencias a secciones del documento de diseño** (`§2.2.x`, `§5.3`, `§12`) en SQL, worker y web.
  5. **Logs del worker a stdout, una línea por evento, sin colores** (`log.js:3-36`); `git` responsivo: scripts con `set -euo pipefail` y acceso por `docker compose exec -T db psql` (nunca `DATABASE_URL` directa).

- **Incertidumbres**:
  - **"3 intentos máximo" del código de 6 dígitos** (doc `chasquipet.md:400`): el SQL solo incrementa `auth_challenge.intentos` al rechazar (`058:81-83`); el tope de 3 no está en SQL (la contención real es rate limit 10/h). UNKNOWN si vive en el frontend web.
  - La definición íntegra de `v_stock_medicamento` (045) y de `consumir_rate_limit` (010) no se releyó en esta fase; semántica de `posicion`/`cuantos` en `turnos_por_avisar` (`notificar_turnos_proximos.js:26,45`) queda UNKNOWN.
  - `uncaughtException → process.exit(0)` en el worker (`index.js:300-303`) puede enmascarar crashes ante supervisores que miran exit codes; `setTypeParser(20, Number)` (`index.js:31`) tiene riesgo de pérdida de precisión bigint > 2⁵³. Ambos UNKNOWN (opcionalidad del diseño).
  - Variables `WORKER_POOL_MAX`, `TELEGRAM_TIMEOUT_MS`, `WORKER_RESCATE_MIN`, `WORKER_APAGADO_MS` se leen en el código pero **no** se propagan en `docker-compose.yml` ni `env.example` (valen sus defaults).
  - `SESSION_SECRET` documentada e inyectada (`docker-compose.yml:189`) pero jamás leída por `web/src` (ver Contradicciones).
  - Si el botón "Iniciar sesión web" del menú del bot (doc `chasquipet.md:394`) existe: no se halló su superficie; el acceso web real es deep link `web-<id>` y el botón `por:enlace`.

- **Contradicciones doc-vs-código** (nuevas, además de las acumuladas):
  - `web/README.md` y comentarios dicen "los nueve reportes de §10"; el código registra **12** claves (`web/src/lib/reportes.ts:38-259`).
  - "Ruta feliz de 3 toques" del cobro (`066:9-11`) vs **4 toques** reales: `cob:cobrar` → `cob:cta` → `cob:pagar` → `cob:medio` (`066:303-314,390-400,404`).
  - `SESSION_SECRET`: documentada como "firma de cookies" pero las cookies no se firman (token crudo + sha256 en BD; `sesion.ts:11-13`). Variable muerta.
  - SQL crudo inline en la web son **3** (no 2, como decía Fase 3): `lib/clinico.ts:154`, `admin/config/page.tsx:42` y, no reportado antes, `lib/pantalla.ts:44` (`buscarSedeActiva`).
  - `worker/README.md:44-48` documenta 4 variables que el stack no propaga (ver Incertidumbres).

- **Problemas detectados** (solo reporte, derivados de esta fase; se agregan a Problemas):
  - `SECURITY DEFINER` sin `SET search_path` en `auditar` y `mantenimiento_diario` + `GRANT EXECUTE ON ALL FUNCTIONS` a la app (`090_grants.sql:35,68,74`): superficie amplia y riesgo de shadowing si un esquema de `public` precedente es controlable.
  - `900_superadmin.sh:21,28` y `000_n8n_db.sh:43-45` intercalan `'${VAR}'` en SQL sin escapar (frágil si el secreto contiene `'`).
  - `scripts/registrar-publico.sh:79-82` interpola hostname externo en `UPDATE config` con credenciales de dueño.
  - `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` (`docker-compose.yml:112`) permite a cualquier workflow importado leer los secrets del entorno n8n.
  - El `DELETE` de `consulta`/`consulta_adenda` no está bloqueado por trigger (la defensa son las FK); la doc dice "inmutable" y el esquema solo bloquea UPDATE.

### Fase 6 — Constraints automatizables

- **Fecha / sesión**: 2026-08-09 / sesión 7
- **Agente**: security-analyst (apoyo: project-analyst)
- **Directiva**: detectar reglas que puedan convertirse después en validaciones automáticas (imports prohibidos, archivos/tablas prohibidas, patrones obligatorios, funciones SQL obligatorias, operaciones prohibidas, append-only, uso obligatorio de funciones). Clasificar cada una como `BLOCKER` / `ERROR` / `WARNING` según el riesgo real (opinión del plan §8). Solo `BLOCKER` cuando la violación pueda causar corrupción de datos, vulnerabilidad de seguridad, violación arquitectónica crítica, pérdida de integridad o comportamiento irreversible peligroso. Sin evidencia → no registrar. La fuente primaria es el código/esquema en disco (la base no está levantada).

- **Leyenda**: cada constraint tiene `tipo` (según el esquema de StrictContext: `forbidden_import`, `required_pattern`, `forbidden_pattern`, `max_complexity`, `required_test`, `db_constraint`), `check` (validación automática que la detectaría), `remediación` y `evidencia`.

- **BLOCKER** (violación = corrupción/integridad/seguridad/irreversible):

  1. **C6.1 — Append-only real de 4 tablas** (`db_constraint`). `evento_auditoria`, `movimiento_inventario`, `pago`, `descuento` no admiten UPDATE/DELETE/TRUNCATE para `chasquipet_app`; la corrección es un reverso (`tipo='reverso'`), jamás editar la fila. Defense en profundidad: triggers `*_no_editar` (045:212-221, 060:377-380). Severity: **BLOCKER** (perder la capacidad de edición/borrado de estos registros es el modelo de integridad; reotorgarla rompe auditoría y contabilidad).
     - check_sql: `SELECT grantee, table_name, privilege_type FROM information_schema.role_table_grants WHERE grantee='chasquipet_app' AND table_name IN ('evento_auditoria','movimiento_inventario','pago','descuento') AND privilege_type IN ('UPDATE','DELETE','TRUNCATE');` → debe devolver 0 filas.
     - remediación: reinvocar `REVOKE UPDATE, DELETE, TRUNCATE ON %I FROM chasquipet_app` (090:53) y mantener la tabla en el array de 090:49.
     - evidencia: `090_grants.sql:42-59`, `045_inventario.sql:212-221`, `060_cobro.sql:377-380,1240-1248`.

  2. **C6.2 — Nada purga auditoría ni inventario** (`db_constraint`). El único borrado/cambio de ciclo de vida permitido es `mantenimiento_diario()` (088:34-64) sobre `telegram_update`, `conversacion_estado`, `auth_challenge`, `tarea_async`; las sesiones vencidas se marcan `revocada`, no se borran. Un DELETE/JOB futuro sobre tablas append-only es data loss permanente de la trazabilidad. Severity: **BLOCKER**.
     - check_pattern: grep de `DELETE FROM (evento_auditoria|movimiento_inventario|pago|descuento)` en migraciones y funciones → prohibido (también `TRUNCATE`, `DROP TABLE`).
     - remediación: documentar en 088 el ciclo de vida; ninguna función nueva borra de tablas append-only.
     - evidencia: `088_mantenimiento.sql:16-18,44-63`, `090_grants.sql:63`.

  3. **C6.3 — Dinero y stock `numeric`, nunca float/double** (`db_constraint`). Montos `numeric(12,2)`, cantidades `numeric(12,3)` (060:113-115,161,181,198; 045:74-103). El único `real` permitido es `puntaje` (score comparable, no dinero) en 045:275 y 050:430. Una columna de precio/valor/total/cantidad como `real`/`double precision` reintroduce errores de redondeo en cuentas e inventario. Severity: **BLOCKER**.
     - check_sql: `SELECT table_name, column_name, data_type FROM information_schema.columns WHERE data_type IN ('real','double precision') AND (column_name ~ 'precio|valor|total|subtotal|base|cantidad|descuento|monto|tarifa')`.
     - remediación: usar `numeric` con escala explícita (12,2) o (12,3); `real` solo para columnas de scoring.
     - evidencia: `060_cobro.sql:113-115,161-162,181,198`, `045_inventario.sql:74`, `050_pacientes.sql:430`.

  4. **C6.4 — Numeración secuencial con `pg_advisory_xact_lock`, jamás `MAX(numero)+1` a pelo** (`required_pattern`). 030:105-121 documenta y usa el lock (`hashtext('turno:'...)'`); sin él, dos canales concurrentes colisionan en el mismo número (turnos, y en general todo id numerado). Un INSERT de turno/número nuevo sin advisory lock en la misma transacción es corrupción concurrencial. Severity: **BLOCKER**.
     - check_sql: en funciones con `SELECT COALESCE(MAX(n),0)+1` debe existir `pg_advisory_xact_lock` antes del INSERT en la misma función.
     - remediación: anteponer `PERFORM pg_advisory_xact_lock(hashtext('<clave>' || ...))` (030:114).
     - evidencia: `030_turnos.sql:105-121`.

  5. **C6.5 — Toda escritura de negocio valida el actor con `exigir_permiso`** (`required_pattern`). La authz vive en SQL; el front/bot solo eligen botones. Una función nueva con DML sobre tablas de negocio que no abra con `PERFORM exigir_permiso(...)` crea una puerta sin autorización (el cliente puede llamarla directo vía n8n/web). Severity: **BLOCKER**.
     - check_sql: por cada `CREATE FUNCTION` con `INSERT/UPDATE/DELETE`, exigir `exigir_permiso` en el cuerpo. Lista blanca de excepciones (deliberadas): `auditar`, `mantenimiento_diario`, helpers SECURITY DEFINER sin actor, funciones que se llaman internamente YA validadas.
     - remediación: la firma canónica `p_actor_id uuid` primero y validar con el módulo.acción de la función.
     - evidencia: `085_admin.sql:7-10,55,140,189`, `050_pacientes.sql:965,1047,1218`, `020_identidad.sql` (permisos como datos), `web/src/app/(portal)/inventario/acciones.ts:12-14` (la web re-exige).

  6. **C6.6 — La aplicación se conecta como `chasquipet_app`, no como dueño** (`db_constraint`). La BD solo se publica en `127.0.0.1` (compose:55); la app usa rol sin superpoderes (090:16-22). Conectar lógica de negocio con `POSTGRES_USER` (dueño) o hacerla depender de privilegios de dueño rompe la frontera append-only/auditoría. Severity: **BLOCKER** (regresión que conecte al dueño por fuera de la puerta conocida del registrador desplaza toda la seguridad).
     - check: en docker-compose/scripts, `DATABASE_URL`/GRANT de servicios de app deben apuntar a `chasquipet_app`.
     - remediación: mantener el patrón 090; las excepciones de dueño se reportan (registrador, `docker-compose.yml:308-312`) y no se repiten.
     - evidencia: `090_grants.sql:16-22,33-35`, `docker-compose.yml:55`.

  7. **C6.7 — Secretos y credenciales jamás como literales en código/git** (`forbidden_pattern`). Tokens (Telegram), DeepSeek API key y SESSION_SECRET solo por entorno (compose:109,153,163,189); `.env` git-ignored (`.gitignore:3-5`). Un secreto real en el repo/commit es una filtración permanente e irreversible. Severity: **BLOCKER**.
     - check_pattern: regex de tokens (`\d+:[A-Za-z0-9_-]{30,}`), `sk-...`, `SESSION_SECRET=` con valor ≠ vacío/env, en trackeados por git.
     - remediación: nunca versionar; usar `${VAR}` en compose y `process.env` en el código; rotar si se filtra.
     - evidencia: `.gitignore:3-5`, `docker-compose.yml:106-110` (token por env, no en el JSON del workflow), `worker/src/telegram.js:66` (lee de env).

  8. **C6.8 — El webhook responde antes de procesar; lo pesado se encola** (`required_pattern`). `responseMode:onReceived` (01:9-22) garantiza <1 s y sin reintentos de Telegram; IA, avisos, recibos y confirmación de escrituras van por `encolar_tarea` (078:950-996, 010:237-255). Una salida nueva síncrona en la línea del webhook vuelve a poner el latido del bot bajo carga (violación §2.2.3). Severity: **BLOCKER** si la salida es pesada (IA/PDF/multi-envío) dentro del webhook.
     - check_pattern: en `n8n/workflows/*.json` y en SQL, cualquier operación pesada nueva debe pasar por `encolar_tarea`/tarea_async, no ejecutarse en el nodo del webhook.
     - remediación: envolver en función SQL que llama `encolar_tarea` con `clave_unicidad`.
     - evidencia: `n8n/workflows/01-telegram-webhook.json:9-22`, `010_base.sql:237-255`, `078_chasqui_ia.sql:950-996`.

  9. **C6.9 — Escribir dinero/inventario solo con confirmación explícita por botón** (`required_pattern`). La IA nunca ejecuta sola herramientas con `escribe=true`: deja propuesta en `ia_accion_pendiente` y exige botón (078:692-709,714-762; regla 3 de 078:28). Entradas: doble confirmación `com:confirmar→com:confirmar2` (076:552-557); salidas `inv:confirmar` (046:402-406); pago `cob:medio` (066:404-414). Una acción de escritura auto-ejecutada (chat/IA) sobre dinero/inventario es comportamiento irreversible sin consentimiento. Severity: **BLOCKER**.
     - check: nueva herramienta `ia_herramienta` con `escribe=true` y `critica` debe quedar forzosamente en propuesta confirmable; nueva salida del bot que persiste dinero/stock debe pasar por callback de confirmación.
     - remediación: patrón `escribe+campo→ia_accion_pendiente→botón` (078).
     - evidencia: `078_chasqui_ia.sql:120,128,681,692-762`, `046_bot_inventario.sql:402-406`, `076_bot_compras.sql:552-557`, `066_bot_cobro.sql:404-414`.

- **ERROR** (violación = debilita integridad/seguridad/arquitectura, sin corrupción directa):

  10. **C6.10 — `SECURITY DEFINER` debe fijar `SET search_path`** (`db_constraint`). Hoy 0 funciones lo fijan; `auditar` y `mantenimiento_diario` corren elevadas sin search_path (090:68,74) → riesgo de shadowing si un esquema precedente de `public` es controlable. Toda función nueva SECURITY DEFINER sin `SET search_path` = **ERROR**.
      - check_sql: `SELECT p.oid::regprocedure FROM pg_proc p WHERE p.prosecdef AND p.prosrc NOT LIKE '%search_path%';` → debe coincidir solo con las actuales (∞, auditables).
      - remediación: `SET search_path = public, pg_temp` al inicio del cuerpo; fijar también en las 2 existentes (deuda, Fase 5 Problemas).
      - evidencia: `090_grants.sql:35,68,74`, `088_mantenimiento.sql:20-22` (comentario), Fase 5 §Problemas.

  11. **C6.11 — Nueva tabla inmutable debe entrar en la lista de 090** (`db_constraint`). Cualquier tabla agregada con ciclo de vida inmutable (historial, registros contables) debe añadirse al array de 090:49 y protegerse; hacerlo inmutable solo por convención (sin REVOKE/trigger) es esconder el modelo real. Severity: **ERROR**.
      - check: por cada tabla nueva con semántica append-only, exigir entrada en `090_grants.sql` o FK/trigger de defensa.
      - evidencia: `090_grants.sql:42-59` (array + REVOKE).

  12. **C6.12 — Cero SQL crudo inline en la web fuera de funciones SQL** (`forbidden_pattern`). La arquitectura es "lógica 100% en SQL"; los 3 spots existentes (`lib/clinico.ts:154`, `lib/pantalla.ts:44`, `admin/config/page.tsx:42`) son deuda conocida (Fase 5). Nuevos `.query(<SQL crudo>)` en `web/src/app` (server actions/páginas) o en `lib` duplican reglas de negocio fuera de la base. Severity: **ERROR** (violación arquitectónica crítica si crece; regresión del modelo PostgreSQL-centric).
      - check_pattern: `rg "\.query\(" web/src/app web/src/lib` — excepto los autorizados en una lista blanca; el resto debe llamar funciones SQL.
      - remediación: envolver en función SQL STABLE (`filtro_*`/`*_json`) y llamarla con `SELECT fn($1)`.
      - evidencia: Fase 5 §Contradicciones (3 spots), `web/src/lib/clinico.ts:154`, `web/src/lib/pantalla.ts:44`, `web/src/app/(portal)/admin/config/page.tsx:42`.

  13. **C6.13 — Route handlers y Server Actions con cabeceras obligatorias** (`required_pattern`). Todos los `route.ts` de la API: `runtime='nodejs'`, `force-dynamic`, y `no-store` salvo `/health` y `/salir`; Server Actions toman `$1`=actor de sesión (nunca del body) y re-exigen permiso en SQL (doble cerradura). Un route handler estático o que tome el actor del cliente rompe autenticación/SSE. Severity: **ERROR**.
      - check_pattern: en `web/src/app/**/route.ts` exigir las 2 exportaciones; prohibir `dynamic='force-static'`/`revalidate`.
      - remediación: cabeceras fijas por plantilla del skill web (Fase 9) + revisión en code review.
      - evidencia: `web/src/app/api/*/*/route.ts` (todos con force-dynamic+no-store), `web/src/app/(portal)/admin/acciones.ts:38-41` ($1=actor).

  14. **C6.14 — Callbacks de bot con prefijo de módulo `<mod>:`** (`required_pattern`). El enrutador despacha por prefijo `turno:`/`inv:`/`cli:`/`cob:`/`com:`/`por:`/`ia:`/`aut:`, cada stub devuelve NULL si el prefijo no es suyo (078:1012-1024, 046:339). Un callback sin prefijo o con prefijo de otro módulo rompe el menú. Severity: **ERROR**.
      - check_pattern: todo `callback_data` empezando con `[a-z]+:` donde el prefijo exista en el router; los stubs deben terminar devolviendo NULL cuando no es suyo.
      - evidencia: `078_chasqui_ia.sql:1012-1024`, `046_bot_inventario.sql:339` (contrato de devolución NULL).

  15. **C6.15 — Rate limiting en cada puerta pública** (`required_pattern`). `consumir_rate_limit` en login:ip/login:tg (058:39,72), portal:enlace (077:52), turno:chat (030:218-222), ia:<usuario> (078:978). Un endpoint/webhook nuevo SIN autenticar y sin `consumir_rate_limit` = abuso/DoS. Severity: **ERROR**.
      - check_pattern: toda función SQL llamable sin `exigir_permiso` (puerta pública) debe consumir `consumir_rate_limit` con clave por recurso.
      - evidencia: `058_auth_web.sql:39,72`, `077_portal_enlace.sql:52`, `030_turnos.sql:218-222`, `078_chasqui_ia.sql:978`, `010_base.sql:344-365`.

  16. **C6.16 — Worker: manejadores exportan `{tipo, manejar}` y no escriben `tarea_async` directo** (`required_pattern`). Contrato `index.js:4-6`; la cola se maneja solo con `reclamar_tareas`/`completar_tarea`/`fallar_tarea`/`rescatar_tareas_colgadas` (index.js:115,130,165,184). Un manejador sin `export const tipo` no entra al Map; un INSERT/DELETE directo sobre `tarea_async` rompe dedup/backoff. Severity: **ERROR**.
      - check_pattern: `src/tareas/*.js` deben exportar `tipo` y `manejar`; el único DML sobre tarea_async vive en SQL (010).
      - evidencia: `worker/src/tareas/index.js:4-6,41`, `worker/src/index.js:115,130,165,184`, `worker/README.md:19,84-87`.

  17. **C6.17 — Web: sin `password` ni HTTP externo** (`forbidden_pattern`). Cero campos `password` (0 matches en `web/src`); toda salida va por `/api/*` propias, nunca fetch a dominios ajenos (única URL externa = deep link `t.me` como dato, `api/entrar/route.ts:48`). Un `type="password"` (login por credenciales) o un fetch al exterior reintroduce vector y rompe la autenticación-solo-Telegram. Severity: **ERROR**.
      - check_pattern: `rg -in "password" web/src` → 0; `rg -n "fetch(" web/src` → solo rutas propias/funciones sanitizadas.
      - evidencia: `web/src/lib/sesion.ts:6-10` (autenticación solo por código/enlace), `web/src/lib/notificaciones.ts` (solo /api).

  18. **C6.18 — Tablas clínicas/financieras "inmutables" con defensa real, no solo FK** (`db_constraint`). `consulta` firma→solo `anulada` (050:244-278) pero su DELETE no está bloqueado por trigger (la defensa son las FK — gap reportado en Fase 5); `cuenta_linea_no_editar` (060:385-404) y `entrada_exigir_borrador` (070:122-145) sí tienen trigger. Toda transición prohibida de estado (firmar→editar, borrar historial) debe estar defendida por trigger/REVOKE. Severity: **ERROR**.
      - check_sql: por cada `estado` con FSM inmutable existe un trigger `BEFORE UPDATE/DELETE` o REVOKE que la imponga.
      - evidencia: `050_pacientes.sql:244-278` (función), Fase 5 §Problemas (DELETE sin trigger), `060_cobro.sql:385-404`, `070_compras.sql:122-145`.

- **WARNING** (convención/deuda sólida, impacto menor o condicional):

  19. **C6.19 — Acotar `GRANT EXECUTE ON ALL FUNCTIONS` y privilegios mínimos** (`db_constraint`). 090:35 + ALTER DEFAULT PRIVILEGES (090:82) otorgan EXECUTE global; el registrador escribe `config.portal_url` como dueño (compose:308-312). Dejar el patrón actual prolifera superficie. Severity: **WARNING**.
      - check_sql: `GRANT EXECUTE.*ON ALL FUNCTIONS` presente → revisión periódica; funciones SECURITY DEFINER sensibles a prueba de shadowing.
      - evidencia: `090_grants.sql:35,82`, `docker-compose.yml:308-312`.

  20. **C6.20 — Imágenes con versión fija (máx. cloudflared)** (`required_pattern`). `postgres:16-alpine`, `n8nio/n8n:2.31.5`; excepción `cloudflared:latest` (Fase 5 Contradicciones). Una imagen nueva sin tag fijo en el compose mata la reproducibilidad. Severity: **WARNING**.
      - check_sql/compose: `image:` sin `:versión` → WARNING salvo `cloudflared`.
      - evidencia: `docker-compose.yml` (imágenes), Fase 5 §Contradicciones.

  21. **C6.21 — `N8N_BLOCK_ENV_ACCESS_IN_NODE` debe estar en `true`** (`db_constraint`). Hoy `false` (compose:112): cualquier workflow importado puede leer los secrets del entorno n8n. Con workflows versionados propios no es explotado, pero es configuración frágil. Severity: **WARNING**.
      - remediación: fijar `true` y pasar los secretos por configuración de n8n referenciada; no importar workflows de terceros.
      - evidencia: `docker-compose.yml:112`, Fase 5 §Problemas.

  22. **C6.22 — Escrituras críticas auditadas con `datos_antes/datos_despues`** (`required_pattern`). Las escrituras de cuenta, pago, inventario, config, usuarios y admin llaman `auditar` con los valores anterior/nuevo (085 lo exige). Toda escritura nueva que cambie estado crítico sin `auditar` pierde trazabilidad. Severity: **WARNING** (es patrón repetido, no una regla dura: hay escrituras auxiliares que no auditan).
      - check_pattern: funciones DML sobre tablas financieras/clínicas/admin → exigir `auditar(...)` en el cuerpo.
      - evidencia: `010_base.sql:122-138` (definición `auditar`), Fase 4 (66 sitios), `085_admin.sql` (ediciones con auditoría).

  23. **C6.23 — Verificación mínima tras cambios (asociada a "required_test")** (`required_test`). No hay suite; el estándar real es: migraciones aplicables con `psql -v ON_ERROR_STOP=1` sobre una BD de demo (`scripts/cargar-demo.sh`), `npm run typecheck` en web y `npm run check` en worker. Nuevas migraciones/funciones deben acompañarse de una invocación recién creada que demuestre el comportamiento (mismo criterio de Fase 1). Severity: **WARNING** (no hay tests para quebrantar aún).
      - check_pattern: directorio `db/migrations/*.sql` siempre ejecutable en orden alfabético desde una BD limpia; `web && npm run typecheck`; `worker && npm run check`.
      - evidencia: Fase 1 §TESTING (no existen tests), `scripts/cargar-demo.sh`, `web/package.json`, `worker/package.json`, README (estrategia de verificación).

- **max_complexity** (sin evidencia de tope): no se registró ningún límite de tamaño/índice de ciclomática en el repositorio (las funciones SQL grandes como `bot_manejar_update` o `080_reportes` no imponen tope). **No se inventa**.

- **forbidden_import** (sin evidencia): no hay restricciones de imports en el código (no existe lint que las prohíba). Las restricciones de red del web (`web/src/lib/notificaciones.ts`) se capturan como C6.17. No se registra constraint de imports porque no hay prohibición existente.

- **Incertidumbres**:
  - Las check_sql/check_pattern propuestas son **candidatos**: el target de ejecución (grep local, script psql, lint configurado) no está decidido; la automatización real cae en Fases 14/17 (StrictContext `validate_action`).
  - La lista blanca de excepciones a `exigir_permiso` (C6.5) y de SQL crudo permitido (C6.12) no está escrita en ningún archivo; hoy es conocimiento implícito de las fases previas. UNKNOWN si debe formalizarse como archivo de configuración o dejarse en las secciones de skill (Fase 9).
  - C6.19/C6.21 dependen de decisiones de configuración (no de código); su automatización requiere un step de infra que no existe (UNKNOWN si se automatiza con juegos de reglas del compose).
  - El DELETE de `consulta` sin trigger (C6.18) queda como gap documentado (Fase 5 Problemas); si debe convertirse en constraint BLOCKER o ERROR dependerá de la decisión de corregirlo o no (fuera del alcance de esta misión: solo se reporta).
  - Severidad de C6.8: no todas las salidas del webhook son pesadas; la frontera "pesado = en cola" es subjetiva salvo los casos nombrados (IA, PDF, tareas multi-destinatario). UNKNOWN en automatizar el umbral exacto.

### Fase 7 — Decisiones arquitectónicas (ADRs)

- **Fecha / sesión**: 2026-08-09 / sesión 8
- **Agente**: context-architect (apoyo: project-analyst)
- **Directiva**: crear ADRs únicamente para decisiones que expliquen *por qué* el sistema funciona de determinada manera, cada una verificada contra el código/esquema real (no contra la documentación). No crear ADR solo porque una tecnología se usa. La base no está levantada: la evidencia es el código en disco (migraciones + worker + web + n8n + infra), ya validada en Fases 2–6.

- **ADRs registrados** (title / componente / pattern / decision_rationale / constraints / status / evidencia / confianza):

  1. **ADR-01 — PostgreSQL es la fuente de verdad y el único dueño de los datos.** `DATABASE (global)` · pattern: *PostgreSQL-centric, single source of truth*.
     - rationale: todo dato y toda decisión de negocio vive en `public`; los componentes periféricos (n8n, worker, web, scripts) no recalculan reglas ni guardan estado de negocio propio; se conectan como rol acotado `chasquipet_app`, nunca como dueño. Esto hace que el bot y el portal compartan exactamente la misma lógica y que la auditoría/integridad no dependa de la buena fe de un proceso externo.
     - constraints: C6.6 (rol de app, no dueño), C6.1 (append-only), C6.12 (cero lógica SQL en web).
     - evidencia: `090_grants.sql:5-9` (comentario de diseño + REVOKE), `090_grants.sql:16-22` (roles LOGIN sin superpoderes), `docker-compose.yml:55` (BD solo en 127.0.0.1), `worker/src/index.js:8-14` (la base decide reclamo/backoff), `web/src/lib/db.ts` (pool a funciones SQL).
     - confianza: ALTA (reforzada por Fases 2–6; 282 funciones, 0 lógica en periferia).

  2. **ADR-02 — La lógica de negocio está en funciones SQL, no en las apps.** `DATABASE (282 funciones SQL)` · pattern: *business logic as SQL functions; las apps son adapters*.
     - rationale: cada dominio se expone como funciones de lectura (STABLE) y escritura con la firma canónica `p_actor_id uuid` primero + `p_canal text DEFAULT 'telegram'` al final, que validan con `exigir_permiso` y devuelven `jsonb {ok:…}`. Una sola implementación de rangos, inmutabilidad, totales y permisos sirve a bot y web; agregar superficie (un reporte, un callback) no requiere tocar varias apps.
     - constraints: C6.5 (toda escritura exige `exigir_permiso`), C6.12 (SQL crudo en web = excepción deuda), C6.13 (server actions → funciones SQL con `$1`=actor).
     - evidencia: `050_pacientes.sql:674-688` (firma canónica), `060_cobro.sql:582-583` (contrato `{ok,…}`), `020_identidad.sql:92-113` (tiene/exigir_permiso), `web/README.md:163-170` (la web "solo lee la lista y llama las mismas funciones que el bot"), `worker/src/index.js:8-14`.
     - confianza: ALTA.

  3. **ADR-03 — n8n es una capa fina de transporte, sin estado ni lógica de negocio.** `N8N` · pattern: *thin transport layer; los jobs solo llaman funciones SQL o encolan*.
     - rationale: el webhook contesta 200 al instante (`onReceived`), ejecuta dedup+resolución (2 funciones SQL) y traduce las `acciones` JSONB del router a llamadas REST de la Bot API; los 3 jobs de cron solo llaman funciones SQL o `encolar_tarea`. Guardar estado en n8n reintroduciría un segundo dueño de la verdad y rompería la continuidad de las conversaciones ante reinicios.
     - constraints: C6.8 (webhook <1 s → todo lo pesado a `tarea_async`), C6.14 (solo traduce acciones, no las decide).
     - evidencia: `n8n/workflows/01-telegram-webhook.json:6-111` (5 nodos: webhook→postgres→code→httpRequest→postgres), `02/03/04-job-*.json` (cada job = scheduleTrigger→postgres), `docker-compose.yml:73` (n8n `2.31.5`).
     - confianza: ALTA.

  4. **ADR-04 — El trabajo diferido se encola en `tarea_async` y lo drena un worker sin estado; la BD decide reintentos y dead-letter.** `WORKER + DATABASE (cola)` · pattern: *queue + drenador; la base adjudica, el worker despacha*.
     - rationale: el webhook debe responder en <1 s (§2.2.3); IA, avisos, recibos y confirmaciones diferidas se encolan con `encolar_tarea`. `reclamar_tareas` usa `FOR UPDATE SKIP LOCKED`, así N replicas del worker corren sin coordinación; el backoff exponencial (`LEAST(30·2^(intentos-1),3600)`), el agotamiento a `fallida` y el aviso al superadmin viven en la base, no en el worker. El worker solo reclama, ejecuta y reporta (`completar_tarea`/`fallar_tarea`).
     - constraints: C6.16 (manejadores `{tipo, manejar}`, no DML directo sobre `tarea_async`), C6.8.
     - evidencia: `010_base.sql:210-276` (tabla + `encolar_tarea` + `reclamar_tareas` SKIP LOCKED), `010_base.sql:286-323` (backoff + dead-letter + `notificar_superadmin`), `worker/src/index.js:23-24,164-180`, `worker/src/index.js:115,130,165,184`, `worker/README.md:19,84-87`.
     - confianza: ALTA.

  5. **ADR-05 — Telegram: router SQL único + despacho modular por stubs encadenados + salida por `acciones` JSONB que n8n traduce.** `TELEGRAM` · pattern: *máquina de estados en DB, prefijos `<mod>:`, COALESCE de stubs, contrato `{acciones:[]}`*.
     - rationale: toda la conversación (estado en `conversacion_estado`, permisos, menús) vive en SQL para que un reinicio de n8n no pierda el flujo; cada módulo registra su `bot_<mod>_callback/texto/media` con `CREATE OR REPLACE` y devuelve NULL si el prefijo no es suyo, y el orquestador final los encadena con `COALESCE` (cierre en 078). n8n no decide qué responder: traduce mecánicamente `acciones` a `sendMessage`/`editMessageText`/`answerCallbackQuery`.
     - constraints: C6.14 (prefijo `<mod>:` como contrato + retorno NULL), C6.9 (escrituras de dinero/inventario solo por callback de confirmación), MUST 5 y 7 de Fase 5.
     - evidencia: `040_bot_turnos.sql:63-95` (stubs vacíos), `040_bot_turnos.sql:258-570` (router `bot_manejar_update`), `078_chasqui_ia.sql:1012-1043` (órdenes COALESCE finales), `078_chasqui_ia.sql:877` (guardia de prefijo), `046_bot_inventario.sql:339` (`IF v_partes[1] <> 'inv' THEN RETURN NULL`), `040_bot_turnos.sql:33-47` (`accion_enviar`/`accion_editar`), `n8n/workflows/01-telegram-webhook.json:50`.
     - confianza: ALTA.

  6. **ADR-06 — Los permisos son datos y la frontera de autorización es SQL.** `IDENTIDAD / DATABASE` · pattern: *RBAC con permisos como filas; `exigir_permiso` en cada escritura; el front y el bot solo eligen botones*.
     - rationale: la identidad es Telegram (no hay autoregistro ni usuario/contraseña en la web); `usuario/rol/permiso/rol_permiso/usuario_permiso` son datos compartidos entre bot y portal, y la vista `v_usuario_permiso` alimenta el menú del bot y los checks del portal. `exigir_permiso` al inicio de cada función de escritura (y de nuevo en el front con `exigirPermiso` = doble cerradura) hace que ninguna nueva pantalla pueda olvidar autorizar.
     - constraints: C6.5 (toda escritura exige permiso), C6.17 (sin `password` ni HTTP externo en web), C6.13 (server actions toman `$1`=actor de sesión).
     - evidencia: `020_identidad.sql:75-113` (`v_usuario_permiso`, `tiene_permiso`, `exigir_permiso`), `020_identidad.sql:117-143` (identidad por Telegram provisionado por admin, nunca autoregistro), `085_admin.sql:7-10,140,189` (permisos de admin), `web/src/lib/sesion.ts:51-65` (`puede`/`exigirPermiso`), `110_seed_operativo.sql:72-99` (superadmin por env).
     - confianza: ALTA.

  7. **ADR-07 — Auditoría procedimental con un único punto de escritura (`auditar()`) sobre una tabla append-only.** `DATABASE (auditoría)` · pattern: *audit function SECURITY DEFINER → `evento_auditoria`; sin trigger de auditoría*.
     - rationale: `evento_auditoria` guarda `entidad/entidad_id/accion/usuario/canal/datos_antes/datos_despues/detalle`; la app no tiene UPDATE/DELETE/TRUNCATE sobre ella (por rol y por diseño), así la trazabilidad no depende de que el llamador "se porte bien". `auditar()` corre SECURITY DEFINER (090:68) porque la app no puede escribir directo; se invoca con `PERFORM auditar(...)` (~66 sitios). Nunca se purga (088:16-18).
     - constraints: C6.1 (append-only de `evento_auditoria`), C6.2 (jamás purgar auditoría), C6.22 (escrituras críticas auditadas con antes/después), C6.10 (SECURITY DEFINER debe fijar `SET search_path` — hoy deuda).
     - evidencia: `010_base.sql:122-138` (definición `auditar`), `010_base.sql:103-116` (tabla), `090_grants.sql:42-59,68` (REVOKE + SECURITY DEFINER), `088_mantenimiento.sql:16-18` (no se purga), Fase 4 (66 `PERFORM auditar`).
     - confianza: ALTA.

  8. **ADR-08 — Idempotencia como primitiva de base: `ON CONFLICT` + UNIQUE parcial + `clave_unicidad`.** `DATABASE (base / telegram_update / aviso_turno_enviado / tarea_async)` · pattern: *dedup atómico por clave, sin estado en periferia*.
     - rationale: Telegram reintenta los updates (sin dedup se duplicarían turnos y movimientos); los avisos no deben repetirse y una tarea no debe encolarse dos veces. La decisión se hace en la **misma** instrucción (`INSERT … ON CONFLICT DO NOTHING`) con índices UNIQUE parciales, de modo que no hay ventana de carrera ni necesidad de transacciones en el worker.
     - constraints: C6.8 (encolado con `clave_unicidad`), MUST 7 (SHOULD) de Fase 5 (dedup con `marcarAviso`).
     - evidencia: `010_base.sql:191-193` (dedup `telegram_update` con `RETURN FOUND`), `010_base.sql:234-235,251` (UNIQUE parcial + `ON CONFLICT DO NOTHING` en `encolar_tarea`), `035_aviso_turno.sql:1-16` (índice `(turno_id,tipo)` + dedup), `worker/src/index.js:72-93` (`marcarAviso`), `010_base.sql:261-276` (SKIP LOCKED).
     - confianza: ALTA.

  9. **ADR-09 — Append-only por REVOKE + triggers de defensa en profundidad; corrección por reverso, jamás edición.** `DATABASE` · pattern: *immutability por rol + triggers `*_inmutable`; reversos (`tipo='reverso'`) y adendas*.
     - rationale: `evento_auditoria`, `movimiento_inventario`, `pago` y `descuento` son registros contables/clínicos cuyo valor está en que nadie —ni un job— pueda editar o borrar filas; un pago mal registrado se anula con una fila `tipo='reverso'`, un movimiento con otro de signo opuesto, y una consulta firmada solo transiciona a `anulada` o se corrige por adenda. En `telegram_update` solo se permite UPDATE (marcar `procesado`), nunca DELETE desde la app (la retención la maneja `mantenimiento_diario`).
     - constraints: C6.1, C6.2, C6.11, C6.18; MUST_NOT 1 y 2 de Fase 5.
     - evidencia: `090_grants.sql:42-63` (REVOKE + array de tablas), `045_inventario.sql:212-221` (`movimiento_inmutable`, 0A000), `060_cobro.sql:377-380` (`pago_inmutable`/`descuento_inmutable`), `060_cobro.sql:1240-1248` (reverso), `088_mantenimiento.sql:16-18` (no purga append-only), `050_pacientes.sql:277` (`consulta_no_editar_firmada`).
     - confianza: ALTA.

  10. **ADR-10 — Manejo temporal: fechas de negocio en `America/Bogota`, almacenamiento en UTC (`timestamptz`).** `DATABASE + infraestructura` · pattern: *`hoy_bogota()`/`ahora_bogota()` como única puerta de fecha de negocio; `TZ`/`PGTZ` en todos los contenedores*.
      - rationale: día operativo, corte de caja, numeración de turnos y lotes vencidos se calculan en la zona hora legal de Colombia; en BD se guardan `timestamptz` (UTC) y los contenedores arrancan con `TZ=America/Bogota` para que procesos (worker, web, n8n) y logs coincidan en la misma hora sin conversiones dispersas.
      - constraints: ninguno duro (convención arraigada); se liga a la PREFERENCE 1 de Fase 5.
      - evidencia: `010_base.sql:12-22` (`hoy_bogota`/`ahora_bogota` con `AT TIME ZONE 'America/Bogota'`), `docker-compose.yml:44-45,84-85,150,218-219` (`TZ`/`PGTZ` en db, n8n, worker, backup), `worker/src/log.js` (`Intl.DateTimeFormat es-CO`).
      - confianza: ALTA.

  11. **ADR-11 — Portal web: capa delgada Next.js; sesión solo por Telegram; pantalla en tiempo real vía `LISTEN/NOTIFY` con fallback.** `WEB` · pattern: *thin Next.js App Router; identidad = Telegram; SSE + polling, single `LISTEN` multiplexado*.
      - rationale: no hay usuarios propios del portal ni contraseñas — la identidad es Telegram (código de 6 dígitos o enlace de un solo uso) y la cookie guarda un token del cual en BD solo existe su sha256; cada página del portal corta la sesión en el layout y los permisos se leen de `v_usuario_permiso` (la web nunca decide). La pantalla pública se mantiene con UNA conexión `LISTEN pantalla_turnos` multiplexada (evita agotar conexiones por monitor) y cae a polling de 5 s si el SSE falla.
      - constraints: C6.13 (route handlers `nodejs`+`force-dynamic`+`no-store`), C6.17 (sin password ni HTTP externo), C6.12 (SQL crudo = deuda de 3 spots).
      - evidencia: `web/src/lib/sesion.ts:16-37,59-65`, `058_auth_web.sql:136-201` (sha256 + `sesion_por_token`), `077_portal_enlace.sql:36-80` (challenge ya aprobado de un solo uso), `030_turnos.sql:699` (`pg_notify 'pantalla_turnos'`), `web/src/lib/notificaciones.ts:1-124` (multiplexor + reconexión), `web/src/lib/db.ts:9-12` (`DATABASE_URL_DIRECTA` por LISTEN), `web/src/app/pantalla/[sede]/vista-pantalla.tsx` (corte a polling).
      - confianza: ALTA.

  12. **ADR-12 — Integraciones externas como adapters aislados: Bot API por webhook + DeepSeek SOLO en el worker con puerta de confirmación + túnel Cloudflare.** `EXTERNAL INTEGRATIONS` · pattern: *todo secreto por env; la IA nunca escribe sola; la web no hace HTTP externo*.
      - rationale: el acceso exterior único es Telegram (entrada webhook vía Caddy→n8n, salidas por worker/n8n con token solo por entorno) y el túnel Cloudflare publica solo el proxy; DeepSeek (única IA) vive únicamente en el worker: el modelo escoge herramientas y para las de `escribe=true` deja una propuesta en `ia_accion_pendiente` que exige botón (el worker jamás ejecuta escrituras). Ninguna credencial se versiona; la web no llama HTTP externo, solo rutas propias.
      - constraints: C6.7 (secretos nunca en git), C6.9 (IA de escritura con confirmación), C6.21 (`N8N_BLOCK_ENV_ACCESS_IN_NODE`), MUST_NOT 7 y 9 de Fase 5.
      - evidencia: `078_chasqui_ia.sql:120,128,656-762` (`ia_llamar`/`ia_confirmar`, `escribe`), `worker/src/tareas/chasqui_responder.js:40-50,166-185` (SDK openai, `DEEPSEEK_API_KEY`, modelo por `config_txt`), `worker/src/telegram.js:66` (token por env), `docker-compose.yml:106-110,153,163,189` (env secrets), `proxy/Caddyfile:22-24` (`/webhook/*`→n8n), `docker-compose.yml:159-166,275-317` (cloudflared + registrador).
      - confianza: ALTA.

- **ADRs descartados deliberadamente** (no se registran como ADR porque no explican *por qué* o carecen de decisión verificable):
  - "usar Next.js 16 / React 19 / n8n 2.31.5 / PostgreSQL 16": tecnología elegida, no decisión arquitectónica con rationale demostrable en el código.
  - "qué es `db/seeds/`" y "qué hace `N8N_INTERNAL_URL`": UNKNOWN, sin evidencia → se mantienen como incertidumbres, no como decisiones.
  - "autenticación por código de 6 dígitos" como ADR aparte: queda absorbida en ADR-06/ADR-11 (es consecuencia de "identidad = Telegram").

- **Incertidumbres**:
  - Los ADRs se basan en el código en disco; la BD no estaba levantada, así que el comportamiento dinámico (dedup, backoff, triggers) se verificó por su implementación, no por ejecución en vivo (mismo criterio de Fases 2–6).
  - ADR-07/09 dependen del rol `chasquipet_app`: si en producción algo se conectara como dueño, las salvaguardas de rol no aplicarían (el único punto de dueño conocido es el registrador, `docker-compose.yml:308-312` — reportado en Fase 5).
  - ADR-05 asume el orquestador final de 078 (ia→inv→cli→cob→com→por→auth); si el worker desplegado no incluye `078_chasqui_ia.sql`/`chasqui_responder.js` (untracked), en producción esos módulos no existen aún (UNKNOWN de Fase 1).
  - "¿El registro de los ADRs debe poblar `architecture_decisions` en StrictContext?" — Sí, en Fase 14 (poblamiento) con este catálogo como entrada; esta fase solo define el conocimiento.

### Fase 8 — Reconstruir los agentes

- **Fecha / sesión**: 2026-08-09 / sesión 9
- **Agente**: context-architect
- **Directiva** (plan §10): determinar qué roles de ingeniería se necesitan para trabajar sobre el repositorio, basados en las **responsabilidades reales** encontradas (Fases 0–7), no en la doc. Candidatos a investigar: `planner`, `sql-engineer`, `telegram-engineer`, `backend-engineer`, `frontend-engineer`, `integration-engineer`, `reviewer`. No crear agentes innecesarios. Cada agente con `name / role / objective / responsibilities / allowed_tools / forbidden_tools / required_skills / review_required`.
- **Resultado de la investigación**: los **7 candidatos** del plan tienen evidencia real suficiente; no se añade ninguno fuera de esa lista ni se funde ninguno (nota de solapamiento en Incertidumbres). Estos agentes de trabajo reemplazan conceptualmente a los **9 agentes de análisis** ya poblados en StrictContext (project-analyst, database-analyst, backend-analyst, telegram-analyst, frontend-analyst, integration-analyst, security-analyst, context-architect, context-reviewer), que fueron la jerarquía de la misión de análisis (Fases 0–18) y no los de operación del repo.

- **Agentes de ingeniería definidos** (id / name / role / objective / responsibilities / allowed_tools / forbidden_tools / required_skills / review_required / rationale):

  1. **`planner` / Planner** — Rol: dirección de proyecto; secuencia el trabajo y define alcance.
     - **objective**: transformar los planes (`docs/plan_ejecucion_chasquipet.md`, `chasquipet.md` §3 "fuera del MVP" y §14) en tareas StrictContext secuenciadas con `acceptance_criteria` **verificables**, asignadas al agente correcto y con dependencias explícitas. No implementa.
     - **responsibilities**: descomponer funcionalidades planificadas en tareas atómicas; decidir orden (jamás "tope = MAX+1", jamás agente sin skill); definir criterios verificables ("existe la función X", "se verifica permiso Z"); separar ESTADO ACTUAL vs PLAN FUTURO (Fase 12); respetar la regla "detente y consulta conmigo al terminar los pasos 2, 3 y 5" (`chasquipet.md:453`); no crear tareas que dependan de contexto que aún no exista.
     - **allowed_tools**: lectura (read/grep/glob), psql **solo lectura** (esquema/information_schema), StrictContext (get_task/get_agent_context/list_*).
     - **forbidden_tools**: escribir/editar código (edit/write en db/worker/web/n8n), psql de escritura, crear migraciones, ejecutar tareas.
     - **required_skills**: architecture, security, testing.
     - **review_required**: sí (los planes los revisa el humano/superadmin antes de ejecutar).
     - **rationale/evidencia**: existe un plan de fases y la regla de detenerse a consultar (`chasquipet.md:453`); las tareas futuras (Fase 13) necesitan un rol que las especifique.

  2. **`sql-engineer` / SQL Engineer** — Rol: **núcleo del sistema**; dueño de toda la lógica de negocio en PostgreSQL.
     - **objective**: escribir y mantener la lógica de negocio **exclusivamente como funciones SQL, triggers, constraints y migraciones**, siguiendo la firma canónica y el contrato JSONB.
     - **responsibilities**: nuevas migraciones (`db/migrations/*.sql`) con tablas/índices/triggers/funciones; funciones de dominio STABLE de lectura y escritura con `p_actor_id uuid` + `p_canal text DEFAULT 'telegram'`; `PERFORM exigir_permiso(...)` en toda escritura; devolver `jsonb {ok:…}`; `auditar(...)`; idempotencia `ON CONFLICT` + UNIQUE parcial + `encolar_tarea` con `clave_unicidad`; triggers de la 3ª familia (caché/validación/inmutabilidad) y advisory locks (§5, `030:105-121`); fechas por `hoy_bogota/ahora_bogota`; reportes (080) y admin (085, 088); respetar Fase 6 (constraints C6.x: numeric→no-float, append-only, exigir_permiso, SECURITY DEFINER con `SET search_path`).
     - **allowed_tools**: edit/write en `db/migrations/*.sql`; psql vía `docker compose exec -T db psql -U chasquipet_app` (SDK PSQL) para probar; lectura de worker/web/setup solo para conocer los contratos.
     - **forbidden_tools**: editar `worker/**`, `web/**`, `n8n/**`, entradas de inventario directas sin `exigir_permiso`, conectarse como dueño (`POSTGRES_USER`), `UPDATE/DELETE` sobre tablas append-only, `real/float` para dinero (C6.3), SQL fuera de migraciones.
     - **required_skills**: postgres-business-logic, architecture, security, testing.
     - **review_required**: sí (escrituras de dinero/inventario y cambios de esquema los revisa reviewer).
     - **rationale/evidencia**: 282 funciones, 35 triggers, 68 índices, 41 tablas (Fase 2); el 100% de la lógica vive en SQL (ADR-02); todo el cobro/inventario/pagos pasa por aquí.

  3. **`telegram-engineer` / Telegram Engineer** — Rol: dueño del canal primario de operación (el bot).
     - **objective**: implementar y mantener los flujos de conversación de Telegram (menús, callbacks, FSM, deep links, confirmaciones) sobre el router → stubs encadenados, coordinando el contrato de `acciones` JSONB que n8n traduce y los envíos del worker.
     - **responsibilities**: `bot_manejar_update` y los stubs `bot_<mod>_callback/texto/media/menu_extra` con prefijo `<mod>:` y retorno NULL si no es suyo (`046:339`, `078:1012-1043`); FSM con `conversacion_estado` + `estado_guardar/leer/limpiar`; menús con `accion_enviar/accion_editar`, `pesos()`, `esc()`; confirmaciones obligatorias por botón antes de dinero/inventario (`046:402`, `066:404`, `076:552`, `078:692-762`); deep links `web-` / `turno-` / `por:`; notificaciones push (llamado, proximos, recibo al dueño con habeas data `consentimiento_datos`); rate limit por puerta pública (`030:218-222`, `058:39,72`).
     - **allowed_tools**: edit/write en las migraciones y funciones de los módulos del bot (`040` enrutador, `046`, `056`, `066`, `076`, `058` lado bot, `077`, `078`); psql para probar; lectura del workflow n8n `01-telegram-webhook.json` y `worker/src/telegram.js` para conocer el contrato de salida.
     - **forbidden_tools**: editar la lógica de dominio de negocio (funciones STABLE/`_json` de stock, cobro, compras que no dependan del bot), editar el JSON del webhook n8n (lo hace backend-engineer), auto-ejecutar escrituras sin confirmación, tocar `worker/**` excepto para leer contratos.
     - **required_skills**: telegram, postgres-business-logic, security, testing.
     - **review_required**: sí (flujos con dinero/inventario y confirmaciones).
     - **rationale/evidencia**: el bot es la interfaz primaria; el pipeline completo (dedup → router → stubs → acciones → n8n → worker) está descrito en Fase 3 §5; ~75 `estado_guardar`, 30 `accion_editar`, 28 `accion_enviar` (Fase 4).

  4. **`backend-engineer` / Backend Engineer** — Rol: dueño del worker, la cola y la orquestación (n8n y scripts de operación).
     - **objective**: mantener la capa fina que drena `tarea_async` y orquesta, de modo que n8n y el worker sigan siendo transportes sin estado ni lógica de negocio.
     - **responsibilities**: iterar el worker (`worker/src/`) en el patrón canónico `{tipo, manejar}` (tareas/index.js:4-6,41); agregar manejadores nuevos que llaman UNA función SQL y envían por `telegram.js`; respetar la política Telegram 429→`retry_after`/403→`ok:false` (telegram.js:96-113); idempotencia de avisos (`marcarAviso`, index.js:72-93); quede dar de alta nuevos workflow n8n (webhook `<1 s` con `responseMode:onReceived` y jobs `scheduleTrigger`→SQL puro); scripts `scripts/*.sh` (backup, restaurar, demo, superadmin, importar-n8n, registrar-publico); no implementar backoff (lo decide la BD, 010:286-323).
     - **allowed_tools**: edit/write en `worker/**` y `n8n/workflows/*.json` y `scripts/*.sh`; bash para `npm run check` (node --check), docker compose, psql para invocar funciones ya existentes.
     - **forbidden_tools**: escribir lógica de negocio en el worker (debe ser una función SQL ya validada), editar `db/migrations/*.sql` salvo para colaborar con sql-engineer, editar `web/**`, guardar estado en n8n.
     - **required_skills**: worker, architecture, security, testing.
     - **review_required**: sí.
     - **rationale/evidencia**: 11 manejadores, 4 workflows, cola con backoff/dead-letter en BD (Fases 2-4, ADR-04).

  5. **`frontend-engineer` / Frontend Engineer** — Rol: dueño del portal administrativo y la pantalla pública Next.js.
     - **objective**: construir y mantener el portal (Next.js 16 App Router) como capa delgada de lectura/administración conectada **solo** a funciones SQL, con sesión vía Telegram y sin lógica de negocio propia.
     - **responsibilities**: páginas y Server Actions que llaman funciones SQL con `$1` = actor de sesión y doble cerradura (`inventario/acciones.ts:12-14`); route handlers con cabeceras fijas (`runtime='nodejs'`, `force-dynamic`, `no-store`, salvo `/health` y `/salir`); pantalla pública por SSE con fallback a polling (mullex multiplexor `lib/notificaciones.ts`); reportes con CSV (`api/reportes/[clave]`, sesión+permiso); login por código de 6 dígitos o enlace (`entrar/`); nunca `password`, nunca HTTP externo.
     - **allowed_tools**: edit/write en `web/**`; bash para `npm run typecheck` y `npm run build`; lectura de `db/migrations/*.sql` para conocer las funciones SQL existentes.
     - **forbidden_tools**: SQL crudo inline nuevo (los 3 spots existentes son deuda; C6.12), `type="password"`, fetch a dominios externos, editar migraciones/worker, decidir permisos por su cuenta (lee `v_usuario_permiso`).
     - **required_skills**: nextjs-admin, architecture, security, testing.
     - **review_required**: sí.
     - **rationale/evidencia**: portal read-mostly, autenticación-solo-Telegram, cabeceras constantes (Fase 3 §6, Fase 4 §23-26).

  6. **`integration-engineer` / Integration Engineer** — Rol: dueño de los adaptadores a servicios externos.
     - **objective**: implementar y mantener adaptadores aislados hacia servicios externos (Telegram Bot API saliente, DeepSeek/IA, y los que el plan añada: Factus/DIAN, WhatsApp), con secretos en `.env`, idempotencia y rate limiting, sin tocar el dominio.
     - **responsibilities**: `worker/src/tareas/chasqui_responder.js` (IA, SOLO en el worker; herramientas y confirmación por botón, jamás auto-escribir — `078:692-762`); política de errores del proveedor (429/403/422 → el criterio de reintento); registrar webhook (`scripts/configurar-bot.sh`, `scripts/registrar-publico.sh`); túnel Cloudflare + Caddy (compose local); mapear entidades de negocio → payload del proveedor (factus mapper); exponer secretos solo por entorno (`docker-compose.yml`, nunca literales).
     - **allowed_tools**: edit/write en el código del adaptador (`worker` solo en archivos de integración, `scripts` de registro/túnel, `proxy/Caddyfile`, porciones de `docker-compose.yml` del túnel), lectura de `db/migrations/*.sql`.
     - **forbidden_tools**: escribir lógica de negocio del dominio, editar migraciones de negocio, editar `web/**`, auto-ejecutar escrituras IA sin confirmación, hardcodear secretos.
     - **required_skills**: external-integrations, worker, security, testing.
     - **review_required**: sí (integración con dinero —Factus— e IA).
     - **rationale/evidencia**: 3 integraciones externas hoy (Telegram salida, DeepSeek, túnel) + 2 planeadas (DIAN, WhatsApp); ADR-12 (adaptadores aislados).

  7. **`reviewer` / Reviewer** — Rol: control de calidad y conformidad con reglas/constraints.
     - **objective**: validar cada cambio contra las reglas MUST/MUST_NOT y las constraints C6.x (BLOCKER/ERROR/WARNING) usando `validate_action()`, y ejecutar la estrategia de verificación mínima real antes de declarar listo un trabajo.
     - **responsibilities**: comprobar firma canónica + `exigir_permiso` en toda escritura; append-only (no UPDATE/DELETE en `evento_auditoria`/`movimiento_inventario`/`pago`/`descuento`); contrato JSONB; prefijos de callback; cabeceras de route handlers; contrato de manejadores `{tipo, manejar}`; secretos en git; ejecutar la validación mínima: migraciones sobre BD de demo con `ON_ERROR_STOP`, `npm run typecheck`, `npm run check`, `docker compose` health; reportar hallazgos sin corregir (solo reporta).
     - **allowed_tools**: lectura (read/grep/glob), bash para las verificaciones (psql, typecheck, node --check, docker compose), MCP StrictContext (`validate_action`, `get_agent_context`).
     - **forbidden_tools**: editar código de cualquier capa (es revisor, no corrector); solo reporta.
     - **required_skills**: architecture, security, testing.
     - **review_required**: sí mismo (revisa; su salida la revisa un humano).
     - **rationale/evidencia**: la estrategia real de verificación sin tests automatizados (Fase 1 §TESTING, C6.23); las constraints Fase 6 requieren alguien que las haga cumplir.

- **Mapeo a la tabla `agents` de StrictContext** (para Fase 14): cada entrada se poblará con `id` (el mismo), `name`, `role`, `goal` (= objective), `system_prompt_template` (bootstrap con las responsibilities + skills + constraints), `allowed_tools`/`forbidden_tools` (JSONB de nombres de herramientas del runtime), `max_steps` (default 10 salvo planner), `requires_human_review` (true en sql-engineer, telegram-engineer, backend-engineer, integration-engineer; false en planner, frontend-engineer; true en reviewer), `priority` (planner 10, sql 20, telegram 20, backend 20, frontend 20, integration 30, reviewer 50), `active` (true).

- **Incertidumbres**:
  - **Solapamiento sql-engineer ↔ telegram-engineer**: la lógica del bot vive en SQL y la del dominio en SQL; la frontera real es el **prefijo del módulo del bot** (`bot_*_callback/texto/media`) vs las funciones STABLE de dominio. No es exacta: `058_auth_web.sql` mezcla identidad (dominio, sql-engineer) con el flujo del bot/auth (telegram-engineer). Se propone que la función de bot y su FSM pertenezcan a telegram-engineer y la función de dominio a sql-engineer; la frontera debe resolverse en cada caso (UNKNOWN si se necesita un criterio más fino, ver Fase 9 skills).
  - **integration-engineer vs backend-engineer**: la superficie real de integración hoy es pequeña (IA en worker, túnel, registro webhook) y parte del adaptador IA vive dentro del worker (propiedad discutible). Se conserva `integration-engineer` porque el plan §10 lo lista y porque Factus/WhatsApp son módulos externos grandes; UNKNOWN si en la práctica conviene fusionarlo con backend-engineer (el adaptador IA usa la misma máquina de cola).
  - **Destino de los 9 agentes de análisis** ya poblados en StrictContext: se conservan activos (documentan la misión) o se desactivan/depuran al poblar los 7 de trabajo (Fase 14 lo decide). UNKNOWN.
  - **`allowed_tools`/`forbidden_tools`**: los nombres de herramientas son conceptuales (read/edit/write/bash/psql/MCP); la lista exacta y el formato JSONB dependen del runtime real de los agentes (OpenCode), a resolver en Fase 14.
  - Los agentes se definen sobre el estado en disco (código no commiteado incluido: `chasqui_responder.js`, `077`/`078`); si el deploy no incluye eso, el alcance del IA de `integration-engineer` cambia (mismo UNKNOWN de Fase 1).

### Fase 9 — Crear los skills

- **Fecha / sesión**: 2026-08-09 / sesión 10
- **Agente**: context-architect
- **Directiva** (plan §11): construir skills basados en dominios reales del proyecto, con conocimiento específico suficiente para justificar cada uno; divididos en las secciones `overview / patterns / anti_patterns / examples / migrations / testing / security / references`, describiendo (1) qué existe, (2) cómo funciona, (3) cómo debe extenderse, (4) qué debe evitarse y (5) cómo comprobar cambios. No crear un skill sin conocimiento específico; no inventar contenido. Fuente primaria: evidencia consolidada en Fases 0–8 (migraciones, worker, n8n, web, scripts, ADRs, constraints, incertidumbres).

- **Resultado de la investigación**: los **8 candidatos** del plan §11 tienen conocimiento específico suficiente y se crean todos; ninguno añadido fuera de la lista, ninguno descartado (cada dominio justifica separación: hay material concreto y verificable en cada uno). Los 8 se registran en `skills` + `skill_sections` en Fase 14 (poblamiento).

- **Skills definidos** (id / domain / sections cubiertas / resumen):

  1. **`architecture`** (domain `architecture`) — sections: overview, patterns, anti_patterns, examples, migrations, testing, security, references.
  2. **`postgres-business-logic`** (domain `database`) — overview, patterns, anti_patterns, examples, migrations, testing, security, references.
  3. **`telegram`** (domain `telegram`) — overview, patterns, anti_patterns, examples, migrations, testing, security, references.
  4. **`worker`** (domain `worker`) — overview, patterns, anti_patterns, examples, migrations, testing, security, references.
  5. **`nextjs-admin`** (domain `web`) — overview, patterns, anti_patterns, examples, migrations, testing, security, references.
  6. **`security`** (domain `security`) — overview, patterns, anti_patterns, examples, migrations, testing, security, references.
  7. **`testing`** (domain `testing`) — overview, patterns, anti_patterns, examples, migrations, testing, security, references.
  8. **`external-integrations`** (domain `integration`) — overview, patterns, anti_patterns, examples, migrations, testing, security, references.

  (Contenido por skill en las subsecciones siguientes.)

---

### Skill 1 — `architecture`

- **qué existe**: arquitectura "PostgreSQL-centric" verificada contra el código (Fase 3), no contra la doc: Postgres 16 es la fuente única de verdad y dueño de la lógica (ADR-01); n8n, worker y web son capas delgadas de transporte/adaptación (ADR-03/04/11); los roles de negocio son datos (ADR-06); auditoría procedimental (ADR-07); idempotencia como primitiva de BD (ADR-08); append-only por REVOKE+triggers (ADR-09); temporalidad en America/Bogota (ADR-10); integraciones aisladas (ADR-12). 282 funciones SQL, 4 vistas, 35 triggers (Fase 2).
- **cómo funciona**: cada componente invoca funciones SQL y traduce formatos; los estados materiales (stock, totales de cuenta) se mantienen con triggers, no se recomputan en las apps. El webhook responde <1 s y lo pesado se encola en `tarea_async`. La cola se drena con `FOR UPDATE SKIP LOCKED` y el backoff/dead-letter viven en la BD (ADR-04).
- **cómo debe extenderse**: agregar superficie = agregar una función SQL (dominio STABLE de lectura o escritura con firma canónica) + su `bot_<mod>_*`/Server Action + en su caso `encolar_tarea`; ninguna lógica nueva en la periferia. Nuevo dominio = nueva migración aditiva en `db/migrations/`.
- **qué debe evitarse**: lógica de negocio en worker/n8n/web; guardar estado en n8n o en memoria del worker; conectar como dueño (C6.6); SQL crudo inline web (C6.12); secretos en git (C6.7); re-edición/borrado de tablas append-only (C6.1).
- **cómo comprobar cambios**: `npm run typecheck` (web), `npm run build`, `worker npm run check`, migraciones aplicables `psql -v ON_ERROR_STOP=1` sobre demo, `/health`, `docker compose` health; validar contra `validate_action()` (BLOCKER/ERROR/WARNING de Fase 6).
- **evidencia**: ADR-01 a ADR-12 (Fase 7), Fase 3 (modelo de arquitectura), Fase 6 (constraints C6.x).

### Skill 2 — `postgres-business-logic`

- **qué existe**: 41 tablas, 0 enums (estados `text`+CHECK), 68 índices, 35 triggers, 282 funciones; utilidades `exigir_permiso`, `tiene_permiso`, `auditar`, `encolar_tarea`, `hoy_bogota`/`ahora_bogota`, `config_int/txt/bool`, `reclamar_tareas`, `consumir_rate_limit`, `estado_guardar/leer/limpiar` (Fases 2 y 4).
- **cómo funciona**: firma canónica de escritura `p_actor_id uuid` + `p_canal text DEFAULT 'telegram'|'web'`; toda escritura abre con `PERFORM exigir_permiso(p_actor_id,'modulo.accion')`, devuelve `jsonb {ok:boolean, motivo?, mensaje?}` y audita con `auditar(...)`. Errores esperados → `ok:false`; violaciones → `RAISE EXCEPTION USING ERRCODE` semántico (`23514` negocio, `0A000` append-only, `42501`/`28000` permisos/auth). Idempotencia con `ON CONFLICT` + UNIQUE parcial + `clave_unicidad`; numeración con `pg_advisory_xact_lock`; cola con `FOR UPDATE SKIP LOCKED`; triggers en 3 familias (touch, recálculo de caché, validación/inmutabilidad); búsqueda con `normalizar()` + GENERATED STORED + GIN `pg_trgm`; FSM en `conversacion_estado` con TTL.
- **cómo debe extenderse**: nueva funcionalidad = migración aditiva con tabla/índices/triggers/funciones de dominio; respetar firma canónica, `exigir_permiso`, `auditar`, contrato JSONB, `numeric` (C6.3), append-only (C6.1), advisory lock para numeración (C6.4); SECURITY DEFINER nuevo debe fijar `SET search_path` (C6.10).
- **qué debe evitarse**: `MAX(numero)+1` a pelo; DML sin `exigir_permiso` (C6.5); `real`/`double` para dinero/stock (C6.3); editar/borrar/purgar `evento_auditoria`, `movimiento_inventario`, `pago`, `descuento` (C6.1/C6.2); editar consulta firmada o línea de cuenta (reverso/adenda); ingresar mercancía vencida; no auditar ediciones críticas (C6.22).
- **cómo comprobar cambios**: invocación `psql` de cada función nueva que demuestre el comportamiento (C6.23); aplicar migraciones sobre BD demo con `ON_ERROR_STOP`; corroborar triggers 3ª familia y estados `text`+CHECK.
- **evidencia**: Fase 2 (esquema), Fase 4 (patrones 1–15), Fase 5 (MUST/MUST_NOT/SHOULD), Fase 6 (C6.1–6.18), Fase 7 ADR-02/04/07/08/09/10.

### Skill 3 — `telegram`

- **qué existe**: router único `bot_manejar_update` (`040_bot_turnos.sql`) con 3 ramas (público sin usuario, personal por texto, personal por callback); despacho modular por stubs encadenados `bot_modulo_callback/texto/media/menu_extra` con prefijo `<mod>:` y retorno NULL si el prefijo no es suyo; orquestador final en `078` con COALESCE (callback: ia→inv→cli→cob→com→por→auth; texto: auth→por→inv→cob→com→cli→ia); salida `{acciones:[{tipo:'responder_callback'|'enviar'|'editar',…}]}` traducida por n8n; FSM con `estado_guardar/leer/limpiar`; helpers `esc()`, `accion_enviar`, `accion_editar`, `pesos()`.
- **cómo funciona**: n8n recibe el webhook, ejecuta `registrar_update_telegram` (dedup por update_id) + `bot_manejar_update`, traduce las acciones a `answerCallbackQuery`/`sendMessage`/`editMessageText` y marca procesado. El bot valida permisos por botón y confirmaciones de dinero/inventario por callback; deep links `web-<id>`, `turno-<sede>`, `por:enlace`. Rate limit por puerta pública (`turno:chat`, `login:`, `portal:enlace:`, `ia:`).
- **cómo debe extenderse**: nuevo módulo de bot = migración que redefine `bot_<mod>_callback/texto/media` con guardia `IF v_partes[1] <> 'mod' THEN RETURN NULL`, usa FSM con pasos `estado_guardar`, callbacks con prefijo `<mod>:`, confirmación por botón antes de escribir dinero/inventario, y se registra en el orquestador COALESCE de `078`.
- **qué debe evitarse**: callback sin prefijo (C6.14); auto-escritura de dinero/inventario sin confirmación (C6.9); textos largos o más de 3 botones por fila (PREFERENCE 2); HTML complejo (los mensajes viven en SQL, `acciono_enviar`); guardar estado fuera de `conversacion_estado`.
- **cómo comprobar cambios**: probar flujos con callbacks reales (`psql` + `bot_*` directo o vía webhook demo); verificar `answerCallbackQuery` siempre antepuesto, dedup por update_id; confirmar que el orquestador `078` quedó actualizado.
- **evidencia**: Fase 3 §5 (pipeline), Fase 4 (patrones 8, 10, 13, 14), Fase 5 (MUST 5, 7, 12; SHOULD 5, 6, 9), Fase 6 (C6.9, C6.14, C6.15), ADR-05.

### Skill 4 — `worker`

- **qué existe**: 11 manejadores en `worker/src/tareas/` con contrato `{tipo, manejar}`; esqueleto `manejar({payload},{db,log,marcarAviso})`; envíos centralizados en `telegram.js`; dedup de avisos `marcarAviso` (`aviso_turno_enviado`); logs a stdout sin color; sin transacciones manuales ni estado de negocio en memoria.
- **cómo funciona**: index.js reclama con `reclamar_tareas` cada 2 s (lote 10), ejecuta manejadores, y reporta `completar_tarea`/`fallar_tarea`; el worker NUNCA escribe `tarea_async` directo y no reimplementa backoff (lo decide la BD). Política de Telegram: 429 → esperar `retry_after` (≤60 s) y reintentar 1 vez; 403/400 no recuperable → `{ok:false}` completado; resto → lanzar para reintento.
- **cómo debe extenderse**: nueva tarea = función SQL que llama `encolar_tarea` + manejador nuevo `{tipo: '<tipo>', manejar}` que invoca UNA función SQL y envía por `enviarMensaje`/`teclado`; registrar el módulo en `index.js` del worker como `{tipo, manejar}`.
- **qué debe evitarse**: DML directo sobre `tarea_async` (C6.16); lógica de negocio en el worker (solo funciones SQL); transacciones manuales; backoff manual; guardar estado en memoria; contradicción con límites 403/400.
- **cómo comprobar cambios**: `npm run check` (node --check) en worker; encolar una tarea de prueba y verificar procesamiento/`completar_tarea`; medir que no reintenta sin motivo (403/400).
- **evidencia**: Fase 3 §4 (cola), Fase 4 (patrones 16–20), Fase 5 (MUST 14, 15; MUST_NOT 10), Fase 6 (C6.16).

### Skill 5 — `nextjs-admin`

- **qué existe**: portal Next.js 16 App Router + React 19, TS strict; sesión por Telegram (cookie HttpOnly con sha256 en BD, `058_auth_web.sql`); login por código 6 dígitos o enlace de un solo uso; Server Actions uniformes; route handlers con cabecera fija (`runtime='nodejs'`, `dynamic='force-dynamic'`, `Cache-Control:'no-store'`), `params: Promise` + `esUuid`; pantalla pública por SSE con fallback a polling 5 s; 12 claves de reporte; CSV por `/api/reportes/[clave]`.
- **cómo funciona**: cada request valida `sesion_por_token` con refresco de `last_seen_at`; el layout `(portal)` corta la sesión; permisos resueltos por `v_usuario_permiso` (la web solo compara con `exigirPermiso`); Server Actions llaman funciones SQL con `$1` = actor de sesión y revalidan; el SSE usa UNA conexión `LISTEN pantalla_turnos` multiplexada.
- **cómo debe extenderse**: nueva vista = Server Component + Server Action (o route handler con cabeceras fijas) que llama funciones SQL existentes; nunca SQL crudo inline (C6.12); nunca decidir permisos: leer `v_usuario_permiso`.
- **qué debe evitarse**: `type="password"` o login con usuario/clave (C6.17, MUST_NOT 6); fetch a dominios externos (MUST_NOT 7); SQL crudo inline (C6.12); `dynamic='force-static'`/`revalidate` en route handlers (C6.13); tomar el actor del body (C6.13).
- **cómo comprobar cambios**: `npm run typecheck`, `npm run build`, probar `/health`, `sesión`, pantalla SSE con fallback polling, un reporte CSV con permiso.
- **evidencia**: Fase 3 §6 (portal), Fase 4 (patrones 23–26), Fase 5 (MUST 11; MUST_NOT 6, 7; Contradicciones), Fase 6 (C6.12, C6.13, C6.17), ADR-11.

### Skill 6 — `security`

- **qué existe**: RBAC como datos (`rol/permiso/rol_permiso/usuario_permiso`), `usuario`/`v_usuario_permiso`; `exigir_permiso`/`tiene_permiso` (020:92,101) en toda escritura; roles de BD `chasquipet_app`/`chasquipet_lectura`; append-only por REVOKE (090:42-63) + triggers inmutables; auditoría `auditar()` SECURITY DEFINER; sesiones de un solo uso con sha256; rate limits por puerta pública; secretos solo por entorno (`.env`, compose).
- **cómo funciona**: tres capas (roles de PostgreSQL → roles de negocio como datos → doble cerradura web+SQL); la app corre como `chasquipet_app` (no dueño); el bot y la web usan las mismas funciones de permiso; las sesiones expiran y son revocables; habeas data: recibo/resumen al dueño solo con `consentimiento_datos` + `telegram_chat_id`.
- **cómo debe extenderse**: nueva escritura = `exigir_permiso` + `auditar` + `numeric`; nuevo endpoint público = `consumir_rate_limit`; nueva tabla inmutable = agregarla al array de 090 (C6.11); nueva SECURITY DEFINER = `SET search_path` (C6.10).
- **qué debe evitarse**: secretos en git (C6.7); conectar como dueño (C6.6); `GRANT EXECUTE ON ALL FUNCTIONS` sin acotar (C6.19); `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` (C6.21); autoregistro o revelar validez de código (MUST_NOT 3); purgar auditoría/inventario (C6.2).
- **cómo comprobar cambios**: `validate_action()` contra constraints; `psql` re-verificando REVOKE/permisos; inspección de `.env`/git por secretos.
- **evidencia**: Fase 2 (permisos como datos, roles 090), Fase 5 (MUST 1, 8, 13; MUST_NOT 3, 5, 9; Problemas de seguridad), Fase 6 (C6.5–6.7, C6.10, C6.19, C6.21), ADR-06/07.

### Skill 7 — `testing`

- **qué existe**: no hay suite automatizada ni CI; la verificación real es: migraciones aplicables con `psql -v ON_ERROR_STOP=1` sobre BD demo; `web && npm run typecheck` (tsc --noEmit) y `npm run build`; `worker && npm run check` (node --check); `scripts/cargar-demo.sh` + `db/demo/`; `/health` (SELECT 1).
- **cómo funciona**: cada cambio se verifica contra una BD de demo recién cargada (o vivo con Docker) invocando las funciones SQL en orden; los manejadores del worker se prueban encolando tareas y observando `tarea_async`; las Server Actions y routes se prueban por HTTP con sesión.
- **cómo debe extenderse**: cualquier nueva migración/función debe acompañarse de una invocación que demuestre el comportamiento (mismo criterio de Fase 1); si se introduce test automatizado, debe correr tras `cargar-demo` y respetar roles de BD.
- **qué debe evitarse**: declarar listo sin verificar; romper `ON_ERROR_STOP` en BD de demo; repos sin health; enmascarar fallos con `process.exit(0)` en uncaughtException (UNKNOWN).
- **cómo comprobar cambios**: lista de verificación C6.23: migraciones → typecheck → build → node --check → demo → health.
- **evidencia**: Fase 1 §TESTING, Fase 6 C6.23, Fase 4 p.27 (preámbulo de scripts).

### Skill 8 — `external-integrations`

- **qué existe**: entrada Telegram por webhook (n8n → Caddy → cloudflared), salidas por Bot API (n8n síncrono y worker); DeepSeek compatible OpenAI SOLO en el worker (`chasqui_responder.js`) con puerta de confirmación por botón (`ia_llamar`/`ia_confirmar`, `ia_accion_pendiente`); túnel Cloudflare con descubrimiento de hostname (`registrar-publico.sh`) y anulación opcional por `WEBHOOK_URL_FIJA`; deep links `web-<id>`, `turno-<sede>`, `por:`.
- **cómo funciona**: la IA se alimenta de catálogo `ia_herramienta` filtrado por `tiene_permiso`; herramientas `escribe=true` producen propuesta confirmable, el worker NUNCA escribe; la web no hace llamadas HTTP externas; todo secreto (token, DEEPSEEK_API_KEY, SESSION_SECRET) se inyecta por `.env`/compose; el registrador tipa el `setWebhook` y actualiza `config.portal_url` solo si cambió.
- **cómo debe extenderse**: nueva integración (Factus/DIAN, WhatsApp) = adaptador aislado en el worker/su capa, con secretos por entorno, `reference_code` como idiempotencia (`doc_<id>`), rate limit del proveedor (429 → Retry-After), 422 no reintentar, mapeo de entidades por función/módulo de integración; SIN tocar el dominio ni el bot existente.
- **qué debe evitarse**: secretos en JSON de workflow o en git (C6.7); auto-escritura IA sin confirmación (C6.9); llamadas HTTP externas desde la web (MUST_NOT 7); hardcodear credenciales Factus/WhatsApp; exponer el editor de n8n o la BD.
- **cómo comprobar cambios**: sin credenciales reales se testea el mapper contra payloads de ejemplo y el flujo de cola; con sandbox se valida OAuth/cache de token y handling 429/422.
- **evidencia**: Fase 3 §9 (integraciones), Fase 4 p.18 (política Telegram), ADR-12, Fase 6 C6.7/C6.9/C6.21, `reporte-tecnico.md` (Factus DIAN). Factus/DIAN: NO implementado (plan futuro).

- **Incertidumbres**:
  - Los 8 skills derivan del conocimiento validado en Fases 0–8; su **registro real en `skills`/`skill_sections`** (id, domain, secciones, priority, validation_rules, code_examples) y el formato de `related_skills` en ADRs se resuelve en Fase 14 (poblamiento).
  - La frontera sql-engineer ↔ telegram-engineer (Fase 8) queda como conocimiento de los skills 2 y 3; si se necesita un criterio más fino (p.ej. cuándo un `058_auth_web.sql` es dominio vs bot), es UNKNOWN y se decide en Fase 10/14.
  - `testing` (skill 7) describe la estrategia real actual; si el proyecto adopta test automatizados, el skill debe actualizarse (hoy C6.23 es el estándar WARNING).
  - `security` y `external-integrations` citan problemas reportados sin corregir (GRANT EXECUTE amplio, SECURITY DEFINER sin search_path, N8N_BLOCK_ENV_ACCESS_IN_NODE=false, registrador con dueño); estos son deuda reportada, no comportamiento normativo del skill.
  - El contenido de cada skill es **conocimiento textual**, no archivos de plantilla ni código ejecutable; la automatización de `check_pattern`/`check_sql` (Fase 6) queda para Fases 14/17.

### Fase 10 — Relaciones Agent ↔ Skill

- **Fecha / sesión**: 2026-08-09 / sesión 11
- **Agente**: context-architect
- **Directiva** (plan §12): para cada agente de la Fase 8 determinar los skills (Fase 9) que necesita. NO cargar todos los skills a todos los agentes: el objetivo es **minimizar contexto irrelevante**; todo skill cargado debe justificarse con responsabilidad real. Criterios complementarios usados: (1) **todo skill debe tener al menos un agente dueño** (ninguno huérfano), (2) **ningún agente sin al menos un skill**, (3) los skills transversales de seguridad/testing se aplican a todos, (4) el mapeo se valida contra las responsabilidades y `required_skills` ya definidos en Fase 8.
- **Resultado de la investigación**: los **7 agentes de la Fase 8** se mapean a los **8 skills de la Fase 9** con la matriz siguiente. El mapeo es consistente con los `required_skills` ya declarados en Fase 8 (no se descubrió ningún vínculo nuevo necesario ni ninguno sobrante que contradiga la evidencia). Cada skill tiene ≥1 agente dueño (ninguno huérfano) y cada agente tiene ≥2 skills (mínimo: `security` + `testing`, transversales).

- **Matriz de relaciones** (agente → skills que carga):

  1. **`planner`** → architecture, security, testing.
     - *Por qué*: dirige y secuencia el trabajo; necesita la arquitectura (architecture: postgres-centric, ADRs) para decidir alcance; security y testing transversales porque toda tarea futura (Fase 13) debe respetar constraints C6 y llevar `acceptance_criteria` verificables (C6.23). *Por qué no más*: no edita código en ningún dominio, así que no carga skills de dominio (postgres-business-logic/telegram/worker/nextjs-admin/external-integrations) — su `objective` es transformar planes ya escritos en tareas, no implementar.

  2. **`sql-engineer`** → postgres-business-logic, architecture, security, testing.
     - *Por qué*: dueño del núcleo → postgres-business-logic (skill 2) es su dominio entero; architecture para conocer las reglas de extensión de la capa SQL dentro del todo; security y testing transversales (toda función nueva = `exigir_permiso` + `auditar` + prueba psql C6.23). *Por qué no más*: no toca bot/web/worker/integraciones (forbidden_tools lo excluyen).

  3. **`telegram-engineer`** → telegram, postgres-business-logic, security, testing.
     - *Por qué*: dueño del canal → telegram (skill 3); postgres-business-logic porque el bot vive en SQL (FSM `estado_guardar/leer/limpiar`, stubs, confirmaciones) y debe respetar la firma canónica y el contrato JSONB; security y testing transversales. *Por qué no más*: el prefijo de módulo delimita su territorio — no hereda worker ni nextjs-admin.

  4. **`backend-engineer`** → worker, architecture, security, testing.
     - *Por qué*: dueño del worker y la orquestación → worker (skill 4); architecture por la cola/backoff en BD y los roles de n8n/scripts en la arquitectura; security y testing transversales. *Por qué no más*: no escribe SQL de negocio ni bot ni web (prohibido en Fase 8).

  5. **`frontend-engineer`** → nextjs-admin, architecture, security, testing.
     - *Por qué*: dueño del portal → nextjs-admin (skill 5); architecture por el portal como capa delgada (ADR-11) y la doble cerradura; security y testing transversales (sesión, cabeceras fijas, C6.13). *Por qué no más*: no toca SQL (solo llama funciones) ni worker ni bot.

  6. **`integration-engineer`** → external-integrations, worker, security, testing.
     - *Por qué*: dueño de los adaptadores → external-integrations (skill 8); worker porque los adaptadores viven en el worker (IA `/chasqui_responder`) y deben respetar la política de la cola y de `telegram.js`; security y testing transversales (secretos por entorno, rate limit del proveedor). *Por qué no más*: no escribe dominio ni bot ni web.

  7. **`reviewer`** → security, testing, architecture.
     - *Por qué*: control de calidad → security y testing son su herramienta central (`validate_action()`, C6.x, estrategia de verificación mínima); architecture para juzgar cada cambio contra las decisiones de arquitectura (ADRs). *Por qué no más*: no implementa en ningún dominio; revisa contra las rules/constraints registradas, no contra el conocimiento profundo de cada skill (no carga los 5 skills de dominio: su `objective` es validar, no construir).

- **Resolución de la incertidumbre "frontera sql-engineer ↔ telegram-engineer"**: la frontera real (arrastrada de Fases 8/9) se resuelve por el **prefijo de módulo del bot**, con evidencia en migraciones y en el orquestador:
  - `058_auth_web.sql` mezcla ambos dominios en UN archivo: la identidad/sesión (funciones `crear_challenge_web`/`resolver_challenge_web`/`emitir_sesion_web`/`sesion_por_token`/`cerrar_sesion_web`/`revocar_sesiones_usuario` = dominio, sql-engineer) convive con los stubs del bot (`bot_auth_*`, `accion_*`, `bot_modulo_*` = telegram-engineer), evidence at 058:253-430.
  - El criterio: **una función cuyo nombre empieza por `bot_` (y sus helpers `accion_*`, `esc`, `pesos`, `teclado`/JSONB de botón) pertenece a telegram-engineer; una función de dominio (STABLE de lectura, escritura con `p_actor_id`, utilidad) pertenece a sql-engineer**; si una función de dominio es consumida por el bot, el implementador del bot la referencia sin reescribirla.
  - En futuras sesiones, si un cambio toca un archivo mixto como `058`, la propiedad se asigna por función, no por archivo (evidencia adicional: `078_chasqui_ia.sql` re-define el orquestador COALESCE final y los stubs del módulo ia, pero `ia_llamar`/`ia_confirmar` las consumen como dominio).
  - Este criterio cierra la incertidumbre de la Fase 8/9; queda residual el UNKNOWN de Fase 1 (IA real en producción), que es de credenciales, no de frontera.

- **Regla de carga por agente (derivada)**: `security` y `testing` se cargan en **todos** los agentes (son transversales y ya exigidas en Fase 6/8); los 6 skills de dominio (`architecture`, `postgres-business-logic`, `telegram`, `worker`, `nextjs-admin`, `external-integrations`) se cargan solo en el agente dueño indicado arriba. Ningún agente carga los 8; ningún skill queda sin dueño.

- **Incertidumbres**:
  - **Esquema de registro de la relación (para Fase 14)**: StrictContext no tiene tabla N:M explícita de agent↔skill; hoy la relación vive en el texto de `required_skills` de cada agente. El esquema actual (`agents` sin columna de skills; `tasks.required_skills` JSONB solo existe como dependencia de tarea) puede requerir: (a) una columna JSONB `required_skills` en `agents`, o (b) tabla `agent_skills(agent_id, skill_id)`, o (c) dejarla implícita en `system_prompt_template`. UNKNOWN hasta Fase 14 (poblamiento).
  - **Destino de los 9 agentes de análisis** ya poblados (project-analyst…reviewer): no participan en la matriz Fase 10 (son de la misión de análisis, no de operación); si se desactivan en Fase 14, sus skills no aplican. UNKNOWN (mismo que Fase 8).
  - **Frontera sql↔telegram en archivos que mezclan dominio+bot sin prefijo claro**: el criterio del prefijo `bot_` cubre el 100% de los stubs vistos (grep de migraciones), pero si un futuro archivo define lógica de bot con otro nombre, la decisión se toma por el orquestador COALESCE de `078` (quién lo despacha). Residual UNKNOWN, baja.
  - **`planner` sin skills de dominio**: su decisión de orden se apoya en architecture + los constraints C6; si una tarea futura necesita juzgar viabilidad técnica SQL/bot, el planner debería delegar la viabilidad al dueño del dominio, no cargar el skill. Queda como PREFERENCE.
  - **Grupo de habilidades por build**: la cantidad de skills cargados por agente (3–4) asume un costo de contexto no medido; la medición de "cuánto contexto consume cada skill" queda para la prueba de recuperación (Fase 16).

### Fase 11 — Comandos de desarrollo

- **Fecha / sesión**: 2026-08-09 / sesión 12
- **Agente**: context-architect
- **Directiva** (plan §13): a partir del **workflow real del proyecto** (no del documento) determinar qué operaciones repetitivas deberían convertirse en commands de StrictContext. Candidatos a investigar: `inspect, plan, implement, test, verify, review, session, session-report`. Para cada command definir `name / description / prompt_template / required_context / required_agent / required_skills / validation_requirements`. **NO implementar todavía los comandos de ejecución** si la herramienta actual no los soporta: primero registrar su especificación.

- **Workflow real usado como fuente** (evidencia): el desarrollo del repo avanza por **ciclos por etapa** (9 commits en `master` etiquetados "paso 1–8", `git log --oneline`): cada etapa = migración(s) SQL aditiva + stubs de bot/worker/n8n/web SOLO como adapters; verificación sin tests (C6.23: migraciones con `psql -v ON_ERROR_STOP=1` sobre BD demo, `npm run typecheck` + `build` web, `npm run check` worker, invocación psql de cada función nueva); el plan de ejecución tiene **sesiones independientes** (`docs/plan_ejecucion_chasquipet.md:44-46`) y el propio análisis usa el **protocolo de sesión** de este documento (leer avance → verificar fase → marcar en_progreso → ejecutar → volcar → registrar). Estos tres patrones (etapa implementable, verificación mínima, sesión con reporte) son las operaciones repetitivas que se formalizan aquí.

- **Resultado de la investigación**: los **8 candidatos del plan §13** corresponden a operaciones repetitivas reales del workflow; **ninguno se descarta y ninguno se añade**. Se especifican 8 commands. Un hallazgo importante: el esquema real de StrictContext (`commands` table: `id/name/description/required_agent/steps/preconditions/expected_output/rollback_steps`) **no coincide** con los campos que el plan §13 pide especificar (`prompt_template/required_context/required_skills/validation_requirements`) → el mapeo queda para Fase 14 (poblamiento), como incertidumbre. El runtime actual solo expone `get_command_steps()` (lectura de pasos), no ejecución → esta fase solo registra la especificación, como manda el plan.

- **Commands definidos** (id / name / description / prompt_template / required_context / required_agent / required_skills / validation_requirements):

  1. **`inspect` / Inspeccionar**
     - description: explorar el estado real de un componente, dominio o tarea del repositorio **sin modificar nada**, determinando qué existe y cómo funciona, para apoyar el planeo y la ejecución.
     - prompt_template: "Investiga `<objetivo>`. Recorre `<componentes>`. Usa read/grep/glob y reporta el estado real de cada hallazgo (EXISTING / DECISION / CONVENTION / PLANNED / UNKNOWN) con evidencia path:line. Sin evidencia suficiente → UNKNOWN. NO modifiques código."
     - required_context: acceso de lectura al repo; skill(s) del dominio inspeccionado (Fase 9); ADRs y constraints aplicables al dominio (Fases 6/7).
     - required_agent: el agente dueño del dominio del objetivo (Fase 8); para vistas de alcance general del proyecto → `planner`; para pasada de verificación → `reviewer`.
     - required_skills: `architecture` (clasificar DECISION/CONVENTION) + skill del dominio inspeccionado + `security`/`testing` si toca dinero/inventario (matriz Fase 10).
     - validation_requirements: cada afirmación con evidencia path:line; sin evidencia → UNKNOWN; cero archivos modificados; contradicciones doc-vs-código reportadas tal cual (nunca corregidas en silencio).

  2. **`plan` / Planificar**
     - description: transformar una funcionalidad planificada (fuente: `docs/plan_ejecucion_chasquipet.md`, `chasquipet.md` §3/§14) en **tareas StrictContext secuenciadas** con `acceptance_criteria` verificables, agente dueño y dependencias explícitas; el planner no implementa.
     - prompt_template: "Descompón `<funcionalidad planificada>` en tareas atómicas. Para cada una define: title, description, assigned_agent (solo entre los 7 de Fase 8), required_skills, dependencies, acceptance_criteria verificables por C6.23 ('existe la función X', 'se verifica permiso Y'). NO registres PLANNED como EXISTING. Detente y consulta al humano al cerrar los pasos 2, 3 y 5 (chasquipet.md:453)."
     - required_context: plan futuro de ejecución, catálogo de agentes (Fase 8), skills (Fase 9), constraints C6 (Fase 6), ADRs (Fase 7).
     - required_agent: `planner`.
     - required_skills: `architecture`, `security`, `testing` (matriz Fase 10 del planner).
     - validation_requirements: ninguna tarea sin `acceptance_criteria` verificable; assigned_agent solo entre los 7 de trabajo; dependencias sin ciclos; nada del plan futuro registrado como funcionalidad existente.

  3. **`implement` / Implementar**
     - description: ejecutar una tarea asignada en el dominio correcto (SQL / bot / worker / web / integración), siguiendo los patrones del skill del dominio y las constraints C6, y acompañar el cambio de su verificación mínima (C6.23).
     - prompt_template: "Implementa la tarea `<id>` (agentue `<assigned_agent>`). Sigue la firma canónica `p_actor_id` + `p_canal`, `exigir_permiso` en toda escritura, `auditar`, contrato JSONB {ok,motivo,mensaje}, idempotencia ON CONFLICT+UNIQUE parcial, append-only por reverso/adenda. Verifica el cambio con C6.23. No corrijas problemas ajenos a la tarea (solo repórtalos)."
     - required_context: la tarea con sus `acceptance_criteria`, el skill del dominio (Fase 9), constraints C6 aplicables (Fase 6).
     - required_agent: el `assigned_agent` de la tarea (sql-engineer | telegram-engineer | backend-engineer | frontend-engineer | integration-engineer).
     - required_skills: las del assigned_agent según la matriz Fase 10.
     - validation_requirements: cumplir TODOS los acceptance_criteria; `validate_action()` sin violaciones (nunca ignorar un BLOCKER); escrituras con confirmación explícita cuando dinero/inventario (C6.9); cero lógica de negocio nueva en periferia.

  4. **`test` / Verificar el cambio**
     - description: ejecutar la verificación mínima real del proyecto sobre un cambio (C6.23): migraciones aplicables con `psql -v ON_ERROR_STOP=1` sobre BD demo, `npm run typecheck` + `npm run build` (web), `npm run check` (worker), invocación con psql de cada función/acción nueva que demuestre el comportamiento, y `/health`.
     - prompt_template: "Verifica `<cambio>` contra C6.23: (a) aplica migraciones sobre BD demo (`scripts/cargar-demo.sh` + psql `ON_ERROR_STOP`); (b) web: `npm run typecheck` y `npm run build`; (c) worker: `npm run check`; (d) invoca con psql cada función/Server Action nueva mostrando resultado; (e) comprueba `/health`. Reporta paso a paso qué pasó y qué falló."
     - required_context: scripts de demo (`scripts/cargar-demo.sh`, `db/demo/`), `package.json` de web y worker, la migración/función nueva.
     - required_agent: el agente que implementó (dueño del dominio) o `reviewer` en la pasada de validación final.
     - required_skills: `testing` (skill 7) + `security` si el cambio toca constraints de seguridad (matriz Fase 10).
     - validation_requirements: ON_ERROR_STOP respetado de principio a fin; typecheck/build/check sin errores; cada función nueva con una invocación que demuestre el comportamiento (criterio Fase 1); no declarar "listo" sin pasar toda la lista.

  5. **`verify` / Validar contra reglas**
     - description: validar una acción o cambio contra las reglas MUST/MUST_NOT (Fase 5) y las constraints C6 (Fase 6) usando `validate_action()`, y aplicar la verificación mínima antes de declarar listo.
     - prompt_template: "Valida `<acción>` con `validate_action(agent, action, details)`. Contrasta con MUST/MUST_NOT (Fase 5) y constraints C6 (Fase 6). Si `valid=false`, DETENTE y reporta las violaciones; nunca ignores un BLOCKER. Después ejecuta la verificación mínima C6.23."
     - required_context: reglas de la Fase 5, constraints C6, el agente que ejecuta (para el alcance del `scope`).
     - required_agent: `reviewer`.
     - required_skills: `architecture`, `security`, `testing` (matriz Fase 10 del reviewer).
     - validation_requirements: `validate_action()` consultado antes de cambios críticos; ninguna violación BLOCKER sin resolver; verificación mínima completa (C6.23) antes de declarar listo.

  6. **`review` / Revisar**
     - description: revisión de un cambio o trabajo completo contra el conocimiento registrado (ADRs, MUST/MUST_NOT, constraints, skills, evidencia path:line); **reporta hallazgos (contradicciones, desviaciones, deuda) sin corregirlos**.
     - prompt_template: "Revisa `<cambio/dif>`. Contrasta con ADRs (Fase 7), reglas (Fase 5), constraints C6 (Fase 6) y el patrón del skill del dominio (Fase 9). Verifica firma canónica, exigir_permiso, auditar, append-only, contrato JSONB, prefijos de callback, cabeceras de route handlers. Reporta cada hallazgo con evidencia path:line y su clasificación (contradicción / desviación / problema / UNKNOWN). NO corrijas."
     - required_context: ADRs, reglas, constraints, skills, el cambio a revisar.
     - required_agent: `reviewer`.
     - required_skills: `architecture`, `security`, `testing` (matriz Fase 10 del reviewer).
     - validation_requirements: todo hallazgo con evidencia path:line; cero modificaciones de código; contradicciones doc-vs-código conservadas; nada PLANNED presentado como EXISTING.

  7. **`session` / Sesión de trabajo**
     - description: iniciar o continuar una sesión de trabajo sobre el proyecto: leer el plan y el avance, verificar la fase/tarea siguiente en la tabla maestra, marcar el estado en `en_progreso` y rehidratar el contexto del agente asignado antes de ejecutar.
     - prompt_template: "Sesión de trabajo. 1) Lee el plan y el avance. 2) Verifica en la tabla maestra la próxima fase/tarea `pendiente`. 3) Marca el estado `en_progreso` en el avance. 4) Rehidrata el contexto del agente principal (Fase 8) + skills (Fase 9) + constraints (Fase 6). 5) Ejecuta."
     - required_context: `docs/avance-analisis-strictcontext.md`, el plan de incorporación, la tabla maestra, agentes/skills/constraints.
     - required_agent: el agente principal de la fase/tarea en curso (context-architect en el análisis; en el ciclo de desarrollo, el `assigned_agent` de la tarea).
     - required_skills: las del agente de la sesión (matriz Fase 10).
     - validation_requirements: el Estado global del avance refleja la sesión en `en_progreso`; rehidrata el contexto del agente correcto; no avanza a la siguiente fase sin haber registrado el estado.

  8. **`session-report` / Reporte de sesión**
     - description: cerrar una sesión: volcar los hallazgos con evidencia en la sección de la fase correspondiente del avance, actualizar la tabla maestra (`completada`), el Estado global y el Registro acumulado (incertidumbres/contradicciones/problemas), **sin avanzar a la siguiente fase** hasta registrar.
     - prompt_template: "Cierra la sesión: 1) vuelca los hallazgos con evidencia `path:line` en la sección de la fase del avance; 2) marca la fase `completada` en la tabla maestra y en el Estado global; 3) registra nuevas incertidumbres/contradicciones/problemas en el Registro acumulado; 4) NO inicies la siguiente fase hasta confirmar el registro."
     - required_context: la sección de la fase, la tabla maestra, el Estado global, el Registro acumulado del avance, el plan de incorporación.
     - required_agent: el agente principal de la fase que termina (context-architect en el análisis; `reviewer` para las fases de validación finales).
     - required_skills: las del agente de la sesión (matriz Fase 10).
     - validation_requirements: la fase queda `completada` y registrada antes de avanzar; evidencia path:line en cada hallazgo; nada PLANNED registrado como EXISTING; incertidumbres nuevas incorporadas al Registro acumulado.

- **Incertidumbres**:
  - **Mapeo de campos del plan §13 al esquema real de `commands`**: la tabla StrictContext tiene `steps/preconditions/expected_output/rollback_steps` (JSONB), no `prompt_template/required_context/required_skills/validation_requirements`. Interpretaciones posibles: (a) `prompt_template` → `steps` como primer paso; (b) `validation_requirements` → `preconditions`/`expected_output`; (c) `required_skills` → columna nueva o JSONB embebido. Se resuelve en Fase 14 (poblamiento). UNKNOWN.
  - **`required_agent` paramétrico**: `inspect`, `implement`, `test` y `session` dependen del dominio/tarea (la columna `commands.required_agent` es un solo valor). Alternativas para Fase 14: comandos genéricos sin agente fijo, o plantillas por agente. UNKNOWN.
  - **El runtime normal de StrictContext solo expone `get_command_steps()`** (lectura de pasos); no hay herramienta de "ejecutar comando". Por eso esta fase registra **solo especificaciones** (plan §13 lo ordena); la ejecución real dependerá del runtime futuro.
  - **`session`/`session-report` replican el protocolo del avance (misión de análisis)**, no del operativo del repo: el proyecto productivo no tiene un proceso formal de sesiones fuera de este análisis; su utilidad en el ciclo normal de desarrollo es indirecta. UNKNOWN baja (¿se mantienen como comandos del contexto de ingeniería o solo del de análisis?).
  - **Frontera `test` vs `verify`**: ambos ejecutan la verificación mínima C6.23; se separan por responsabilidad (test = el implementador comprueba su cambio; verify = reviewer valida contra reglas/constraints). Diferenciación de rol, no de contenido (PREFERENCE).

### Fase 12 — Separar el plan futuro del estado actual

- **Fecha / sesión**: 2026-08-09 / sesión 13
- **Agente**: context-architect
- **Directiva** (plan §14): leer el plan de desarrollo del proyecto **después** de terminar el análisis del repositorio (Fases 0–11 ya hechas), comparar `CURRENT STATE` vs `PLANNED STATE` y clasificar cada elemento del plan como `ALREADY_EXISTS` / `PARTIALLY_EXISTS` / `DOES_NOT_EXIST` / `UNKNOWN`. No registrar tareas futuras como funcionalidades existentes. Fuentes leídas: `chasquipet.md` §3 ("Fuera del MVP") y `docs/plan_ejecucion_chasquipet.md` (Fases 1 y 2, sesiones 1–20). La matriz producida alimenta la Fase 13 (crear tareas).

- **Estado actual verificado** (frente al plan): **todo el alcance MVP está completo** — los 8 pasos del orden de implementación (`chasquipet.md:440-451` §14: esquema base→turnos→inventario→clínico→cobro→compras→portal→jobs/demo) están en disco: 9 commits etiquetados "paso 1–8" (`git log --oneline`), migraciones 010→110 con seeds y 078, worker (11 manejadores), web en `(portal)`, 4 workflows n8n y scripts. Coincide con el `reporte-tecnico.md:385-409` (COMPLETO para turnos/inventario/clínico/cobro/compras/portal/jobs/backups). Nada de lo planificado es `ALREADY_EXISTS` completo.

- **Clasificación por elemento del plan** (detalle en la matriz):

  - **PARTIALLY_EXISTS** (solo esqueleto en el esquema, sin lógica ni UI):
    1. **Agendamiento de citas (citas + disponibilidad)** — tablas `disponibilidad` (050:126-139), `cita` (050:144-163) con triggers `*_touch`, índices parciales `idx_cita_agenda`/`idx_cita_paciente` (050:168-170), FK `consulta.cita_id` con UNIQUE parcial (050:181,221-222) y `cita.turno_id` (050:157) para converger turno↔cita. Comentario explícito: "Existen para que `consulta.cita_id` tenga a qué apuntar y para que activar citas más adelante sea añadir interfaz, no migrar historia clínica" (050:121-124). **No existe**: ninguna función de lógica (`crear_cita`, `slots_disponibles`, `crear_disponibilidad`, etc. = 0 matches), ni UI, ni flujo de bot, ni permisos seed. Es la intención exacta de `chasquipet.md:78` ("sin exponerlas en la UI").
    2. **Kiosco tablet** — el canal `tablet_kiosco` existe en el `CHECK (canal_origen IN ('qr_telegram','recepcion_manual','tablet_kiosco'))` de `turno.canal_origen` (030:64), como reserva. **No existe**: ninguna pantalla/tablero de kiosco, ningún flujo, ningún plan detallado (solo la mención de `chasquipet.md:81` "el modelo de datos ya soporta el canal `tablet_kiosco`").

  - **DOES_NOT_EXIST** (funcionalidad completa del plan futuro de `docs/plan_ejecucion_chasquipet.md` y §3):
    3. **Presupuestos / cotizaciones** (F1, sesiones 1–3; prefijo `pre:`) — 0 matches de `presupuesto*` en `db/` (grep). `reporte-tecnico.md:405` "PRESUPUESTOS/COTIZACIONES: NO ENCONTRADO".
    4. **Facturación electrónica DIAN vía Factus** (F1, sesiones 4–9) — el esquema `documento_electronico` está **diseñado pero no creado** (comentario `060_cobro.sql:26` y `chasquipet.md:299`; `reporte-tecnico.md:394` "NO IMPLEMENTADO"); el recibo actual es consecutivo interno "no factura" (`110_seed_operativo.sql:23`, `chasquipet.md:297` §7.4). Ni `documento_electronico`, `config_dian`, `municipio_dian` ni módulo Factus (`worker/src/factus/`) existen (grep: 0).
    5. **Carnet digital** (F2, sesiones 13–16) — 0 matches `carnet*` en `db/` y `worker/`. `reporte-tecnico.md:407` "NO ENCONTRADO".
    6. **Canal del cliente / modo dueño** (F2, sesión 17; prefijo `dueno:`) — no existe; el router de Telegram solo tiene 3 ramas (público sin usuario, personal por texto, personal por callback; `040_bot_turnos.sql:258-570`, ver Fase 3 §5) y no hay detección de modo dueño (`chat_id ∈ dueno.telegram_chat_id ∧ ∉ usuario.telegram_user_id`). Único contacto público con el dueño hoy: QR de turnos (rama A) y notificaciones push. `reporte-tecnico.md:23,408` "canal del cliente online: NO ENCONTRADO más allá del QR" y `reporte-tecnico.md:418` "sin API pública".
    7. **Marketing automatizado** (F2, sesión 18) — 0 matches de `campana_*`/`cumpleanos_mascota` en `worker/src/tareas/` y `n8n/workflows/` (los 4 workflows existentes 02/03/04 son turnos/inventario/mantenimiento, no marketing).
    8. **Reportes F1/F2** (sesiones 9 y 19) — los reportes actuales son los 12+traza del MVP (`web/src/lib/reportes.ts:38-259`: stock, consumo, turnos, turnos-hora, ocupacion, caja, descuentos, margen, compras, consultas, diagnosticos, pacientes; + trazabilidad). No existen `presupuestos`, `dian`, `citas`, `carnets` ni `canal_cliente`.
    9. **WhatsApp** (F2, sesión 20) — `DOES_NOT_EXIST`, y el propio plan dice **"No implementar aún. Solo documentar la extensión en el README."** (`plan_ejecucion_chasquipet.md:574-585`). No debe convertirse en tarea de implementación; a lo sumo una tarea de documentación.
    10. **Historia clínica por audio** (`chasquipet.md:80`), **hospitalización, laboratorio interno, app para el dueño** (`chasquipet.md:82`), **órdenes de compra formales / cuentas por pagar** (`chasquipet.md:83`, `reporte-tecnico.md:409`), **migración de datos históricos** (`chasquipet.md:84`) — `DOES_NOT_EXIST` sin especificación: a diferencia de las sesiones F1/F2, **no tienen detalle de plan** → `UNKNOWN` para Fase 13 (ver Incertidumbres).

  - **UNKNOWN / EXCLUIDO**:
    - **Medicamentos de control especial** (`chasquipet.md:85`) — `[CONFIRMAR]` pendiente con el cliente y el plan ordena "**No implementar ni modelar**". No es tarea.

- **Matriz detallada** (planned feature / current implementation / gap / dependencies / required agent / required skills / relevant rules / relevant constraints). Agente y skills per la matriz de Fase 10:

  1. **F1-S1 Esquema de Presupuestos** (`db/migrations/120_presupuestos.sql`; tablas `presupuesto`, `presupuesto_linea`, `presupuesto_historial`, trigger de recálculo, funciones `crear/agregar_linea/quitar_linea/enviar/aprobar/rechazar/convertir_presupuesto_cuenta/presupuesto_json/presupuestos_por_vencer/bot_presupuesto_texto/presupuesto_marcar_vencidos`, seed de permisos `presupuesto.*`).
     - current implementation: ninguna (0 evidencia).
     - gap: todo — tablas, triggers de recálculo (patrón 3ª familia, Fase 4 p.6), funciones de dominio con firma canónica, seed de permisos, job de vencidos.
     - dependencies: sobre el MVP completo (firma canónica, `exigir_permiso`, `auditar` ya existentes). `presupuesto_historial` hereda append-only.
     - required agent: `sql-engineer`.
     - required skills: postgres-business-logic, architecture, security, testing.
     - relevant rules: MUST 1, 2, 3, 5, 7, 9, 10; MUST_NOT 10; SHOULD 2, 3, 6.
     - relevant constraints: C6.1 (presupuesto_historial inmutable), C6.3 (numeric en dinero), C6.5 (exigir_permiso en toda escritura), C6.9 (convertir_presupuesto_cuenta = escritura de dinero → confirmación), C6.10 (sin SECURITY DEFINER sin search_path), C6.22 (auditar), C6.23 (verificación psql).

  2. **F1-S2 Bot Telegram — Flujo de Presupuestos** (prefijo `pre:`; reúso de `buscar_dueno`/`buscar_paciente`; FSM flujo='presupuesto'; botones Aprobar/Rechazar para el dueño; tareas worker `enviar_presupuesto_telegram` y `recordatorio_presupuesto_vencido`).
     - current implementation: ninguna.
     - gap: módulo de bot completo (stubs `bot_presupuesto_callback/texto`, orquestador, FSM), 2 manejadores worker.
     - dependencies: F1-S1.
     - required agent: `telegram-engineer` (con apoyo de backend-engineer para los 2 manejadores worker).
     - required skills: telegram, postgres-business-logic, security, testing.
     - relevant rules: MUST 5, 7; MUST_NOT 4 (QR no urgencia — n/a); SHOULD 5, 6, 9; PREFERENCE 2.
     - relevant constraints: C6.9 (confirmación por botón antes de dinero), C6.14 (prefijo `pre:` + registro en COALESCE de 078), C6.15 (rate limit), C6.16 (`{tipo, manejar}` en worker).
     - ⚠️ El plan propone "agregar `bot_manejar_presupuesto` al router existente" modificando `020_identidad.sql` — **contradice** la convención real de stubs encadenados `bot_modulo_callback/texto/media` + `COALESCE` en `078` y migraciones aditivas (Fase 4 p.10, Fase 10). Ver Contradicciones del plan.

  3. **F1-S3 Portal Web — Página de Presupuestos** (lista con filtros, formulario crear, detalle, acciones enviar/aprobar/convertir/anular, CSV).
     - current implementation: ninguna.
     - gap: páginas + Server Actions + reporte.
     - dependencies: F1-S1 (y F1-S2 para acciones de bot opcionales).
     - required agent: `frontend-engineer`.
     - required skills: nextjs-admin, architecture, security, testing.
     - relevant rules: MUST 11; MUST_NOT 6, 7; SHOULD 4.
     - relevant constraints: C6.12 (sin SQL crudo), C6.13 (route handlers cabecera fija — solo si hay export CSV por `api/reportes/[clave]`, patrón existente), C6.17 (sin password/HTTP externo).
     - ⚠️ El plan propone rutas `web/src/app/presupuestos/` **fuera de `(portal)`**: la convención real corta sesión en `(portal)/layout.tsx` (Fase 3 §6) → las páginas deben ir bajo `(portal)/presupuestos/`. Ver Contradicciones del plan.

  4. **F1-S4 Esquema DIAN + Factus** (`db/migrations/130_dian_factus.sql`; tablas `documento_electronico`, `config_dian`, `municipio_dian` + seed de municipios, funciones `emitir_factura_factus`, `factus_mapear_cuenta/customer/items`, `dian_habilitada_para_sede`, `documento_electronico_json`, permisos `dian.*`).
     - current implementation: ninguna (diseño previsto en `060_cobro.sql:23-28` y `chasquipet.md:295-299`; recibo interno `110_seed_operativo.sql:23`).
     - gap: todo el esquema nuevo; `documento_electronico` debe ser append-only (historial contable).
     - dependencies: sobre MVP (cuenta/cierre existentes, `recibo_numero` con `siguiente_numero_recibo` + advisory lock 060:279-291 — patrón C6.4 a replicar para numeración de documento).
     - required agent: `sql-engineer`.
     - required skills: postgres-business-logic, architecture, security, testing.
     - relevant rules: MUST 1, 2, 3, 4, 5; MUST_NOT 1, 2.
     - relevant constraints: C6.1/C6.2 (documento_electronico inmutable, jamás purgar), C6.3 (montos numeric), C6.4 (numeración/factura con advisory lock), C6.5 (exigir_permiso en emitir/anular), C6.11 (nueva tabla inmutable → agregar al array de 090:49), C6.22 (auditar emisión/anulación).

  5. **F1-S5 Worker — Módulo Factus** (`worker/src/factus/`: auth.js OAuth2 con caché de token, client.js, mapper.js; tarea `emitir_factus.js`; reglas: 80 req/min, 429→Retry-After, 422→no reintentar, backoff 30s→30min máx 5, idempotencia `reference_code='doc_'||id`).
     - current implementation: ninguna.
     - gap: módulo completo + manejador worker.
     - dependencies: F1-S4 (esquema) + credenciales Factus manuales (`plan_ejecucion_chasquipet.md:20-31`).
     - required agent: `integration-engineer`.
     - required skills: external-integrations, worker, security, testing.
     - relevant rules: MUST 14, 15; MUST_NOT 9, 10; SHOULD 8 (acotar GRANT no relacionado, pero sí secretos).
     - relevant constraints: C6.7 (secretos solo env: `.env` FACTUS_*), C6.16 (`{tipo, manejar}` + no DML directo a `tarea_async`), C6.21, ADR-12; patrón de idempotencia de Fase 4 p.9 (encolar con `clave_unicidad`).
     - ⚠️ El pseudocódigo del plan lee las tablas con `db.query('SELECT * FROM documento_electronico…')` (SQL directo en el worker) — **contradice** ADR-02/C6.16 ("el worker llama funciones SQL", `SELECT factus_mapear_cuenta($1)`). Ver Contradicciones del plan.

  6. **F1-S6 Bot Telegram — Emisión de Factura DIAN en el flujo de Cobro** (tras cerrar cuenta, si `dian_habilitada_para_sede`: botón "Emitir factura DIAN" `fac:emi:<cuenta_id>` / "Solo recibo interno"; tarea `enviar_factura_telegram` cuando el documento pasa a 'aceptado').
     - current implementation: ninguna (el cierre de cuenta existe: `060_cobro.sql` cierre + recibo; el flujo `cob:` existe `066_bot_cobro.sql`).
     - gap: bifurcación tras cerrar cuenta + envío al dueño con PDF/XML.
     - dependencies: F1-S4 + F1-S5.
     - required agent: `telegram-engineer` (flujo bot) + `sql-engineer` (función de dominio `emitir_factura_factus` y `cerrar_cuenta`).
     - required skills: telegram, postgres-business-logic, security, testing.
     - relevant rules: MUST 5; MUST_NOT 5 (habeas data: envío al dueño solo con `consentimiento_datos` + `telegram_chat_id`, como `enviar_recibo.js:42-47`); SHOULD 9.
     - relevant constraints: C6.9 (confirmación por botón antes de emitir), C6.14 (prefijos `fac:`/`cob:`), C6.16 (worker), C6.7 (credenciales).

  7. **F1-S7 Portal Web — Configuración DIAN + Bandeja de Documentos** (`admin/dian/page.tsx`, `admin/dian/documentos/page.tsx`: habilitar por sede, prefijo, régimen; bandeja por estado; reenviar/anular/descargar PDF/XML).
     - current implementation: ninguna.
     - gap: 2 páginas admin + funciones SQL de lectura.
     - dependencies: F1-S4.
     - required agent: `frontend-engineer` (+ `sql-engineer` para las funciones de lectura/acción).
     - required skills: nextjs-admin, architecture, security, testing.
     - relevant rules: MUST 1, 11; MUST_NOT 6, 7; SHOULD 4.
     - relevant constraints: C6.12, C6.13, C6.17; permisos `dian.*` como datos (`020`/`085` patrón).

  8. **F1-S8 Webhook de Factus** (opcional; `web/src/app/api/factus/webhook/route.ts`: POST, firma HMAC con `FACTUS_WEBHOOK_SECRET`, actualiza estado de `documento_electronico`).
     - current implementation: ninguna.
     - gap: route handler público con validación de firma.
     - dependencies: F1-S5.
     - required agent: **UNKNOWN** — es un adaptador externo que vive en `web/**`; `integration-engineer` (dueño de adapters, ADR-12) no puede editar `web/**` por sus forbidden_tools (Fase 8) y `frontend-engineer` (dueño de web) no tiene skill external-integrations. Ver Incertidumbres.
     - required skills: UNKNOWN (según resolución; candidato: nextjs-admin + external-integrations).
     - relevant rules: MUST 11; MUST_NOT 7.
     - relevant constraints: C6.7 (FACTUS_WEBHOOK_SECRET solo env), C6.13 (route handler con `runtime='nodejs'`+`force-dynamic`), C6.15 (rate limit en puerta pública no autenticada).

  9. **F1-S9 Reportes + Pulido F1** (`reportes.ts`: claves `presupuestos` y `dian`; validaciones "no emitir DIAN sin NIT del dueño", "no presupuesto sin líneas"; edge cases bruto).
     - current implementation: 12+traza reportes MVP (`web/src/lib/reportes.ts:38-259`).
     - gap: 2 claves nuevas + `reporte_*` SQL (080 patrón) + validaciones.
     - dependencies: F1 completo (S1–S8).
     - required agent: `frontend-engineer` (+ `sql-engineer` para las funciones `reporte_presupuestos`/`reporte_dian`).
     - required skills: nextjs-admin, architecture, security, testing.
     - relevant rules: reportes con `p_desde/p_hasta` opcionales = mes en curso (SHOULD 2, `080_reportes.sql:12,24-34`).
     - relevant constraints: C6.12, C6.13 (CSV vía `api/reportes/[clave]` con sesión+permiso, patrón existente).

  10. **F2-S10 Esquema de Citas y Disponibilidad** (`db/migrations/140_citas.sql`: completar columnas de `cita`/`disponibilidad`, índices, vista `v_slots_disponibles`, funciones `crear/eliminar_disponibilidad`, `slots_disponibles`, `crear/confirmar/cancelar/reprogramar_cita`, `citas_por_fecha`, `bot_cita_texto`; permisos `cita.*`, `disponibilidad.*`).
      - current implementation: PARTIAL — tablas `cita` (050:144-163) y `disponibilidad` (050:126-139) ya tienen el esquema casi completo (sede, paciente, dueno, tipo_servicio_id, veterinario, consultorio, inicio/fin_at, estado con CHECK `programada|confirmada|cumplida|cancelada|no_asistio`, `turno_id` FK para convergencia, triggers `*_touch`, índices parciales). Sin funciones, sin vista de slots, sin UI.
      - gap: lógica de agendamiento (funciones, vista de slots), permisos, y respetar el diseño de convergencia turno↔cita (`cita.turno_id`, `consulta.cita_id`).
      - dependencies: ninguna nueva (tablas ya existen); los `ALTER TABLE` deben ser ADD COLUMN IF NOT EXISTS respeciendo la base 050.
      - required agent: `sql-engineer`.
      - required skills: postgres-business-logic, architecture, security, testing.
      - relevant rules: MUST 7 (estado conversacional — tangencial), MUST 3; SHOULD 2, 3.
      - relevant constraints: C6.5 (exigir_permiso en escrituras de cita), C6.3 (si hay precios), C6.22 (auditar reprogramar/cancelar), C6.23.

  11. **F2-S11 Bot Telegram — Flujo de Reserva para dueños** (prefijo `cit:`; FSM flujo='cita' paso sede/fecha/slot/paciente/motivo/confirmar; `slots_disponibles`; tarea `enviar_confirmacion_cita`, `recordatorio_cita_24h`, `recordatorio_cita_2h`).
      - current implementation: ninguna.
      - gap: flujo completo de bot + 3 manejadores worker.
      - dependencies: F2-S10 (también depende de que la identidad del dueño exista — sí, `dueno.telegram_chat_id`, `020`/`050`).
      - required agent: `telegram-engineer` (+ `backend-engineer` para los manejadores worker de recordatorios).
      - required skills: telegram, postgres-business-logic, security, testing.
      - relevant rules: MUST 5, 7; SHOULD 5, 6, 9; PREFERENCE 2.
      - relevant constraints: C6.9 (confirmación por botón antes de crear cita), C6.14 (prefijo `cit:`), C6.15 (rate limit en puerta pública — la reserva la hace el dueño sin sesión), C6.16 (worker).
      - ⚠️ El plan dice "Dueño escribe `/reservar`" (`plan_ejecucion_chasquipet.md:398`) — **contradice** el hallazgo de Fase 3 (no existen comandos de texto `/turno`/`/turnos` en ninguna migración; la operación es por botones/callbacks). El acceso real debe ser por botón/menú, no por comando. Ver Contradicciones del plan.

  12. **F2-S12 Portal Web — Configuración de Disponibilidad** (`admin/disponibilidad/page.tsx`: calendario semanal, franjas, duración de slot, asignar veterinario, activar/desactivar).
      - current implementation: ninguna.
      - gap: página admin + Server Actions.
      - dependencies: F2-S10.
      - required agent: `frontend-engineer`.
      - required skills: nextjs-admin, architecture, security, testing.
      - relevant rules: MUST 11; MUST_NOT 6, 7.
      - relevant constraints: C6.12, C6.13, C6.17.

  13. **F2-S13 Esquema de Carnet Digital** (`db/migrations/150_carnet.sql`: `carnet_digital`, `carnet_registro`, funciones `generar_carnet`, `registrar_en_carnet`, `carnet_json`, `carnet_por_codigo`, `proximos_vencimientos_carnet`, `bot_carnet_texto`).
      - current implementation: ninguna (0 evidencia).
      - gap: todo.
      - dependencies: sobre MVP (pacientes/vacunas ya existen; el trigger de vacunas al firmar consulta toca el dominio clínico `050`).
      - required agent: `sql-engineer`.
      - required skills: postgres-business-logic, architecture, security, testing.
      - relevant rules: MUST 1, 2, 3; MUST_NOT 2 (datos clínicos del carnet no se purgan).
      - relevant constraints: C6.5, C6.10, C6.22, C6.23; privacidad Ley 1581 (el carnet público expone solo nombre y teléfono de contacto — `plan_ejecucion_chasquipet.md:512`, ver F2-S16).

  14. **F2-S14 Worker — Generación de PDF del Carnet** (`worker/src/tareas/generar_pdf_carnet.js`: pdf-lib/qrcode, template HTML, QR único, guardar en `/backups/carnets/` o volumen, actualizar `carnet_digital.url_publica`).
      - current implementation: ninguna; el worker no genera PDFs (0 uso de librerías gráficas, deps solo `pg`+`openai`).
      - gap: tarea worker + nuevas deps del contenedor.
      - dependencies: F2-S13.
      - required agent: `backend-engineer` (dueño del worker; la generación de PDF es tarea de cola, no un adapter externo) — ver Incertidumbres si se prefiere integration-engineer.
      - required skills: worker, architecture, security, testing.
      - relevant rules: MUST 14, 15; MUST_NOT 10.
      - relevant constraints: C6.16 (contrato `{tipo, manejar}`), C6.23.

  15. **F2-S15 Bot Telegram — Carnet del Dueño** ("Mi carnet", selección de mascota, genera/actualiza PDF, compartir QR; trigger al firmar consulta con vacuna → `carnet_registro`).
      - current implementation: ninguna.
      - gap: flujo de bot + trigger de vacunas en el dominio clínico (este trigger es sql-engineer).
      - dependencies: F2-S13 + F2-S14.
      - required agent: `telegram-engineer` (+ `sql-engineer` para el trigger de vacunas).
      - required skills: telegram, postgres-business-logic, security, testing.
      - relevant rules: MUST 5, 10 (inmutabilidad clínica — el registro en carnet es derivado), SHOULD 5, 6.
      - relevant constraints: C6.9, C6.14 (prefijo carnet), C6.16.

  16. **F2-S16 Página Pública del Carnet** (`web/src/app/carnet/[codigo]/page.tsx`, sin auth, lee `carnet_por_codigo`).
      - current implementation: ninguna (la única página pública actual es `pantalla/[sede]`, sin datos personales).
      - gap: página pública con QR → datos del paciente.
      - dependencies: F2-S13.
      - required agent: `frontend-engineer`.
      - required skills: nextjs-admin, architecture, security, testing.
      - relevant rules: MUST 11; MUST_NOT 7 (sin datos sensibles del dueño — `plan_ejecucion_chasquipet.md:512`).
      - relevant constraints: C6.13 (router/SSR público), C6.15 (rate limit en página pública sin auth — patrón `turno:chat`/`login:`), C6.17; Ley 1581 habeas data (aplica a la exposición pública).

  17. **F2-S17 Canal del Cliente — Menú del Dueño en Telegram** (detección de modo dueño, menú "Mis mascotas/citas/carnet/facturas", flujos `dueno:mascotas`, `dueno:citas`, `dueno:facturas`, `dueno:reservar`, `dueno:carnet`).
      - current implementation: ninguna — no existe modo dueño en el router (solo ramas público/personal, `040_bot_turnos.sql:258-570`); la única rama pública es QR de turnos.
      - gap: nueva rama de identidad "dueño" en el router (chat_id en `dueno.telegram_chat_id` y no en `usuario.telegram_user_id`), menú y 5 flujos.
      - dependencies: F2-S11 (reserva), F2-S15 (carnet), F1-S6 (facturas DIAN — o al menos recibos).
      - required agent: `telegram-engineer`.
      - required skills: telegram, postgres-business-logic, security, testing.
      - relevant rules: MUST 5, 7; MUST_NOT 5 (habeas data en las notificaciones al dueño); SHOULD 5, 6, 9.
      - relevant constraints: C6.9, C6.14 (prefijo `dueno:` + registro en COALESCE de 078), C6.15, C6.16.

  18. **F2-S18 Marketing Automatizado** (jobs `cumpleanos_mascota`, `campana_vacunacion`, `reactivacion_cliente`; portal `admin/marketing/page.tsx`).
      - current implementation: ninguna (los 4 workflows n8n existentes son turnos/inventario/mantenimiento).
      - gap: 2–3 jobs (n8n scheduleTrigger→SQL o worker) + página admin.
      - dependencies: F2-S11, F2-S13, F2-S17 (datos de citas/carnets/canal cliente).
      - required agent: `backend-engineer` (jobs) + `frontend-engineer` (página admin).
      - required skills: worker, architecture, security, testing (backend); nextjs-admin, architecture, security, testing (frontend).
      - relevant rules: MUST 6 (webhook/jobs → cola); Fase 4 p.22 (jobs = scheduler→SQL puro).
      - relevant constraints: C6.16, C6.23. ⚠️ `cumpleanos_mascota` busca `fecha_nacimiento = hoy` pero el esquema real usa `fecha_nacimiento_aprox` (050) — notar al redactar la tarea.

  19. **F2-S19 Reportes F2 + Pulido** (`reportes.ts`: claves `citas`, `carnets`, `canal_cliente`; rate limiting en endpoints públicos, fallback del bot).
      - current implementation: 12+traza reportes MVP.
      - gap: 3 claves nuevas + `reporte_*` SQL + pulido.
      - dependencies: F2 completo.
      - required agent: `frontend-engineer` (+ `sql-engineer` para funciones `reporte_citas/carnets/canal_cliente`).
      - required skills: nextjs-admin, architecture, security, testing.
      - relevant rules: SHOULD 2 (reportes con `p_desde/p_hasta`), Fase 4 p.23/25.
      - relevant constraints: C6.12, C6.13, C6.15.

- **Contradicciones del PLAN (futuro) vs convenciones reales** (críticas para redactar las tareas de Fase 13 sin heredar el error del plan):
  1. `docs/plan_ejecucion_chasquipet.md` Anexo C (p.666-699) manda `RAISE EXCEPTION USING errcode='P0001'` y `hint='...'` — **contradice** el patrón real verificado (Fase 4 p.4 y C6.1-6.18): los códigos de negocio son `23514`, `0A000`, `42501`, `28000`, y jamás aparece `P0001` ni `hint=`.
  2. F1-S2 (plan: agregar `bot_manejar_presupuesto` al router existente modificando `020_identidad.sql`) — contradice el patrón de **stubs encadenados + COALESCE** (`040_bot_turnos.sql:63-95`, `078_chasqui_ia.sql:1012-1043`) y las migraciones aditivas; un módulo nuevo se añade por `CREATE OR REPLACE` de su `bot_<mod>_callback/texto` y se registra en el orquestador `078`, nunca editando `020` ni el router.
  3. F1-S5 pseudocódigo (SQL directo `SELECT * FROM documento_electronico` en el worker) — contradice ADR-02 y C6.16 (el worker llama funciones SQL; no DML directo ni lectura suelta).
  4. F1-S3 (rutas `web/src/app/presupuestos/page.tsx` y F1-S7 `admin/dian/...` fuera del grupo `(portal)`) — el portal real corta sesión en `(portal)/layout.tsx` (Fase 3 §6); la UI administrativa debe vivir bajo `(portal)/`.
  5. F2-S11 ("Dueño escribe `/reservar`") — contradice Fase 3/5 (no hay comandos de texto `/turno`; la operación es por botones/callbacks con prefijo); el flujo debe ser por botón/menú con prefijo `cit:`.
  6. F1-S5 credenciales Factus: el plan insiste en `.env` — coincidente con C6.7 (no es contradicción, se confirma). El número del recibo usa el patrón correcto con advisory lock (`siguiente_numero_recibo`, `060_cobro.sql:279-291`), a replicar.

- **Incertidumbres**:
  - **Webhook de Factus (F1-S8)**: vive en `web/**` pero es un adaptador externo; `integration-engineer` no puede editar `web/**` (forbidden_tools Fase 8) y `frontend-engineer` no tiene skill `external-integrations`. Opciones: (a) ampliar allowed_tools de `integration-engineer` para el route handler del webhook; (b) asignarlo a `frontend-engineer` siguiendo el patrón C6.13 con la firma HMAC validada en un helper; (c) tratarlo como endpoint de orquestación → `backend-engineer`. Decide Fase 13/14. UNKNOWN.
  - **F1-S9/F2-S19 reportes**: la frontera frontend↔sql para `reporte_*` es la misma de Fase 9 ("función SQL de dominio a sql-engineer, página a frontend-engineer"); se asume sin riesgo pero no está escrita como regla. UNKNOWN baja.
  - **Carne PDF worker (F2-S14)**: `backend-engineer` (dueño del worker) vs `integration-engineer` (adapters); PDF es generación interna de contenido, no adapter externo → se asigna a backend-engineer, pero es una decisión de autoridad no verificable en el código (no existe precedente de PDF). UNKNOWN baja.
  - **Features de `chasquipet.md` §3 sin detalle de plan** (`chasquipet.md:80-84`): historia clínica por audio, hospitalización, laboratorio interno, app para el dueño, órdenes de compra formales/cuentas por pagar, migración de datos históricos — `DOES_NOT_EXIST` pero **UNKNOWN para Fase 13** (no hay especificación en `plan_ejecucion_chasquipet.md`; no deben convertirse en tareas hasta tener detalle).
  - **Kiosco tablet**: el canal `tablet_kiosco` está reservado (030:64) pero no hay plan de implementación en `plan_ejecucion_chasquipet.md` (no está en las 20 sesiones). UNKNOWN si esa funcionalidad se planifica con tareas o se deja documentada.
  - **Medicamentos de control especial** (`chasquipet.md:85`): `[CONFIRMAR]` pendiente con el cliente; el plan ordena no implementar ni modelar. Queda como decisión pendiente, no tarea.
  - **Habilitación legal DIAN** (Anexo D, `plan_ejecucion_chasquipet.md:718-729`): precedente a la operación real de F1-S6; depende del cliente y de Factus, fuera del alcance de codificación.

### Fase 13 — Crear las tareas futuras

- **Fecha / sesión**: 2026-08-09 / sesión 14
- **Agente**: context-architect
- **Directiva** (plan §15): transformar el plan de desarrollo en tareas StrictContext, manteniendo la separación contexto vs. trabajo. Cada tarea con `title / description / assigned_agent / required_skills / dependencies / acceptance_criteria / status = PENDING`. Criterios de aceptación **verificables** (evitar "implementar correctamente"; preferir "existe la función X", "existe la tabla Y", "se verifica permiso Z", "se registra auditoría", "se ejecuta prueba A"). Se corrige explícitamente en las descripciones las 5 contradicciones del plan vs. convenciones reales detectadas en Fase 12 (P0001→ERRCODE semánticos; stubs+COALESCE en vez de editar 020/router; worker llama funciones SQL, no DML directo; rutas web bajo `(portal)`; operación por botones/callbacks, no comandos de texto).
- **Fuente**: matriz de Fase 12 (19 elementos F1-S1…F2-S19) + plan `docs/plan_ejecucion_chasquipet.md` (sesiones 1–19) y `chasquipet.md` §3. WhatsApp = solo documentación (plan_sesión_20). NO tarea: features §3 sin detalle, kiosco tablet, medicamentos de control especial (Fase 12 → UNKNOWN/excluido).
- **Notas de decisiones**:
  - **F1-S8 (webhook Factus)** → **frontend-engineer** (era UNKNOWN en Fase 12): el webhook vive en `web/**` (que integration-engineer tiene prohibido editar, Fase 8) y es un route handler con la forma C6.13; la lógica Factus vive en las funciones SQL de F1-S4/S1-S8, no en el handler. Se levanta la restricción para que integration-engineer no la requiera; el route handler lo implementa frontend-engineer aplicando firma HMAC (helper, véase Incertidumbres).
  - **F2-S14 (PDF carnet)** → **backend-engineer** (dueño del worker; generación de contenido, no adapter externo). Confirmada la decisión de Fase 12.
  - **F2-S20 (WhatsApp)** → tarea de **documentación**, no de implementación (el plan lo ordena: "No implementar aún. Solo documentar la extensión en el README").
- **Tareas** (id / title / description / assigned_agent / required_skills / dependencies / acceptance_criteria / status): todas `status = PENDING`.

  **F1 — Presupuestos**

  1. **`f1-s1-presupuestos-esquema`** / **F1-S1 — Esquema de Presupuestos (SQL)**
     - description: crear `db/migrations/120_presupuestos.sql` aditiva (patrón migraciones, Fase 4 p.6): tablas `presupuesto`, `presupuesto_linea`, `presupuesto_historial`; trigger de recálculo de totales (3ª familia, Fase 4 p.6); funciones de dominio con firma canónica `p_actor_id uuid` + `p_canal text DEFAULT 'telegram'`: `crear/agregar_linea/quitar_linea/enviar/aprobar/rechazar/convertir_presupuesto_cuenta/presupuesto_json/presupuestos_por_vencer/presupuesto_marcar_vencidos`; helper `bot_presupuesto_texto` como stub de bot (Fase 10); seed de permisos `presupuesto.*` (patrón `100_seed_roles.sql`). Errores con ERRCODE semántico (`23514`/`0A000`/`42501`/`28000`), **nunca `P0001`** (contradicción plan Anexo C).
     - assigned_agent: `sql-engineer`.
     - required_skills: `[postgres-business-logic, architecture, security, testing]`.
     - dependencies: `[]`.
     - acceptance_criteria:
       - "existe `db/migrations/120_presupuestos.sql` y se aplica sobre BD demo con `psql -v ON_ERROR_STOP=1` (C6.23)"
       - "existen las tablas `presupuesto`, `presupuesto_linea`, `presupuesto_historial` con sus triggers de recálculo"
       - "existen las funciones `presupuesto_json`, `crear_presupuesto`, `convertir_presupuesto_cuenta` con firma `p_actor_id uuid` + `exigir_permiso` y contrato `jsonb {ok,…}`"
       - "`presupuesto_historial` es append-only (sin UPDATE/DELETE para `chasquipet_app`, patrón C6.1/090:49)"
       - "se registra `auditar(...)` en las escrituras de presupuesto (C6.22)"
       - "`grep -E "P0001" db/migrations/120_presupuestos.sql` → 0 resultados"
       - "cada función nueva con una invocación `psql` que demuestre el comportamiento (C6.23)"

  2. **`f1-s2-presupuestos-bot`** / **F1-S2 — Bot Telegram — Flujo de Presupuestos**
     - description: módulo de bot con prefijo `pre:` como stub encadenado (NO editar `020_identidad.sql` ni el router — contradicción plan F1-S2): redefinir `bot_presupuesto_callback`/`bot_presupuesto_texto` con guardia `IF v_partes[1] <> 'pre' THEN RETURN NULL` (Fase 4 p.10) y registrarlos en el orquestador COALESCE de `078` (Fase 10). FSM con `estado_guardar/leer/limpiar` (flujo='presupuesto'). Reuso de `buscar_dueno`/`buscar_paciente`. Botones Aprobar/Rechazar para el dueño (confirmación por botón antes de dinero, C6.9). Tareas worker `enviar_presupuesto_telegram` y `recordatorio_presupuesto_vencido` con contrato `{tipo, manejar}` (C6.16) y `encolar_tarea` con `clave_unicidad`.
     - assigned_agent: `telegram-engineer` (apoyo `backend-engineer` para los 2 manejadores worker).
     - required_skills: `[telegram, postgres-business-logic, security, testing]`.
     - dependencies: `["f1-s1-presupuestos-esquema"]`.
     - acceptance_criteria:
       - "existen `bot_presupuesto_callback` y `bot_presupuesto_texto` redefinidos con guardia de prefijo `pre:` y retorno NULL cuando no es suyo"
       - "`078_chasqui_ia.sql` incluye el módulo presupuesto en los COALESCE de `bot_modulo_callback`/`bot_modulo_texto`"
       - "`020_identidad.sql` y `040_bot_turnos.sql` permanecen sin cambios (grep comparado con HEAD)"
       - "Aprobar/Rechazar/convertir exigen confirmación por botón (C6.9)"
       - "existen los manejadores `enviar_presupuesto_telegram.js` y `recordatorio_presupuesto_vencido.js` con `export const tipo` + `manejar`"
       - "`npm run check` (worker) y `npm run typecheck` (web, si toca) sin errores"

  3. **`f1-s3-presupuestos-web`** / **F1-S3 — Portal Web — Página de Presupuestos**
     - description: páginas bajo **`(portal)/presupuestos/`** (NO `web/src/app/presupuestos/` directo — contradicción plan F1-S3; el portal corta sesión en `(portal)/layout.tsx`): lista con filtros, formulario crear, detalle y acciones enviar/aprobar/convertir/anular vía Server Actions que llaman funciones SQL con `$1` = actor (C6.13), doble cerradura `exigirPermiso` web + SQL. CSV opcional por `api/reportes/[clave]` (patrón existente). Sin SQL crudo inline (C6.12), sin `password`, sin HTTP externo (C6.17).
     - assigned_agent: `frontend-engineer`.
     - required_skills: `[nextjs-admin, architecture, security, testing]`.
     - dependencies: `["f1-s1-presupuestos-esquema"]`.
     - acceptance_criteria:
       - "existen `web/src/app/(portal)/presupuestos/` con listado, creación, detalle y acciones"
       - "todas las Server Actions llaman funciones SQL con `$1 = sesion.usuario_id` y `exigirPermiso` previo"
       - "`grep -E "\.query\(" web/src/app/\(portal\)/presupuestos` → 0 (sin SQL crudo nuevo, C6.12)"
       - "`npm run typecheck` y `npm run build` en web sin errores"
       - "las rutas quedan protegidas por el layout `(portal)` (verificado con sesión)"

  **F1 — DIAN / Factus**

  4. **`f1-s4-dian-esquema`** / **F1-S4 — Esquema DIAN + Factus (SQL)**
     - description: crear `db/migrations/130_dian_factus.sql` aditiva: `documento_electronico` (append-only → agregar al array de 090:49, C6.11), `config_dian`, `municipio_dian` + seed de municipios; funciones `emitir_factura_factus`, `factus_mapear_cuenta/factus_mapear_customer/factus_mapear_items`, `dian_habilitada_para_sede`, `documento_electronico_json`; permisos `dian.*`. Numeración del documento con `pg_advisory_xact_lock` replicando `siguiente_numero_recibo` (060:279-291, C6.4). Montos `numeric` (C6.3). ERRCODE semánticos, jamás `P0001`.
     - assigned_agent: `sql-engineer`.
     - required_skills: `[postgres-business-logic, architecture, security, testing]`.
     - dependencies: `[]`.
     - acceptance_criteria:
       - "existe `db/migrations/130_dian_factus.sql` aplicable sobre BD demo con `ON_ERROR_STOP`"
       - "existen `documento_electronico`, `config_dian`, `municipio_dian` y el seed de municipios"
       - "`documento_electronico` sin UPDATE/DELETE/TRUNCATE para `chasquipet_app` y está en el array append-only de `090:49`"
       - "existe `emitir_factura_factus` con `exigir_permiso('dian.emitir')`, `auditar` y contrato `jsonb {ok,…}`"
       - "la numeración del documento usa `pg_advisory_xact_lock` (patrón `siguiente_numero_recibo`)"
       - "montos de `documento_electronico` son `numeric`, no `real`/`double` (C6.3)"
       - "`grep "P0001" db/migrations/130_dian_factus.sql` → 0"

  5. **`f1-s5-dian-worker`** / **F1-S5 — Worker — Módulo Factus**
     - description: módulo `worker/src/factus/` (auth.js OAuth2 con caché de token, client.js, mapper.js) y tarea `emitir_factus.js`. **El worker llama SOLO funciones SQL** (`SELECT factus_mapear_cuenta($1)`…), nunca `db.query('SELECT * …')` suelto — contradicción plan F1-S5/ADR-02/C6.16. Reglas provider: 80 req/min, 429→Retry-After, 422→no reintentar, backoff 30s→30min máx 5, idempotencia `reference_code = 'doc_'||id` (149). Secretos `FACTUS_*` solo por env (C6.7). Política de reintento del worker (telegram.js: no para Factus pero contrato `{ok:false}`/throw coherente con C6.16).
     - assigned_agent: `integration-engineer`.
     - required_skills: `[external-integrations, worker, security, testing]`.
     - dependencies: `["f1-s4-dian-esquema"]`.
     - acceptance_criteria:
       - "existen `worker/src/factus/auth.js`, `client.js`, `mapper.js` y la tarea `emitir_factus.js`"
       - "la tarea exporta `{tipo:'emitir_factus', manejar}` (contrato C6.16)"
       - "0 usos de `db.query` con SQL directo sobre tablas de dominio en `worker/src/factus` (grep; siempre vía función SQL)"
       - "secretos `FACTUS_CLIENT_ID/PASSWORD/API_URL` leídos solo de env (`process.env`), nunca literales (grep de secretos → 0)"
       - "idempotencia: `reference_code='doc_'||id` y `clave_unicidad` en `encolar_tarea` (patrón Fase 4 p.9)"
       - "`npm run check` en worker sin errores; el mapper se prueba con payload de ejemplo (C6.23)"

  6. **`f1-s6-dian-bot`** / **F1-S6 — Bot Telegram — Emisión de Factura DIAN en el flujo de Cobro**
     - description: tras cerrar cuenta y si `dian_habilitada_para_sede`, ofrecer botón "Emitir factura DIAN" (`fac:emi:<cuenta_id>`) vs "Solo recibo interno" (confirmación por botón antes de emitir, C6.9). Tarea `enviar_factura_telegram` cuando el documento pasa a 'aceptado'. Prefijos `fac:`/`cob:` registrados en COALESCE de `078`. Envío al dueño respetando habeas data: solo con `consentimiento_datos` + `telegram_chat_id` (patrón `enviar_recibo.js:42-47`, MUST_NOT 5).
     - assigned_agent: `telegram-engineer` (apoyo `sql-engineer` para `emitir_factura_factus` y `cerrar_cuenta`).
     - required_skills: `[telegram, postgres-business-logic, security, testing]`.
     - dependencies: `["f1-s4-dian-esquema", "f1-s5-dian-worker"]`.
     - acceptance_criteria:
       - "existe el botón `fac:emi:<cuenta_id>` en el flujo de cobro con confirmación por callback"
       - "existe el manejador worker `enviar_factura_telegram` con `{tipo, manejar}`"
       - "prefijos `fac:` y `cob:` presentes en el orquestador COALESCE de `078`"
       - "el envío al dueño se filtra por `dueno.consentimiento_datos` y `dueno.telegram_chat_id` (grep del manejador)"
       - "no se auto-emite sin botón (C6.9) — verificado con psql del flujo"

  7. **`f1-s7-dian-web`** / **F1-S7 — Portal Web — Configuración DIAN + Bandeja de Documentos**
     - description: `(portal)/admin/dian/page.tsx` (habilitar por sede, prefijo, régimen) y `(portal)/admin/dian/documentos/page.tsx` (bandeja por estado, reenviar/anular/descargar PDF/XML). NO bajo `web/src/app/admin/dian` directo (contradicción plan F1-S7; sesión en `(portal)/layout.tsx`). Server Actions con `$1`=actor, funciones SQL de lectura/acción (no SQL crudo, C6.12), CSV por `api/reportes/[clave]` si aplica. Permisos `dian.*` como datos (C6.13).
     - assigned_agent: `frontend-engineer` (apoyo `sql-engineer` para las funciones de lectura/acción de la bandeja).
     - required_skills: `[nextjs-admin, architecture, security, testing]`.
     - dependencies: `["f1-s4-dian-esquema"]`.
     - acceptance_criteria:
       - "existen `(portal)/admin/dian/page.tsx` y `(portal)/admin/dian/documentos/page.tsx` protegidos por el layout"
       - "todas las Server Actions toman `$1 = sesion.usuario_id` y validan permiso `dian.*` (C6.13)"
       - "descarga PDF/XML vía route handler con cabeceras fijas (C6.13) o archivo servido con sesión"
       - "`grep -E "\.query\("` en esas páginas → 0 (sin SQL crudo nuevo)"
       - "`npm run typecheck`/`build` sin errores"

  8. **`f1-s8-dian-webhook`** / **F1-S8 — Webhook de Factus (opcional)**
     - description: `web/src/app/api/factus/webhook/route.ts` (POST, pública, `runtime='nodejs'`+`force-dynamic`+`no-store`, C6.13) que valida firma HMAC con `FACTUS_WEBHOOK_SECRET` (solo env, C6.7; helper de verificación) y actualiza el estado de `documento_electronico` vía función SQL (no SQL crudo, C6.12); sin credenciales en git. Rate limit en puerta pública (C6.15). **Asignado a frontend-engineer** (route handler en `web/**`; la lógica Factus vive en SQL de F1-S4/F1-S8, no en el handler).
     - assigned_agent: `frontend-engineer`.
     - required_skills: `[nextjs-admin, security, testing]`.
     - dependencies: `["f1-s5-dian-worker"]`.
     - acceptance_criteria:
       - "existe `web/src/app/api/factus/webhook/route.ts` con las 3 cabeceras de route handler (nodejs/force-dynamic/no-store)"
       - "la firma HMAC se valida contra `process.env.FACTUS_WEBHOOK_SECRET` (nunca literal)"
       - "el handler llama funciones SQL (grep: 0 `db.query` con SQL de dominio)"
       - "público con rate limit si aplica (C6.15) y capacidad de probarse con firma conocida (C6.23)"

  9. **`f1-s9-reportes`** / **F1-S9 — Reportes + Pulido F1**
     - description: agregar claves `presupuestos` y `dian` a `web/src/lib/reportes.ts` con sus `reporte_*` SQL (patrón 080, `p_desde/p_hasta` opcionales = mes en curso, SHOULD 2) y CSV por `api/reportes/[clave]` con sesión+permiso (C6.13). Validaciones: "no emitir DIAN sin NIT del dueño" y "no presupuesto sin líneas" (implementadas en SQL, no en UI).
     - assigned_agent: `frontend-engineer` (apoyo `sql-engineer` para `reporte_presupuestos`/`reporte_dian`).
     - required_skills: `[nextjs-admin, architecture, security, testing]`.
     - dependencies: `["f1-s1-presupuestos-esquema", "f1-s4-dian-esquema", "f1-s6-dian-bot", "f1-s7-dian-web"]`.
     - acceptance_criteria:
       - "existen las claves `presupuestos` y `dian` en `reportes.ts` y sus funciones `reporte_presupuestos`/`reporte_dian` en SQL"
       - "los reportes aceptan `p_desde/p_hasta` con default mes en curso (patrón 080)"
       - "CSV exportable por `api/reportes/[clave]` con sesión + permiso"
       - "`npm run typecheck`/`build` sin errores; cada `reporte_*` con invocación psql (C6.23)"

  **F2 — Citas / Disponibilidad**

  10. **`f2-s10-citas-esquema`** / **F2-S10 — Esquema de Citas y Disponibilidad (SQL)**
      - description: completar las tablas **ya existentes** `cita`/`disponibilidad` (050:126-170, PARTIALLY_EXISTS) con migración aditiva `db/migrations/140_citas.sql` (ADD COLUMN respetando 050): columnas faltantes, índices, vista `v_slots_disponibles`, funciones `crear/eliminar_disponibilidad`, `slots_disponibles`, `crear/confirmar/cancelar/reprogramar_cita`, `citas_por_fecha`, `bot_cita_texto`; permisos `cita.*`, `disponibilidad.*`. Respetar la convergencia turno↔cita (`cita.turno_id`, `consulta.cita_id`, 050:157,181,221-222).
      - assigned_agent: `sql-engineer`.
      - required_skills: `[postgres-business-logic, architecture, security, testing]`.
      - dependencies: `[]`.
      - acceptance_criteria:
        - "existe `db/migrations/140_citas.sql` aplicable sobre BD demo con `ON_ERROR_STOP`"
        - "existe la vista `v_slots_disponibles` (familia de vistas, Fase 2)"
        - "existen `crear_cita`, `confirmar_cita`, `cancelar_cita`, `reprogramar_cita` con `exigir_permiso`, `auditar` y contrato `jsonb {ok,…}`"
        - "no se borra ni altera la base 050 de manera destructiva (ADD COLUMN IF NOT EXISTS en su caso)"
        - "cada función con invocación psql (C6.23)"

  11. **`f2-s11-citas-bot`** / **F2-S11 — Bot Telegram — Flujo de Reserva para dueños**
      - description: flujo de reserva con prefijo `cit:` (NO comando de texto `/reservar` — contradicción plan F2-S11; la operación es por botones/callbacks): FSM flujo='cita' pasos sede/fecha/slot/paciente/motivo/confirmar; `slots_disponibles`; confirmación por botón antes de crear cita (C6.9). Tareas worker `enviar_confirmacion_cita`, `recordatorio_cita_24h`, `recordatorio_cita_2h` (C6.16, `{tipo, manejar}`). Rate limit en puerta pública de reserva sin sesión (C6.15). Registro en COALESCE de `078`.
      - assigned_agent: `telegram-engineer` (apoyo `backend-engineer` para los manejadores worker de recordatorios).
      - required_skills: `[telegram, postgres-business-logic, security, testing]`.
      - dependencies: `["f2-s10-citas-esquema"]`.
      - acceptance_criteria:
        - "existen `bot_cita_callback`/`bot_cita_texto` con guardia de prefijo `cit:` y registro en el COALESCE de `078`"
        - "el flujo usa `estado_guardar/leer/limpiar` (FSM flujo='cita') y `slots_disponibles`"
        - "la creación de la cita exige confirmación por botón (C6.9)"
        - "existen los 3 manejadores worker con `export const tipo` + `manejar`"
        - "la puerta pública de reserva consume `consumir_rate_limit` (C6.15)"

  12. **`f2-s12-citas-web`** / **F2-S12 — Portal Web — Configuración de Disponibilidad**
      - description: `(portal)/admin/disponibilidad/page.tsx`: calendario semanal, franjas, duración de slot, asignar veterinario, activar/desactivar, con Server Actions que llaman funciones SQL (`$1`=actor) y `revalidatePath`. Sin SQL crudo (C6.12), sin password/HTTP externo (C6.17).
      - assigned_agent: `frontend-engineer`.
      - required_skills: `[nextjs-admin, architecture, security, testing]`.
      - dependencies: `["f2-s10-citas-esquema"]`.
      - acceptance_criteria:
        - "existe `(portal)/admin/disponibilidad/page.tsx` protegido por el layout"
        - "las Server Actions usan `$1 = sesion.usuario_id` + `exigirPermiso` (C6.13)"
        - "sin SQL crudo inline nuevo (grep → 0)"
        - "`npm run typecheck`/`build` sin errores"

  **F2 — Carnet Digital**

  13. **`f2-s13-carnet-esquema`** / **F2-S13 — Esquema de Carnet Digital (SQL)**
      - description: crear `db/migrations/150_carnet.sql` aditiva: `carnet_digital`, `carnet_registro`; funciones `generar_carnet`, `registrar_en_carnet`, `carnet_json`, `carnet_por_codigo`, `proximos_vencimientos_carnet`, `bot_carnet_texto`; permisos. Datos clínicos del carnet **no se purgan** (MUST_NOT 2). Privacidad Ley 1581: `carnet_por_codigo` expone solo nombre y teléfono de contacto (nunca datos del dueño). `exigir_permiso` en escrituras, `auditar`, contrato JSONB.
      - assigned_agent: `sql-engineer`.
      - required_skills: `[postgres-business-logic, architecture, security, testing]`.
      - dependencies: `[]`.
      - acceptance_criteria:
        - "existe `db/migrations/150_carnet.sql` aplicable con `ON_ERROR_STOP`"
        - "existen `carnet_digital` y `carnet_registro` (historial derivado, no purgable)"
        - "existen `carnet_por_codigo`, `generar_carnet`, `registrar_en_carnet` con `exigir_permiso` y `auditar`"
        - "`carnet_por_codigo` NO devuelve datos personales del dueño (solo nombre/teléfono de contacto del paciente) — verificado con psql"
        - "cada función con invocación psql (C6.23)"

  14. **`f2-s14-carnet-pdf`** / **F2-S14 — Worker — Generación de PDF del Carnet**
      - description: tarea worker `generar_pdf_carnet.js` (pdf-lib/qrcode, template HTML, QR único, guardado en volumen `backups/carnets/`, actualizar `carnet_digital.url_publica` vía función SQL). **Asignada a backend-engineer** (generación de contenido interna, no adapter externo — decisión Fase 12). No toca dominio: llama funciones SQL `carnet_por_codigo`. Actualizar `worker/Dockerfile`/deps.
      - assigned_agent: `backend-engineer`.
      - required_skills: `[worker, architecture, security, testing]`.
      - dependencies: `["f2-s13-carnet-esquema"]`.
      - acceptance_criteria:
        - "existe `worker/src/tareas/generar_pdf_carnet.js` con `export const tipo` + `manejar`"
        - "el PDF se genera llamando funciones SQL (0 SQL directo sobre tablas de dominio, C6.16)"
        - "`url_publica` se actualiza por función SQL, no con UPDATE directo en el worker"
        - "`npm run check` sin errores; deps nuevas en `package.json` documentadas"
        - "prueba sobre BD demo: encolar tarea → se genera archivo (C6.23)"

  15. **`f2-s15-carnet-bot`** / **F2-S15 — Bot Telegram — Carnet del Dueño**
      - description: flujo "Mi carnet": selección de mascota, genera/actualiza PDF (`f2-s14`), compartir QR; trigger al firmar consulta con vacuna → registra en `carnet_registro` (este trigger es de dominio clínico → `sql-engineer`). Prefijo de módulo carnet con guardia (C6.14) y registro en COALESCE de `078`. Confirmación por botón donde toque (C6.9).
      - assigned_agent: `telegram-engineer` (apoyo `sql-engineer` para el trigger de vacunas).
      - required_skills: `[telegram, postgres-business-logic, security, testing]`.
      - dependencies: `["f2-s13-carnet-esquema", "f2-s14-carnet-pdf"]`.
      - acceptance_criteria:
        - "existe el flujo de bot del carnet con guardia de prefijo y registro en el COALESCE de `078`"
        - "existe el trigger que al firmar consulta con vacuna inserta en `carnet_registro` (dominio 050)"
        - "el PDF se encola con `encolar_tarea` y `clave_unicidad` (no se genera en el webhook, C6.8)"
        - "se prueba el flujo completo con psql + enqueue (C6.23)"

  16. **`f2-s16-carnet-publico`** / **F2-S16 — Página Pública del Carnet (sin auth)**
      - description: `web/src/app/carnet/[codigo]/page.tsx` pública sin autenticación que lee `carnet_por_codigo` (función SQL) y renderiza el QR + datos permitidos (Ley 1581: solo nombre y teléfono de contacto, nunca datos del dueño). Route Server Component con `force-dynamic` (C6.13) y rate limit/búsqueda acotada en puerta pública (C6.15). Es la única página pública con datos de paciente (junto a `pantalla/[sede]`).
      - assigned_agent: `frontend-engineer`.
      - required_skills: `[nextjs-admin, architecture, security, testing]`.
      - dependencies: `["f2-s13-carnet-esquema"]`.
      - acceptance_criteria:
        - "existe `web/src/app/carnet/[codigo]/page.tsx` accesible sin sesión"
        - "la página llama `carnet_por_codigo` (función SQL), 0 SQL crudo (C6.12)"
        - "la respuesta NO incluye datos del dueño (verificado por prueba HTTP, habeas data)"
        - "la puerta pública aplica límite/abuso (C6.15) acorde al patrón existente"
        - "`npm run typecheck`/`build` sin errores"

  **F2 — Canal Cliente / Marketing / Reportes**

  17. **`f2-s17-canal-cliente`** / **F2-S17 — Canal del Cliente — Menú del Dueño en Telegram**
      - description: detección de modo dueño en el router (4ª rama: `chat_id ∈ dueno.telegram_chat_id ∧ ∉ usuario.telegram_user_id`) sin romper las 3 ramas existentes; menú "Mis mascotas/citas/carnet/facturas" y flujos `dueno:mascotas`, `dueno:citas`, `dueno:facturas`, `dueno:reservar`, `dueno:carnet`. Prefijo `dueno:` con guardia y registro en COALESCE de `078` (C6.14). Confirmaciones por botón (C6.9); habeas data en notificaciones al dueño (MUST_NOT 5).
      - assigned_agent: `telegram-engineer`.
      - required_skills: `[telegram, postgres-business-logic, security, testing]`.
      - dependencies: `["f2-s11-citas-bot", "f2-s15-carnet-bot", "f1-s6-dian-bot"]`.
      - acceptance_criteria:
        - "existe la rama de modo dueño en `bot_manejar_update` sin alterar público/texto/callback (grep del router)"
        - "existen los 5 flujos `dueno:*` con guardia de prefijo y registro en el COALESCE de `078`"
        - "cada flujo reúsa funciones SQL existentes (0 lógica duplicada en el bot, C6.9)"
        - "las notificaciones al dueño cumplen consentimiento (MUST_NOT 5)"

  18. **`f2-s18-marketing`** / **F2-S18 — Marketing Automatizado (Jobs)**
      - description: jobs n8n `cumpleanos_mascota`, `campana_vacunacion`, `reactivacion_cliente` (patrón Fase 4 p.22: scheduler→SQL/cola, sin estado en n8n) + `(portal)/admin/marketing/page.tsx`. ⚠️ el plan usa `fecha_nacimiento` pero el esquema real usa `fecha_nacimiento_aprox` (050) — la consulta debe usar la columna real. Encolar con `encolar_tarea` + `clave_unicidad` por día/mascota (C6.8, C6.16).
      - assigned_agent: `backend-engineer` (jobs) + `frontend-engineer` (página admin).
      - required_skills: `[worker, architecture, security, testing]` (backend); `[nextjs-admin, architecture, security, testing]` (frontend).
      - dependencies: `["f2-s11-citas-bot", "f2-s13-carnet-esquema", "f2-s17-canal-cliente"]`.
      - acceptance_criteria:
        - "existen los 3 jobs (n8n `scheduleTrigger`→funciones SQL/`encolar_tarea`) sin lógica en n8n (C6.8/C6.16)"
        - "las consultas de cumpleaños usan `fecha_nacimiento_aprox` (columna real, no `fecha_nacimiento`)"
        - "cada campaña encola con `clave_unicidad` diaria/idempotente"
        - "existe `(portal)/admin/marketing/page.tsx` con Server Actions `$1`=actor"
        - "`npm run check` (worker) y `npm run typecheck`/`build` (web) sin errores"

  19. **`f2-s19-reportes`** / **F2-S19 — Reportes F2 + Pulido**
      - description: agregar claves `citas`, `carnets`, `canal_cliente` a `web/src/lib/reportes.ts` con funciones `reporte_*` SQL (patrón 080, `p_desde/p_hasta` default mes en curso) y CSV por `api/reportes/[clave]` (sesión+permiso). Pulido final de F2. Rate limiting en endpoints públicos asociados (C6.15), fallback del bot intacto.
      - assigned_agent: `frontend-engineer` (apoyo `sql-engineer` para `reporte_citas`/`reporte_carnets`/`reporte_canal_cliente`).
      - required_skills: `[nextjs-admin, architecture, security, testing]`.
      - dependencies: `["f2-s10-citas-esquema", "f2-s13-carnet-esquema", "f2-s17-canal-cliente"]`.
      - acceptance_criteria:
        - "existen las claves `citas`, `carnets`, `canal_cliente` en `reportes.ts` y sus `reporte_*` en SQL"
        - "cada reporte acepta `p_desde/p_hasta` opcionales (patrón 080)"
        - "CSV por `api/reportes/[clave]` con sesión+permiso"
        - "`npm run typecheck`/`build` sin errores; cada `reporte_*` con invocación psql (C6.23)"

  **F2 — WhatsApp (documentación)**

  20. **`f2-s20-whatsapp-doc`** / **F2-S20 — WhatsApp (solo documentación, no implementar)**
      - description: el plan ordena **no implementar aún** ("Solo documentar la extensión en el README", `plan_ejecucion_chasquipet.md:574-585`). Tarea de documentación: agregar sección en README/docs describiendo cómo se extendería WhatsApp como canal externo (patcher conforme ADR-12: webhook similar a Telegram, prefijo de canal `whatsapp`, integración aislada), sin escribir código.
      - assigned_agent: `integration-engineer` (documentación del adapter futuro; no implementa).
      - required_skills: `[external-integrations, architecture]`.
      - dependencies: `[]`.
      - acceptance_criteria:
        - "existe una sección en README/doc describiendo la extensión WhatsApp (canal externo, secretos por env, idempotencia)"
        - "0 archivos de implementación nuevos (0 código WhatsApp en `worker/`, `n8n/`, `web/`, `db/`)"
        - "se mantiene la separación contexto vs. trabajo: WhatsApp queda como descriptor, no como funcionalidad existente"

- **Decisión pendiente para Fase 14** (resolución de agentes): la asignación de F1-S8 a frontend-engineer supone que frontend-engineer queda habilitado para editar el route handler del webhook aunque la lógica Factus vive en SQL; si se prefiere que integration-engineer lo mantenga, su `forbidden_tools` (Fase 8) debe ajustarse para permitir `web/src/app/api/factus/**`. UNKNOWN hasta Fase 14.
- **Incertidumbres**:
  - El mapeo de agentes/skills de esta fase asume el esquema de registro de la relación agent↔skill aún sin definir (Fase 10 → UNKNOWN). Los campos JSONB `required_skills`/`dependencies` siguen la tabla `tasks` de StrictContext (init.sql:130-131), pero la resolución de IDs de tareas, agentes y skills reales ocurre en Fase 14 (poblamiento).
  - F1-S8: la firma HMAC y el handler del webhook son código nuevo en `web/**`; la decisión final de propietario (frontend vs integration vs backend) queda abierta para Fase 14 (mantiene la UNKNOWN de Fase 12 con recomendación).
  - F2-S14: la generación de PDF introduce deps nuevas (pdf-lib/qrcode) sin precedente en el worker (sin uso de librerías gráficas hoy); la configuración de volumen debe decidirse (patrón sin precedente, Fase 12 → UNKNOWN baja).
  - Los criterios de aceptación dependen de BD demo levantada y del pipeline de verificación C6.23 (sin tests automatizados); el peso de "invocación psql" como aceptación es el estándar real (Fase 1 §TESTING).
  - F2-S18: la columna real es `fecha_nacimiento_aprox` (050); el uso correcto se resuelve al implementar, no es blocker (queda como nota en la tarea).

### Fase 14 — Poblar StrictContext

- **Fecha / sesión**: 2026-08-09 / sesión 15
- **Agente**: context-architect
- **Orden** (1. Project/context base → 2. ADRs → 3. Skills → 4. Skill sections → 5. Rules → 6. Constraints → 7. Agents → 8. Agent-Skill → 9. Commands → 10. Tasks): ejecutado en orden mediante scripts Python que escriben directamente en `.strictcontext.db` (el runtime solo expone lectura).
- **Poblado en `~/.strictcontext` → `.strictcontext.db`** (conteos verificados post-inserción):
  1. **Project/context base**: ya existente (9 agents de análisis: project/database/backend/telegram/frontend/integration/security-analyst, context-architect, context-reviewer); se conservan activos.
  2. **ADRs (Fase 7)**: 12 registradas (`adr-01…adr-12`) en `architecture_decisions`.
  3. **Skills (Fase 9)**: 8 registradas (architecture, postgres-business-logic, telegram, worker, nextjs-admin, security, testing, external-integrations).
  4. **Skill sections**: 64 (8 secciones × 8 skills: overview, patterns, anti_patterns, examples, migrations, testing, security, references) con evidencia path:line de cada skill.
  5. **Rules (Fase 5)**: 41 = 15 MUST + 12 MUST_NOT + 9 SHOULD + 5 PREFERENCE; las 5 PREFERENCE se registran como `SHOULD` con prioridad 90 y nota en `reason` (el CHECK de `rules.rule_type` no soporta PREFERENCE — decisión Fase 14). Scopes `global`.
  6. **Constraints (Fase 6)**: 23 (`C6.1…C6.23`) con `constraint_type`/`severity`/`check_pattern`/`remediation` (9 BLOCKER, 9 ERROR, 5 WARNING).
  7. **Agents (Fase 8)**: 7 de ingeniería (planner, sql-engineer, telegram-engineer, backend-engineer, frontend-engineer, integration-engineer, reviewer) con `role/goal/system_prompt_template` (responsabilities + constraints), `allowed_tools`/`forbidden_tools` (nombres conceptuales del runtime), `max_steps`, `requires_human_review` y `priority` según mapeo de Fase 8.
  8. **Agent–Skill**: se creó la tabla de relación `agent_skills(agent_id, skill_id)` (PK compuesta, FK a `agents`/`skills`) y se registraron 26 filas según la matriz de Fase 10 (seguridad y testing transversales; sql-engineer→postgres-business-logic; frontend-engineer→nextjs-admin; integration-engineer→external-integrations+worker, etc.).
  9. **Commands (Fase 11)**: 8 (inspect, plan, implement, test, verify, review, session, session-report). Mapeo de los campos del plan §13 al esquema real: `prompt_template`+`required_context`+`required_skills` se embeben como JSONB dentro de `steps`; el externalizado `required_agent` paramétrico se mantiene en `description`/`steps` (la columna `required_agent` queda NULL salvo plan/review donde es fijo); `expected_output` = `validation_requirements`.
  10. **Tasks (Fase 13)**: 20 con status `pending`, `assigned_agent` entre los 7 de trabajo, `required_skills`, `dependencies` (todas apuntan a tasks existentes, verificado) y `acceptance_criteria` verificables por C6.23.
- **Verificación de consistencia post-inserción** (SQL): 16 agents, 8 skills, 64 skill_sections, 41 rules, 23 constraints, 12 ADRs, 8 commands, 20 tasks, 26 agent_skills; 0 skills sin secciones; 0 tasks con dependencias inválidas; conteos de rules por tipo (MUST 15, MUST_NOT 12, SHOULD 14=9+5) y constraints por severidad (9/9/5) coinciden con Fases 5 y 6.
- **Incertidumbres resueltas en Fase 14**:
  - **PREFERENCE fuera del esquema**: `rules.rule_type` solo admite MUST/SHOULD/SHOULD_NOT (y la categoría `style` sí existe); se resuelve registrando PREFERENCE como SHOULD prioridad 90 con la clasificación original documentada en `reason`. Alternativa futura: ampliar el CHECK del esquema.
  - **Mapeo de commands**: `prompt_template`/`required_context`/`required_skills`/`validation_requirements` (plan §13) no existen como columnas; se embeben en `steps` (JSONB) y `expected_output`.
  - **`required_agent` paramétrico**: la columna es de valor único; `inspect`/`implement`/`test`/`session` quedan con NULL y el agente en `description`/`steps` (parametrizado por tarea/dominio), como planeaba Fase 11.
  - **Destino de los 9 agents de análisis**: se conservan activos junto a los 7 de trabajo (documentan la misión; no interfieren con la matriz agent_skills, que solo cubre los 7).
  - **`allowed_tools`/`forbidden_tools`**: nombres conceptuales (read/edit/write/bash/psql/MCP) en JSONB; la lista real del runtime (OpenCode) se afina en Fase 16 (prueba de recuperación).
- **Incertidumbres conservadas para Fase 15/16**:
  - La validación de cobertura/consistencia/orfandad del contenido poblado es la **Fase 15** (a ejecutar).
  - La prueba de recuperación real (`get_agent_context`, hydrate de skill_sections) es la **Fase 16**.
  - Los `allowed_tools`/`forbidden_tools` conceptuales deben validarse contra las herramientas reales del runtime (Fase 16).

### Fase 15 — Validación del contexto generado

- **Fecha / sesión**: 2026-08-10 / sesión 16
- **Agente**: context-reviewer
- **Validación ejecutada** sobre `.strictcontext.db` (queries SQL directas + `get_agent_context` por agente de trabajo):
  - **Cobertura**: 16 agents, 8 skills + 64 skill_sections (8/8 completas), 41 rules, 23 constraints, 12 ADRs, 8 commands, 20 tasks, 26 agent_skills. Todos los componentes principales tienen contexto (architecture, postgres-business-logic, telegram, worker, nextjs-admin, security, testing, external-integrations). Los 7 agentes de trabajo tienen entre 4 y 5 skills cada uno; n8n/Docker/Caddy/cloudflared quedan referenciados en external-integrations/architecture (n8n: 11 secciones). Los 9 agentes de análisis + context-architect + context-reviewer no tienen skills (decisión Fase 10/14: la matriz `agent_skills` cubre solo los 7 de trabajo) — sin violación.
  - **Consistencia**: 0 reglas contradictorias (ningún MUST vs MUST_NOT con misma condition/action); 0 scopes válidos. Todos los scopes son `global` y apuntan a entidades existentes; unauthorized scopes agent:/skill: → 0. Categorías y rule_type dentro de dominios permitidos (MUST 15 / MUST_NOT 12 / SHOULD 14=9+5 engine). 0 constraints sin scope. Constraint C6.10 (ERROR, search_path) coherente con rule 28 (SHOULD, misma evidencia 090:68,74). Prioridades coherentes (MUST/MUST_NOT 10–20, SHOULD 60–90, estilo 90).
  - **Duplicación**: 0 reglas con misma condition; 0 duplicados de action normalizado; similitud semántica (ratio dice difflib) sin pares ≥0.8. Constraints C6.1…C6.23 únicos, sin solapamiento de concepto.
  - **Orfandad**: 0 skills sin agente; 0 agentes de trabajo sin skills; 0 tasks sin assigned_agent; 0 agent_skills con referencias inválidas; 0 skill_sections sin skill; 0 commands con required_agent inexistente (todos NULL salvo plan/review fijo, ver incertidumbres); 0 dependencias de tasks inválidas; required_skills/related_skills apuntan solo a skills existentes. **Conteos verificados** (16/8/64/41/23/12/8/20/26) coinciden exactamente con Fase 14.
  - **Estado**: 20 tasks en status `pending` (ninguna funcionalidad planificada registrada como existente); skills de external-integrations señalan explícitamente "Factus/DIAN: NO implementado (plan futuro)"; 0 ADRs/rules que describan presupuestos/DIAN/Factus/citas/carnet/WhatsApp como estado actual ("cita" matchea solo como subcadena de "explicita" en la rule 5 — falso positivo); ADRs todas `accepted` sin superseded; 12/12 con rationale >80 caracteres.
  - **Evidencia**: las 41 rules citan evidencia path:line; 23/23 constraints tienen `check_pattern` y `remediation` (check_sql NULL en todas — el runtime valida por regex sobre check_pattern; pendiente, ver incertidumbres); tasks con acceptance_criteria verificables por C6.23 (3–7 criterios por task, muestreo f1-s1 con 7 criterios todos accionables).
  - **Prioridad**: 9 BLOCKER + 9 ERROR + 5 WARNING en constraints y MUST/MUST_NOT con prioridad ≤20; escala 10/20/60/70/90 distribuida y coincidente con Fases 5/6. Sin reglas con priority default 100 ni `enforced=0`.
  - **Recuperación SANITY (adelantando Fase 16)**: `get_agent_context(sql-engineer)` y `get_agent_context(frontend-engineer)` devuelven agent + reglas (MUST/MUST_NOT/SHOULD completas) + 23 constraints + instruction; el runtime hidrata correctamente scope `global` para ambos dominios.
- **Incertidumbres**:
  - `commands.required_agent` está NULL en 8/8 aunque Fase 11/14 declaró que `plan`/`review` quedarían con agente fijo (revisar si el embebido en `steps`/`description` basta; no es violación de integridad: 0 filas con agente inexistente).
  - `check_sql` NULL en las 23 constraints: el runtime (server.py) solo usa `check_pattern` por regex; si en el futuro se quiere ejecución SQL autónoma, hay que poblar `check_sql` (decisión de Fase 17).
  - Los 9 agentes de análisis permanecen `active=1` sin skills y sin `agent_skills`: no interfieren con la matriz de trabajo, pero conviene decidir su `active` de cara al informe final (Fase 18).
  - `allowed_tools`/`forbidden_tools` son nombres conceptuales (edit_db_migrations, psql_app, sql_crudo_inline_nuevo…): pendiente mapeo a herramientas reales del runtime en Fase 16.

### Fase 16 — Prueba de recuperación

- **Fecha / sesión**: 2026-08-10 / sesión 17
- **Agente**: context-reviewer
- **Prueba ejecutada** sobre el MCP real (`strictcontext_get_agent_context`, `get_skill`, `get_task`, `get_command_steps`) — no solo consultas SQL:
  - **`get_agent_context(agent)` por agente de trabajo** (7/7 devuelven `{agent, rules[41], constraints[23], instruction}` sin error ni campos faltantes):
    - `planner` → agent (goal/system_prompt/allowed_tools/max_steps) + 41 rules + 23 constraints + instruction. **OK**
    - `sql-engineer` → **OK** (mismo conjunto; sanity ya adelantado en Fase 15 se confirma íntegro)
    - `telegram-engineer` → **OK**
    - `backend-engineer` → **OK**
    - `frontend-engineer` → **OK**
    - `integration-engineer` → **OK**
    - `reviewer` → **OK** (priority 50; sus rules son las globales, sin scope agent:* específico — coherente, el reviewer valida sobre lo global)
  - **Hidratación secundaria** (el plan §18 pide skills/ADRs/commands además de rules/constraints):
    - `get_skill(postgres-business-logic, [overview, patterns, anti_patterns, migrations, testing])` → 5 secciones con contenido. **OK** — el runtime expone solo `overview` por defecto, las demás se piden explícitas.
    - `get_task(f1-s1-presupuestos-esquema)` → task con description + assigned_agent + required_skills + 7 acceptance_criteria verificables. **OK**
    - `get_command_steps(implement)` → steps + preconditions + expected_output. **OK**
  - **Conclusión de recuperación**: el contexto normativo (rules/constraints/instruction) se recupera completo e igual para todos los agentes de trabajo; skills/tareas/comandos se hidratan bajo demanda con las tools dedicadas. Un agente puede iniciar una tarea sin los markdown de apoyo.
- **Hallazgos (bugs reales del runtime)**: 
  - **BUG 1 — `validate_action()` se rompe**: `constraints.id=13` (C6.13) tiene `check_pattern = "export const dynamic = 'force-static'|revalidate en web/src/app/**/route.ts (excepto /health, /salir)"`; el `**` es regex inválida (`re.error: multiple repeat at position 65`). Al iterar con `re.search` sobre el patrón, ANY llamada a `validate_action()` lanza excepción antes de evaluar reglas/constraints → la herramienta está inoperante para todos los agentes. **BLOQUEA Fase 17** (sus 4 casos dependen de validate_action). Corrección necesaria previa: escapar/quitar el `**` del check_pattern de C6.13 (decisión de Fase 17).
  - **Gap de cobertura del plan §18**: `get_agent_context` devuelve agent+rules+constraints+instruction pero **NO** skills/ADRs/commands; el plan promete el bloque completo "agent + relevant skills + relevant rules + relevant constraints + relevant ADRs + relevant commands". La recuperación de skills/commands requiere llamadas manuales a `get_skill`/`get_command_steps`, y los ADRs (`architecture_decisions`, 12 registros) no tienen tool dedicada en el runtime (ni por agente ni por id) → solo consultables por SQL directo. No es falla de contenido sino de superficie del runtime.
  - `commands.required_agent` NULL en 8/8 (confirmado en BD): no hay trazabilidad agente→comando automática; `get_command_steps` requiere conocer el id del comando (depende de la tarea), coherente con Fase 11.
- **Incertidumbres**:
  - La decisión de corregir el `check_pattern` de C6.13 (escapar `**`) queda para Fase 17 (es la condición previa para ejecutar los casos A–D); se documenta aquí como bug para no perderlo.
  - El runtime no auto-adjunta `agent_skills` (26 filas) al contexto del agente; la selección de skills la hace el agente/tarea (requiere que el runtime aprenda a resolver `agent_skills` o que cada tarea declare `required_skills`, que ya existe en tasks). UNKNOWN si se amplía server.py en esta misión o se deja como está.
  - `allowed_tools`/`forbidden_tools` siguen siendo nombres conceptuales (edit_db_migrations, psql_app, auto_escribir_sin_confirmar…); no se mapearon a las tools reales del runtime en esta fase (misma incertidumbre arrastrada de Fase 14/15).

### Fase 17 — Pruebas de validate_action()

- **Fecha / sesión**: 2026-08-10 / sesión 18
- **Agente**: context-reviewer
- **Precondición resuelta**: el BLOQUEO CRÍTICO de Fase 16 (C6.13.check_pattern con `**`) está corregido — el patrón actual usa `web/src/app/.*/route.ts` y los 23 `check_pattern` compilan como regex (`re.compile` OK en 23/23). Las 4 pruebas se ejecutan con el MCP real (`strictcontext_validate_action`), sin excepción previa.
- **Casos ejecutados** (acción → detalle → resultado real):

  - **Caso A — modificar una tabla protegida** (esperado INVALID):
    - `action='borrar movimientos de inventario'`, `details='DELETE FROM movimiento_inventario WHERE lote_id = 12'` → **INVALID** vía regla MUST_NOT `no_editar_append` (rule 16, priority 10). ✓ semánticamente correcto.
    - Hallazgo: el mismo `details` con `action='>editar fila de una tabla append-only'` (UPDATE pago) dispara **C6.16 por falso positivo** (ver hallazgo 3), no C6.1/C6.2.
    - Hallazgo: un `details='DELETE FROM evento_auditoria …'` directo devuelve **VALID** (falso negativo): las regex BLOCKER C6.1 (`SELECT 1 FROM pg_proc p WHERE … -- triggers …`, texto de check_sql mal ubicado en check_pattern) y C6.2 (`DELETE/JOB sobre tablas append-only`, lenguaje natural) **no detectan un DELETE literal**. La protección real en este caso vino de la regla textual, no de la constraint.

  - **Caso B — almacenar secretos en código** (esperado INVALID + BLOCKER):
    - `details` con literal `token en literal del repo` → **INVALID + BLOCKER** vía C6.7. ✓ (coincide solo por la segunda alternativa del patrón).
    - Hallazgo: un literal realista (`TELEGRAM_BOT_TOKEN = '123456789:AAFi…'` o `DEEPSEEK_API_KEY = 'sk-…'`) **NO dispara** C6.7: la 1.ª alternativa `(Telegram|DEEPSEEK|SESSION_SECRET)[a-zA-Z0-9_-]{20,}` exige ≥20 caracteres `[a-zA-Z0-9_-]` inmediatamente tras la clave y se corta en ` = '…'` / `:` / `-` → falso negativo frente a tokens reales de Telegram (ver hallazgo 4).

  - **Caso C — lógica de negocio fuera del componente permitido** (esperado INVALID):
    - `action='implementar logica de negocio en el worker'`, `details` con `INSERT INTO tarea_async (tipo, payload)…` en `worker/src/tareas/…` → **INVALID** vía C6.16 (ERROR). ✓

  - **Caso D — operación permitida** (esperado VALID):
    - `action='crear nueva funcion SQL de escritura con permisos y auditoria'`, `details` de una función canónica (`p_actor_id`, `exigir_permiso`, `auditar`, `jsonb {ok,…}`, `numeric(12,2)`) → **VALID**. ✓
    - `action='agregar route handler conforme cabeceras fijas'` (runtime nodejs + force-dynamic + no-store, `$1`=actor) → **VALID**. ✓
    - `action='agregar callback de bot con prefijo de modulo'` (`inv:…`, guardia RETURN NULL) → **VALID**. ✓
    - Contraste: `details='export const dynamic = "force-static"'` en `route.ts` → **INVALID** vía C6.13 (ERROR), confirmando que el fix de Fase 16 funciona: ahora SÍ detecta la violación que antes abortaba el runtime.

- **Vinculación con las rules/constraints originales**: los 4 casos mapean al contrato esperado: A→C6.1/C6.2 (append-only) + rule 16; B→C6.7; C→C6.16; D→sin violación. La semántica declarada en el plan §19 se cumple para todos al dirigir la frase, con las precisiones (hallazgos 3 y 4) sobre la sensibilidad real de los patrones.

- **Hallazgos (bugs del contenido de `check_pattern`, reportados para Fase 18, NO corregidos por mandato de la misión)**:
  1. **C6.1 y C6.2 no son regex detectantes**: C6.1 tiene un literal SQL (`SELECT 1 FROM pg_proc p WHERE … -- triggers …`) — texto de `check_sql` ubicado en `check_pattern`; C6.2 es lenguaje natural (`DELETE/JOB sobre tablas append-only`). Ninguno casa con un `DELETE/UPDATE` real de tablas append-only → los BLOCKER de append-only no se activan por detalle, solo las reglas textuales. Requiere rediseñar `check_pattern` (regex) y/o poblar `check_sql`.
  2. **C6.16 falso positivo por alternancia reglada**: patrón `INSERT|UPDATE|DELETE directo sobre tarea_async en worker/src` — con `|` sin agrupar, casa cualquier `INSERT`/`UPDATE`/`DELETE` en el detalle, incluso si no es `worker/src` (p.ej. `UPDATE pago SET valor=1` desde sql-engineer o `INSERT INTO turno`). Confunde la validación entre dominios.
  3. **C6.7 falso negativo ante tokens reales**: `(Telegram|DEEPSEEK|SESSION_SECRET)[a-zA-Z0-9_-]{20,}` exige ≥20 alnum/`_`/`-` pegados a la clave; un token de Telegram (`123456789:AAA…`, con `:`) o un `sk-…` con `-`/` =` no matchea. Solo casa por la alternativa de frase ("token en literal del repo"). El patrón no detecta la filtración real que el constraint declara prohibir.
  4. **C6.10 tampoco casa texto real**: `CREATE FUNCTION SECURITY DEFINER sin "SET search_path"` como regex no detecta una firma SECURITY DEFINER en un detalle (necesita la frase literal o un parser de SQL).
  5. **Mecanismo del runtime**: `validate_action` casa por `re.search(check_pattern, details)` de UNA frase de detalle libre (nunca contra el archivo/código ni contra `check_sql`, NULL en 23/23) y por substring de `action` en el texto de reglas MUST_NOT → la cobertura real depende de cómo el agente redacte `details`, no de evidencia objetiva. Los patrones correctos (C6.12 `.query(SELECT…`, C6.13, C6.16 dirigido, C6.3) SÍ detectan.

- **Incertidumbres**:
  - La corrección del contenido de `check_pattern` (C6.1/C6.2/C6.7/C6.10) o el poblamiento de `check_sql` para ejecución autónoma quedan como **decisión para Fase 18 / post-misión**: el plan §1.2 Regla 7 (cambios mínimos) impide "refactorizar" el contexto durante la misión; se reporta y se recomienda resolver antes de depender de `validate_action` como puerta dura.
  - El runtime solo expone `validate_action` con firma `(agent_id, action, details)`; no hay herramienta que corra los `check_sql` ni apte evidencia de repo → la automatización "real" de Fase 6 (check_sql) sigue sin target de ejecución (arrastrado desde Fase 6).
  - La semántica del Caso A depende de `action` (frase) más que de `details`: si el agente redacta el `action` con la frase exacta de la regla, la valida; si redacta el detalle SQL, no. UNKNOWN hasta definir el contrato de uso de la herramienta por los agentes de trabajo (Fase 8 skill/reviewer).

### Fase 18 — Informe final

- **Fecha / sesión**: 2026-08-10 / sesión 19
- **Agente**: context-reviewer (verificación independiente; apoyo de project-analyst)
- **Verificación de cierre** (ejecutada en esta sesión, no reutilizada de fases previas):
  - Conteos de la BD `.strictcontext.db` (SQL directo): 16 agents, 8 skills, 64 skill_sections, 41 rules (15 MUST / 12 MUST_NOT / 14 SHOULD de los cuales 9 SHOULD+5 PREFERENCE→SHOULD prio 90), 23 constraints (9 BLOCKER / 9 ERROR / 5 WARNING; 10 required_pattern, 9 db_constraint, 3 forbidden_pattern, 1 required_test), 12 ADRs, 8 commands, 20 tasks (todos `pending`), 26 agent_skills (7 agentes de trabajo, 3–4 skills c/u). Coinciden con Fases 14/15.
  - `get_agent_context(sql-engineer)` rehidrata agente + 41 rules + 23 constraints + instruction, todo con evidencia path:line. OK.
  - `validate_action` (MCP real, requisito §19): Caso A (DELETE movimiento_inventario) → INVALID vía rule 16; Caso B frase literal → INVALID+BLOCKER vía C6.7; Caso B token realista (`DEEPSEEK_API_KEY='sk-ant-…'`) → **valid:true (falso negativo, confirmado en vivo)** = hallazgo de Fase 17 reproducido; Caso C (INSERT tarea_async en worker) → INVALID vía C6.16; Caso D (función canónica) → VALID. Casos A/C/D correctos; B depende de la redacción del detalle (limitación conocida del runtime).

#### Contexto descubierto

- **Agentes (16 en BD)**: 9 de análisis de la misión (project/database/backend/telegram/frontend/integration/security-analyst + context-architect + context-reviewer) + 7 de trabajo del repo (planner, sql-engineer, telegram-engineer, backend-engineer, frontend-engineer, integration-engineer, reviewer). Solo los 7 de trabajo tienen `agent_skills` (26 filas, matriz Fase 10); los 9 de análisis se conservan activos (documentan la misión).
- **Skills (8)** con 64 secciones (8×8: overview, patterns, anti_patterns, examples, migrations, testing, security, references): architecture, postgres-business-logic, telegram, worker, nextjs-admin, security, testing, external-integrations.
- **Reglas (41)**: 15 MUST, 12 MUST_NOT, 14 SHOULD (9 fuertes + 5 PREFERENCE registradas como SHOULD prio 90 por limitación del CHECK del esquema). Todas con evidencia `path:line` y scope global.
- **Constraints (23, C6.1–C6.23)**: 9 BLOCKER (append-only real, no purgar auditoría/inventario, numeric no-float, advisory lock, exigir_permiso en toda escritura, rol chasquipet_app, secretos fuera de git, webhook<1s→cola, confirmación por botón), 9 ERROR (search_path, nuevas inmutables→090, SQL crudo web, cabeceras route handlers, prefijo callback, rate limit puertas públicas, contrato worker, sin password/HTTP externo, defensa real en inmutables), 5 WARNING (GRANT amplio, imágenes fijas, N8N env access, auditoría escrituras, verificación mínima C6.23). `check_sql` NULL en 23/23 (el runtime valida por `check_pattern`).
- **ADRs (12)**: adr-01…adr-12 (postgres-centric, lógica en SQL, n8n transporte, cola+worker, router Telegram, permisos como datos, auditoría, idempotencia, append-only, manejo temporal, portal delgado, integraciones aisladas). 3 descartadas sin rationale.
- **Commands (8)**: inspect, plan, implement, test, verify, review, session, session-report. `required_agent` NULL en 8/8 (paramétrico embebido en steps; solo plan/review fijos en spec, no en columna).
- **Tasks (20)**: F1-S1…F2-S20, todas `pending`, asignadas a los 7 agentes de trabajo, dependencias válidas, `acceptance_criteria` verificables por C6.23.

#### Estado del proyecto

- **Existentes (EXISTING)**: MVP completo — esquema Postgres (41 tablas, 4 vistas, 35 triggers, 68 índices, 282 funciones), 7 dominios operativos (turnos, inventario, clínico, cobro, compras, portal, jobs/demo), pipeline Telegram end-to-end (n8n webhook → router SQL → acciones JSONB → Bot API/worker), portal web con sesión-Telegram, SSE+fallback, 12 reportes+traza, worker con 11 manejadores + IA DeepSeek (chasqui_responder), infraestructura (compose 8+2 servicios, Caddy, cloudflared, backup 14 días, 7 scripts).
- **Parciales (PARTIALLY_EXISTS)**: citas/disponibilidad (tablas 050:126-170 sin lógica ni UI), kiosco tablet (canal reservado en 030:64 sin implementación).
- **Futuras (DOES_NOT_EXIST / PENDING)**: 20 tareas — presupuestos (F1-S1..S3), DIAN/Factus (F1-S4..S8), reportes/pulido (F1-S9, F2-S19), citas (F2-S10..S12), carnet digital (F2-S13..S16), canal cliente/modo dueño (F2-S17), marketing (F2-S18), WhatsApp doc (F2-S20). Excluidos como NO-tarea: features §3 sin detalle, kiosco tablet, medicamentos de control especial.
- **Trabajo sin commitear** (relevante para el estado del repo): `chasqui_responder.js`, `077_portal_enlace.sql`, `078_chasqui_ia.sql` untracked; modificados `.env.example`, `README.md`, `docker-compose.yml`, `scripts/configurar-bot.sh`, `web/src/app/entrar/*`, `worker/package*`. `master` (8c8a989) por detrás del disco.

#### Incertidumbres

Consolidadas (detalle completo en el Registro acumulado): existencia real del modelo `deepseek-v4-pro` en el provider; propósito de `db/seeds/` (vacío); IA desplegada en producción (archivos untracked → puede faltar en el contenedor); `TELEGRAM_BOT_USERNAME`/`SUPERADMIN_TELEGRAM_USER_ID` inyectadas al worker sin consumidor; `N8N_INTERNAL_URL` sin consumidor en web; `editarMensaje` sin callsites activos; comandos `/turno`/`/turnos` inexistentes (operación por botones); tope de "3 intentos" del código 6 dígitos ausente en SQL; semántica de `turnos_por_avisar`/`posicion`; `v_stock_medicamento`/`consumir_rate_limit` sin releer íntegra; `process.exit(0)`/`setTypeParser(20,Number)` del worker; frontera sql↔telegram (criterio `bot_` resuelto, residual bajo); posible fusión integration↔backend; destino active de los 9 agentes de análisis (±decidido: se conservan); mapeo de allowed/forbidden_tools al runtime real (pendiente); esquema commands vs plan §13 (resuelto en Fase 14); webhook Factus propietario (asignado a frontend-engineer, residual bajo); PDF carnet sin precedente en worker; features §3 sin plan; kiosco tablet; medicamentos de control especial (decisión cliente); `required_agent` NULL 8/8 como trazabilidad agente→comando; `check_sql` sin target de ejecución.

#### Contradicciones (documentación vs código)

- Fase 0 del propio avance: "27 migraciones"→24 reales; "13 manejadores"→11 reales; "0 vistas"→4 reales (todas corregidas en fases posteriores).
- `worker/README.md`: 10 manejadores (falta chasqui_responder); referencia `worker/sql/010_aviso_turno.sql` inexistente.
- `web/README.md` "solo llama funciones SQL" vs 3 spots de SQL crudo inline (clinico.ts:154, pantalla.ts:44, admin/config/page.tsx:42).
- "Nueve reportes de §10" vs 12 claves reales (`reportes.ts:38-259`).
- Botón "Iniciar sesión web" del menú (chasquipet.md:394) inexistente; acceso real por deep link `web-<id>` / `por:enlace`.
- "3 intentos máximo" (chasquipet.md:400) sin tope en SQL.
- "Ruta feliz de 3 toques" del cobro vs 4 toques reales (066).
- `SESSION_SECRET` documentada/inyectada pero nunca leída (cookies sin firmar).
- **Plan futuro vs convenciones reales** (6, para no heredar errores): Anexo C `P0001`+`hint=` vs ERRCODE semánticos; F1-S2 editar router/020 vs stubs+COALESCE en 078; F1-S5 SQL directo en worker vs funciones SQL; F1-S3/F1-S7 rutas fuera de `(portal)`; F2-S11 `/reservar` por texto vs botones/callbacks; F2-S18 `fecha_nacimiento` vs `fecha_nacimiento_aprox` real.

#### Problemas detectados (reportados, NO corregidos)

1. **Runtime StrictContext**: `validate_action()` bloqueada por C6.13 `**` — corregido en sesión 18 (saneamiento de `.strictcontext.db`, no del repo). Queda la limitación estructural: casa `re.search(check_pattern, details)` sobre UNA frase libre, nunca contra código/archivo ni `check_sql` (NULL 23/23).
2. **Calidad de `check_pattern`** (verificado vivo en esta sesión): C6.1/C6.2 no detectan DELETE literal de tablas append-only (falso negativo, solo responde la rule 16 textual); C6.16 falso positivo por alternancia `INSERT|UPDATE|DELETE` sin agrupar; C6.7 falso negativo ante tokens reales Telegram/`sk-…` (confirmado: `DEEPSEEK_API_KEY='sk-ant-…'` → valid:true); C6.10 no detecta SECURITY DEFINER real.
3. **Seguridad**: SECURITY DEFINER sin `SET search_path` (`auditar` 090:68, `mantenimiento_diario` 090:74); `auditar` no valida texto ni puebla `evento_auditoria.ip`; `GRANT EXECUTE ON ALL FUNCTIONS` (090:35); `900_superadmin.sh`/`000_n8n_db.sh` interpolan `'${VAR}'` sin escapar; `registrar-publico.sh:79-82` escribe como dueño; `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` (compose:112).
4. **Robustez**: DELETE de `consulta`/`consulta_adenda` sin trigger de bloqueo (defensa solo FK); `WORKER_POOL_MAX`/`TELEGRAM_TIMEOUT_MS`/`WORKER_RESCATE_MIN`/`WORKER_APAGADO_MS` leídos en código sin propagar en compose/env.
5. **Repo**: git desincronizado del disco (11 cambios); READMEs de worker/web obsoletos; sin tests automatizados ni CI.

#### Recomendaciones (antes de nuevas funcionalidades)

1. **Commitear/desincronizar git**: decidir el destino de `chasqui_responder.js`, `077`, `078` y los 8 archivos modificados para que "estado del repo" == "estado en disco" (afecta a la validez del contexto IA y a 5 incertidumbres).
2. **Cerrar la deuda de seguridad BLOCKER/ERROR antes de F1**: `SET search_path` en las 2 SECURITY DEFINER (C6.10), `N8N_BLOCK_ENV_ACCESS_IN_NODE=true` (C6.21), acotar `GRANT EXECUTE` y crear rol acotado para el registrador (C6.19), escapar `'${VAR}'` en scripts, y decidir el trigger de bloqueo del DELETE de `consulta` (C6.18).
3. **Formalizar las excepciones a C6.5/C6.12** (lista blanca) en un archivo o sección de skill, hoy implícita.
4. **Mejorar `check_pattern`/`check_sql`** (C6.1/C6.2/C6.7/C6.10) o definir el contrato de uso de `validate_action` (details) para no depender de la redacción del agente si se quiere usar como puerta dura.
5. **Cargar el plan futuro como tareas PENDING** (ya está, Fase 13) y NO implementar antes de resolver 1–4; los hallazgos de las contradicciones del plan (P0001, rutas fuera de `(portal)`, etc.) ya están corregidos en las descripciones de las 20 tareas.
6. **Decidir `active` de los 9 agentes de análisis** y el mapeo real de `allowed_tools`/`forbidden_tools` al runtime (pendientes desde Fase 8/14).

#### Calidad del contexto (coverage / confidence / unknowns / unresolved_conflicts)

- **coverage**: ALTA — los 8 componentes principales (DB, worker, n8n, web, Telegram, infra, testing, integraciones) tienen contexto registrado; 8/8 skills con 8 secciones; los 7 agentes de trabajo con 3–4 skills; 41 reglas y 23 constraints con evidencia `path:line`. **No se almacenó el repositorio completo**: solo el conocimiento necesario para razonar (objetivo del plan).
- **confidence**: ALTA en arquitectura/esquema/reglas/constraints (verificadas contra migraciones y código en disco, reconciliadas en Fases 14/15/16); MEDIA en runtime y ajustes finos (validate_action, allowed_tools, required_agent).
- **unknowns**: 20+ incertidumbres abiertas (listadas en el capítulo de Incertidumbres), ninguna bloqueante del contexto normativo; residuales de credenciales/despliegue/git, no de conocimiento del código.
- **unresolved_conflicts**: 6 contradicciones doc-vs-código + 6 del plan futuro vs convenciones reales; todas **conservadas y documentadas** (nunca resueltas en silencio); las del plan ya neutralizadas en las descripciones de las 20 tareas PENDING.

**Cierre de la misión**: todos los criterios del plan §Criterios están satisfechos (inspección completa, arquitectura documentada, esquema/worker/Telegram/n8n/Next.js/integraciones analizados, convenciones/reglas/constraints/ADRs/agentes/skills/relationships/commands registrados, plan futuro separado, 20 tareas PENDING, StrictContext poblado y validado, `get_agent_context` y `validate_action` comprobados — con las limitaciones del runtime reportadas, contradicciones e incertidumbres identificadas, 0 funcionalidades nuevas, 0 refactors). Un agente nuevo puede recibir una tarea y recuperar desde StrictContext: Task → Agent → Skills → ADRs → Rules → Constraints → Acceptance Criteria sin depender de los Markdown de apoyo.

## Registro acumulado

### Incertidumbres pendientes (UNKNOWN)

Las observaciones detectadas en Fase 1 se conservan sin resolver ni modificar. Las relacionadas con la base de datos fueron investigadas en la Fase 2 por database-analyst (ver directiva en la sección de la Fase 2). Las 4 incertidumbres de Fase 1 de dominio BD quedaron resueltas en Fase 2 (estados como `text`, `db/seeds/`, `telegram_update.procesado`, `config.ia_modelo`); se conservan abajo las residuales y las que no son de dominio BD:

- Modelo de IA real en producción (`config.ia_modelo`): el seed `078_chasqui_ia.sql:49-50` documenta `deepseek-v4-pro`/`deepseek-v4-flash` como opciones y el default es `deepseek-v4-pro`; el worker lo lee con `config_txt('ia_modelo','deepseek-v4-pro')`. **Residual**: si el nombre existe realmente en el provider no es verificable sin llamada a la API ni inspección del `.env` real (Fase 2 → `UNKNOWN`).
- `db/seeds/`: directorio existe pero vacío, sin referencias en `docker-compose.yml`, scripts ni docs; el seeding real vive en `100_seed_roles.sql` + `110_seed_operativo.sql` y el superadmin por env. **Propósito del directorio: `UNKNOWN`** (Fase 2; probable residuo, sin evidencia de uso).
- Si el worker desplegado incluye `chasqui_responder` (untracked en git): el contenedor en producción puede no tener IA (Fase 1; no es de dominio BD — se conserva UNKNOWN y se revisa en integración).
- `TELEGRAM_BOT_USERNAME` y `SUPERADMIN_TELEGRAM_USER_ID` se inyectan al worker (`docker-compose.yml:154-155`) pero el código del worker no las consume; se desconoce si son residuo o se usan en otro punto (Fase 1).
- `N8N_INTERNAL_URL` se inyecta al contenedor web (`docker-compose.yml:193`) pero no se halló ningún consumidor en `web/src`; se desconoce si es residuo o hay uso futuro (Fase 3 → `UNKNOWN`).
- `editarMensaje` existe en `worker/src/telegram.js:145-153` pero ningún manejador del worker lo importa; la edición de menús vive en SQL (`accion_enviar`/`accion_editar`) y la ejecuta n8n. Función sin callsites activos (Fase 3).
- Comandos `/turno` y `/turnos`: **no existen** como comandos de texto en ninguna migración; la operación de turnos es por botones `turno:*`. Si la documentación los menciona, es contradicción doc vs código a revisar (Fase 3).
- "3 intentos máximo" del código web de 6 dígitos (doc `chasquipet.md:400`): no está en SQL (solo incrementa `intentos`, solo el rate limit 10/h lo contiene); UNKNOWN si vive en el frontend (Fase 5).
- Semántica de `turnos_por_avisar`/`posicion` para el conteo "faltan N" (`notificar_turnos_proximos.js:26,45`): definición no releída; UNKNOWN (Fase 5).
- `process.exit(0)` en `uncaughtException` del worker y `setTypeParser(20, Number)` (pérdida de precisión bigint > 2⁵³): UNKNOWN si es diseño deliberado (Fase 5).
- Definición íntegra de `v_stock_medicamento` (045) y `consumir_rate_limit` (010): no releída en Fase 5; UNKNOWN (al igual que en Fases 2-4).
- Frontera real sql-engineer ↔ telegram-engineer: la lógica del bot y del dominio viven ambas en SQL; la frontera propuesta es "función de bot + FSM" vs "función de dominio", pero `058_auth_web.sql` mezcla ambas (Fase 8 → UNKNOWN si hace falta un criterio más fino, ver Fase 9 skills).
- Fusión posible integration-engineer ↔ backend-engineer: superficie de integración actual pequeña (IA en worker, túnel, registro webhook); se conserva separado por el plan §10 y por Factus/WhatsApp planificados; UNKNOWN si en la práctica conviene fusionarlos (Fase 8).
- Destino de los 9 agentes de análisis ya poblados en StrictContext (project-analyst … context-reviewer): si se conservan activos, desactivan o dan de baja al poblar los 7 de trabajo en Fase 14 (Fase 8 → UNKNOWN).
- Lista exacta de `allowed_tools`/`forbidden_tools` por agente (nombres de herramientas y formato JSONB del runtime) a resolver en Fase 14 (Fase 8).
- Desajuste del esquema `commands`: la tabla StrictContext tiene `steps/preconditions/expected_output/rollback_steps`, pero el plan §13 pide `prompt_template/required_context/required_skills/validation_requirements`; el mapeo de los 8 commands especificados en Fase 11 a las columnas reales se decide en Fase 14 (Fase 11).
- `required_agent` paramétrico en `inspect`/`implement`/`test`/`session`: la columna `commands.required_agent` es de valor único y esos commands dependen del dominio/tarea (Fase 11).
- El runtime normal de StrictContext solo expone `get_command_steps()` (lectura), no la ejecución de commands; por eso Fase 11 registró solo especificaciones, la ejecución depende del runtime futuro (Fase 11).
- Webhook de Factus (F1-S8 del plan): vive en `web/**` pero es un adaptador externo; `integration-engineer` no edita `web/**` (forbidden_tools Fase 8) y `frontend-engineer` no tiene el skill external-integrations (Fase 12). **RESUELTA en Fase 13** (recomendación): se asigna a `frontend-engineer` (route handler con forma C6.13; la lógica Factus queda en funciones SQL de F1-S4/S1-S8); la decisión final de propietario y el ajuste de `forbidden_tools` si integration-engineer lo tomara queda para Fase 14. UNKNOWN residual baja.
- Generación de PDF del carnet (F2-S14): se asignó a `backend-engineer` (dueño del worker, no es adapter externo) pero no hay precedente de PDF en el worker para verificar la autoridad (Fase 12). **Confirmada en Fase 13** como `backend-engineer`; el volumen/deps de PDF (pdf-lib/qrcode) sin precedente quedan UNKNOWN baja para Fase 14.
- Features de `chasquipet.md:80-84` sin detalle de plan (historia clínica por audio, hospitalización, laboratorio interno, app del dueño, órdenes de compra/cuentas por pagar, migración de datos históricos): DOES_NOT_EXIST pero sin especificación en `plan_ejecucion_chasquipet.md`; no convertibles a tareas en Fase 13 hasta tener detalle (Fase 12).
- Kiosco tablet: el canal `tablet_kiosco` existe en `030_turnos.sql:64` pero no hay plan de implementación en las 20 sesiones del plan de ejecución (Fase 12). UNKNOWN si se planifica o solo se documenta.
- Medicamentos de control especial (`chasquipet.md:85`): `[CONFIRMAR]` pendiente con el cliente; el plan ordena no implementar ni modelar (Fase 12). Sin tarea.

### Contradicciones documentación vs código

- `docs/avance-analisis-strictcontext.md` Fase 0 dice "27 migraciones"; el directorio real `db/migrations/` tiene **24** (22 SQL + 2 .sh). Corregido en Fase 1.
- `docs/avance-analisis-strictcontext.md` Fase 0 dice "13 manejadores"; `worker/src/tareas/index.js` registra **11**. Corregido en Fase 1.
- `docs/avance-analisis-strictcontext.md` Fase 1 dice "0 vistas" en la DATABASE; el esquema real tiene **4 vistas**: `v_usuario_permiso`, `v_cola_actual`, `v_lote_disponible`, `v_stock_medicamento` (030:648, 045:228, 045:242, 020:75). **Corregido en Fase 2**.
- `worker/README.md` documenta 10 manejadores (falta `chasqui_responder`) y referencia `worker/sql/010_aviso_turno.sql` inexistente (la migración real es `db/migrations/035_aviso_turno.sql`).
- `web/README.md` dice que la web "solo llama funciones SQL"; existen 3 puntos de SQL crudo inline (Fase 5 confirma uno no reportado antes): `web/src/lib/clinico.ts:154` (`consultasRecientes`), `web/src/app/(portal)/admin/config/page.tsx:42` y `web/src/lib/pantalla.ts:44` (`buscarSedeActiva`).
- `web/README.md` y `web/src/lib/reportes.ts:5` dicen "los nueve reportes de §10"; el código registra **12** claves de reporte (`reportes.ts:38-259`) (Fase 5).
- Doc `chasquipet.md:394` promete botón "Iniciar sesión web" en el menú del bot; el código no expone ese botón (el acceso real es deep link `web-<id>` y el botón `por:enlace`) (Fase 5).
- Doc `chasquipet.md:400` dice "3 intentos máximo" para el código de 6 dígitos; el SQL solo incrementa `intentos` sin validar tope (solo rate limit 10/h) (Fase 5).
- `066_bot_cobro.sql:9-11` declara ruta de cobro de "3 toques"; el código real son 4 (`cob:cobrar → cob:cta → cob:pagar → cob:medio`) (Fase 5).
- `SESSION_SECRET` documentada (`.env.example:172`) e inyectada (`docker-compose.yml:189`) pero jamás leída por `web/src`; las cookies no se firman (Fase 5).
- **PLAN-futuro vs convenciones reales (Fase 12, para no heredar errores al crear tareas en Fase 13)**:
  - `docs/plan_ejecucion_chasquipet.md` Anexo C manda `RAISE EXCEPTION USING errcode='P0001'` + `hint=`; el patrón real son códigos semánticos `23514`/`0A000`/`42501`/`28000`, jamás `P0001` (Fase 4 p.4).
  - F1-S2 (plan: agregar `bot_manejar_presupuesto` modificando el router/`020_identidad.sql`) vs convención real de stubs encadenados + `COALESCE` en `078` (Fase 4 p.10).
  - F1-S5 (plan: `db.query('SELECT * FROM documento_electronico…')` en el worker) vs ADR-02/C6.16 (el worker llama funciones SQL).
  - F1-S3/F1-S7 (plan: rutas `web/src/app/presupuestos/…`, `admin/dian/…` fuera de `(portal)`) vs portal real bajo `(portal)/layout.tsx` (Fase 3 §6).
  - F2-S11 (plan: "Dueño escribe `/reservar`") vs no-existencia de comandos de texto y operación por botones/callbacks con prefijo (Fase 3).

### Problemas detectados (no corregir, solo reportar)

- **StrictContext runtime (Fase 16 → RESUELTO en Fase 17)**: `validate_action()` estaba inoperante — `constraints.id=13` (C6.13) tenía `check_pattern` con `**` (glob) que `re.search` no compilaba (`multiple repeat at position 65`). En la sesión 18 (Fase 17) se corroboró la corrección in situ (`**`→`.*`); los 23 `check_pattern` compilan y `validate_action` ya no lanza. NO fue una refactorización de código del proyecto: solo saneamiento del contenido de la BD `.strictcontext.db` (artefacto de la propia misión, no del repo de negocio).
- **Calidad de `check_pattern` (Fase 17, NO corregida por mandato)** — las pruebas A–D exponen que varias regex no detectan su violación objetiva:
  - **C6.1 y C6.2 (BLOCKER append-only) no detectan un DELETE literal**: C6.1 tiene un texto `SELECT 1 FROM pg_proc p WHERE … -- triggers …` (parece `check_sql` mal puesto en `check_pattern`); C6.2 es lenguaje natural `DELETE/JOB sobre tablas append-only`. `DELETE FROM evento_auditoria …` → `re.search` no casa → VALID (falso negativo). La protección vino solo de la regla textual MUST_NOT 16.
  - **C6.16 falso positivo por alternancia**: `INSERT|UPDATE|DELETE directo sobre tarea_async en worker/src` (sin agrupar el `|` con el resto) → casa cualquier `INSERT`/`UPDATE`/`DELETE` en cualquier detalle (p.ej. `UPDATE pago SET valor=1` desde sql-engineer) y dispara C6.16 fuera de su dominio worker/src.
  - **C6.7 falso negativo ante tokens reales**: `(Telegram|DEEPSEEK|SESSION_SECRET)[a-zA-Z0-9_-]{20,}` exige ≥20 alnum/`_`/`-` pegados a la clave; un `TELEGRAM_BOT_TOKEN = '123456789:AAA…'` / `DEEPSEEK_API_KEY = 'sk-…'` corta en ` = `/`:` y no casa → el BLOCKER de filtración no se activa ante el formato real. Solo casa por la alternative textual `token en literal del repo`.
  - **C6.10 inexacto**: `CREATE FUNCTION SECURITY DEFINER sin "SET search_path"` no detecta una firma SECURITY DEFINER real (la regex necesita el texto literal o un parser SQL).
  - **Mecanismo del runtime**: `validate_action(agent, action, details)` casa por `re.search(check_pattern, details)` sobre UNA frase de detalle libre (nunca contra un archivo/código, ni contra `check_sql` — NULL en 23/23) y por substring de `action` en el texto de reglas MUST_NOT → la cobertura real depende de cómo el agente redacte `details`, no de evidencia objetiva. Las regex correctas (C6.12 `.query(SELECT…`, C6.13 force-static, C6.3 `real|double precision`, C6.16 cuando aplica al worker) sí detectan.
- El historial git está desincronizado del disco: `chasqui_responder.js`, `077_portal_enlace.sql` y `078_chasqui_ia.sql` son funcionalidad sin commit (untracked), y además hay modificaciones sin commit en `.env.example`, `README.md`, `docker-compose.yml`, `scripts/configurar-bot.sh`, `web/src/app/entrar/*`. El commit `master` 8c8a989 está por detrás del estado actual.
- No existen tests automatizados ni CI en el proyecto; la verificación es manual (typecheck/build del web, `node --check` del worker, demo + psql).
- `worker/README.md` y `web/README.md` no reflejan componentes recientes (IA, enlace del portal).
- **Seguridad (Fase 2/5)**: las dos únicas funciones `SECURITY DEFINER` (`auditar` 090:68 y `mantenimiento_diario` 090:74) no fijan `SET search_path`, quedando expuestas al hijacking de search_path en ausencia de esquemas públicos; además `auditar` acepta parámetros de texto sin validar (permite polucionar el log de auditoría) y nunca puebla la columna `ip` de `evento_auditoria`.
- `evento_auditoria.ip` existe en el esquema pero ningún componente la llena (la función `auditar` no recibe ese parámetro).
- **Seguridad (Fase 5)**: `GRANT EXECUTE ON ALL FUNCTIONS TO chasquipet_app` (090:35) abre toda la superficie de funciones, incluidas las SECURITY DEFINER.
- **Seguridad (Fase 5)**: `900_superadmin.sh:21,28` y `000_n8n_db.sh:43-45` intercalan `'${VAR}'` en SQL sin escapar (frágil ante contraseñas con comilla).
- **Seguridad (Fase 5)**: `scripts/registrar-publico.sh:79-82` interpola hostname externo en `UPDATE config` con credenciales de **dueño** (debería ser rol acotado a UPDATE sobre `config`).
- **Seguridad (Fase 5)**: `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` (docker-compose.yml:112) permite a cualquier workflow importado leer los secrets del entorno n8n.
- **Robustez (Fase 5)**: el `DELETE` de `consulta`/`consulta_adenda` no está bloqueado por trigger; la defensa son las FKs (la doc los declara "inmutables" solo para UPDATE).
- **Deployment (Fase 5, Incertidumbre)**: `WORKER_POOL_MAX`, `TELEGRAM_TIMEOUT_MS`, `WORKER_RESCATE_MIN`, `WORKER_APAGADO_MS` se leen en el código del worker pero no se propagan en compose/env.example (solo valen sus defaults).