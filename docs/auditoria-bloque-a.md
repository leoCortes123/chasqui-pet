# Auditoría del Bloque A — ¿está el terreno firme para el Bloque B?

**Fecha:** 12 de agosto de 2026
**Alcance:** fases A0 a A7 de `docs/plan-consolidacion-chasqui-pet.md`.
**Método:** no se dan por buenos los reportes de fase. Cada afirmación de esta auditoría se
verificó contra el repositorio, contra la base de trabajo o ejecutando el comando, y se anota
con qué. Lo que no se pudo verificar aparece como tal.

**Veredicto: el bloque A está cerrado y el bloque B puede empezar.** Con cuatro salvedades
abiertas (§5), ninguna bloqueante, y una recomendación de orden para B1 (§6).

---

## 1. Estado por fase

| Fase | Estado | Evidencia verificada en esta auditoría |
|---|---|---|
| A0 Ordenar documentación | ✅ | Un solo plan vigente; `docs/archivo/` con los cuatro planes superados; los `reporte-fase*.md` en su sitio. |
| A1 Versionado de migraciones | ✅ | `schema_version` existe y responde `31 aplicadas, 0 pendientes`. Los dos caminos convergen: `910_registrar_versiones.sh` siembra en instalación limpia (lo ejercita cada corrida de `pruebas.sh`) y `migrar.sh` aplicó `150` en la base viva. **La reja de hash se probó de verdad**: se modificó un archivo ya aplicado, el migrador se detuvo con código 2 sin aplicar nada, y al restaurarlo volvió a estar limpio. |
| A2 Cerrar fase 2 del asistente | ✅ | `docs/reporte-fase2-borrador-consulta.md` existe; `079`, `081`–`083` y `worker/src/tareas/enviar_aviso_dueno.js` están rastreados por git (`git ls-files`); el §Anexo A3 del plan marca la fase 2 como cerrada. |
| A3 Huérfanas + purga | ✅ | El corte está en el worker (`chasqui_responder.js:268`: con una propuesta pendiente, las siguientes tool calls no llegan a `ia_llamar`). `ia_purgar_pendientes()` existe en `130` y está **enganchada dentro de `mantenimiento_diario()`** (`130:126`), con sus contadores en el `jsonb` de salida. |
| A4 Pruebas de invariantes | ✅ | `bash scripts/pruebas.sh`: 8 archivos, **117 pruebas en verde**, sobre una base construida desde cero con las 31 migraciones. |
| A5 Registro de operaciones | ✅ | `verificar_registro_operaciones()` devuelve `ok:true` en la base de trabajo y en la efímera; ninguna herramienta activa sin `funcion` ni sin `modulo` (lo comprueba `070_ia_confirmacion.sql`). |
| A6 Orquestación al núcleo | ✅ | `alta_paciente(uuid, jsonb, text)` existe en la base viva; `ia_alta_paciente_ejecutar` y `bot_cli_crear_paciente` conservan su firma y delegan. 17 pruebas propias. Ver `docs/reporte-faseA6-alta-paciente.md`. |
| A7a Convención de cabecera | ✅ | Escrita en `CLAUDE.md` y **exigida** por `migrar.sh`: una pendiente sin `-- Ámbito:` aborta la tanda con código 3. Probado con una migración temporal. Ver `docs/reporte-faseA7-higiene-fronteras.md`. |
| A7b Presentación fuera del núcleo | ⛔ Descartada | Con razón escrita, no por olvido: `reporte-faseA7` §5. Era opcional en el plan y, tal como estaba especificada, habría creado un segundo nombre para lo mismo con 143 llamantes apuntando al viejo. |

## 2. Lo que el bloque A dejó, en concreto

| Falencia que el plan quería cerrar | Cómo se comprueba hoy |
|---|---|
| «No hay forma de saber qué migraciones están aplicadas» | `bash scripts/migrar.sh --estado` |
| «Una migración nueva no se aplica sola en base viva» | `bash scripts/migrar.sh` |
| «Editar una migración aplicada no lo detecta nadie» | El migrador para con código 2 |
| «Cero pruebas automatizadas» | `bash scripts/pruebas.sh` — 117 invariantes |
| «Agregar una herramienta al asistente cuesta reescribir cuatro funciones» | Un `INSERT` en `ia_herramienta` y un envoltorio `op_*` |
| «La misma regla de negocio escrita una vez por canal» | `alta_paciente()`; el bot y el asistente delegan |
| «Nadie sabrá qué es núcleo y qué es veterinario» | La cabecera `Ámbito:`, exigida por el migrador |

Cinco commits, uno por fase (`3895fc6`, `7c3b56a`, `9da0bb8`, `36e4682`, `b663ff6`); A6 y A7
todavía sin commitear al cierre de esta auditoría.

## 3. Comprobaciones de regresión ejecutadas

| Comprobación | Resultado |
|---|---|
| Instalación limpia desde `db/migrations/` (31 archivos) | Sin error |
| Batería completa de invariantes | 117 pruebas ✔, 0 ✘ |
| `verificar_registro_operaciones()` en base viva | `ok:true` |
| Sintaxis de todo el worker (`node --check`, `src/` y `src/tareas/`) | Sin error |
| Tipos de la web (`tsc --noEmit`) | Sin error |
| Reja de hash del migrador | Detiene con código 2 |
| Reja de ámbito del migrador | Detiene con código 3 |
| Base de trabajo | 31 aplicadas, 0 pendientes |

## 4. Corrección de la documentación que gobierna el trabajo

`CLAUDE.md` es lo primero que se lee antes de tocar el repositorio, y tres de sus
afirmaciones habían quedado **falsas** por obra del propio bloque A. Se corrigieron en esta
auditoría, porque una instrucción vencida es peor que ninguna:

| Decía | Dice ahora |
|---|---|
| «Sin ORM ni migrador; no hay tabla de versiones» | Describe `schema_version`, `migrar.sh` y la reja de hash |
| «No existe framework de pruebas automatizadas» | Describe la batería pgTAP y cómo agregar un archivo |
| «La fase 2 del asistente no tiene reporte y no está en git» | Marcada como resuelta por A2 |

Además se agregó `db/pruebas/` a la estructura del repositorio, los comandos de `migrar.sh` y
`pruebas.sh` a *Development Commands*, y la convención `Ámbito:` a las convenciones de SQL.

Lo que **sigue vigente** de la sección de contradicciones y no se tocó: el `lint` declarado
sin ESLint, el comentario que apunta a `worker/sql/010_aviso_turno.sql`, el
`next.config.js`/`.ts` del Dockerfile, `WORKER_RESCATE_MIN`/`TELEGRAM_TIMEOUT_MS` sin declarar
en compose ni en `.env.example` (verificado: siguen sin aparecer en ninguno de los dos),
`opencode.json` fuera de `.gitignore`, y la ausencia de estrategia de ramas y de DIAN.

## 5. Salvedades abiertas al entrar al bloque B

1. **`npm run typecheck` no corre en esta copia de trabajo.** Falla con
   `sh: 1: tsc: Permission denied`: el repositorio vive en un `fuseblk` (`/mnt/datos`) y los
   binarios de `node_modules` no tienen bit de ejecución (`node_modules/typescript/bin/tsc`
   está `-rw-r--r--`). No es un problema del código —los tipos compilan— pero el comando que
   documentan `CLAUDE.md` y el plan **no funciona tal cual**. Mientras tanto:
   `cd web && node node_modules/typescript/bin/tsc --noEmit`. Afecta a B1, que toca la web.
2. **`opencode.json` sigue sin estar en `.gitignore` y lleva una credencial real.** El bloque
   B escribirá muchos archivos nuevos; basta un `git add -A` para publicarla. La regla de
   agregar rutas explícitas está escrita, pero una regla no es una reja.
3. **A6 y A7 están sin commitear.** El árbol también tiene trabajo de interfaz en curso
   (`web/src/app/(portal)/*`, `tokens.css`, `navegacion.tsx`) que no es del bloque A y no se
   tocó en esta auditoría.
4. **La reja de ámbito comprueba que se declare, no que sea correcto.** Eso es criterio y no
   se automatiza.

## 6. Recomendación de orden para el bloque B

El plan pone B1 (agenda de citas) primero y esta auditoría no lo discute. Dos observaciones
para cuando empiece:

- Las tablas `cita` y `disponibilidad` existen desde `050_pacientes.sql` como **cascarón
  vacío**, sin una sola función que las lea o escriba. Verificado: siguen así. B1 no parte de
  cero pero tampoco hereda nada útil salvo la forma de las tablas, que hay que revisar antes
  de darla por buena.
- B1 es la primera fase que estrena de verdad lo que dejó el bloque A: su migración lleva
  cabecera `Ámbito: VERTICAL`, se aplica con `migrar.sh`, sus herramientas del asistente se
  registran con un `INSERT` más un envoltorio `op_*` —sin tocar `ia_llamar`—, y sus
  invariantes van a `db/pruebas/`. Si algo de eso resulta incómodo en B1, es señal de que
  algo del bloque A quedó a medias; conviene decirlo entonces y no rodearlo.
