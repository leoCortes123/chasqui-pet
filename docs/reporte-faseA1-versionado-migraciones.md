# Reporte — Fase A1: Versionado y aplicación de migraciones

**Plan:** `docs/plan-consolidacion-chasqui-pet.md` → Bloque A, Fase A1
**Estado:** `COMPLETED`
**Fecha de verificación:** 2026-08-12 (BD viva `chasquipet-db` + contenedor efímero `postgres:16-alpine`)

## 1. Resumen

Chasqui Pet no tenía forma de saber qué migraciones estaban aplicadas: el contenedor de
Postgres ejecuta `db/migrations/` una sola vez, con el volumen vacío, y en la base viva las
migraciones nuevas se aplicaban a mano sin dejar rastro. Ahora existe un registro
(`schema_version`) y un único camino previsto para aplicar lo que falte
(`scripts/migrar.sh`), con los dos caminos —volumen nuevo y base viva— convergiendo en el
mismo estado.

Además, la fase destapó y corrigió un defecto preexistente: **la instalación limpia desde
`db/migrations/` estaba rota** (ver §8).

Lo que quedó en pie:

- `schema_version(version, nombre, hash, aplicada_at, origen)` con `registrar_version()`
  (idempotente, y ruidosa si el archivo cambió) y `schema_version_estado()`.
- `910_registrar_versiones.sh`: en instalación limpia siembra el registro con todo lo que
  el arranque acaba de aplicar.
- `scripts/migrar.sh`: `--estado`, aplicar pendientes, `--retro-registrar`. Cada migración
  se aplica **en la misma transacción que su registro**.
- `075_prerrequisitos_ia.sql`: adelanta las dependencias que `078`–`083` daban por
  existentes y que hacían abortar la instalación limpia.
- Retro-registro ejecutado sobre la base viva, con respaldo previo.

## 2. Archivos modificados

| Archivo | Cambio |
|---|---|
| `db/migrations/120_schema_version.sql` | **Nuevo.** Tabla `schema_version`, `registrar_version()`, `schema_version_estado()`, REVOKE de escritura a `chasquipet_app`. Cabecera `NÚCLEO`. |
| `db/migrations/910_registrar_versiones.sh` | **Nuevo.** Último paso del arranque: siembra el registro con los `.sql` que initdb acaba de aplicar (`origen = 'initdb'`). |
| `db/migrations/075_prerrequisitos_ia.sql` | **Nuevo.** Adelanta, idempotente, la creación de los roles de base de datos y los seeds de `rol` y `permiso` que `078`–`083` necesitan. Cabecera `NÚCLEO`. |
| `scripts/migrar.sh` | **Nuevo.** Migrador para bases ya inicializadas. |
| `README.md` | Sección «Migraciones sobre una base que ya existe», línea de estructura y una entrada en operaciones frecuentes. |

Sin cambios en web, worker, n8n ni `docker-compose.yml`.

## 3. Base de datos

- **Tabla nueva:** `schema_version`. `version` (prefijo de tres dígitos) es la clave;
  `hash` es el sha256 del archivo aplicado; `origen ∈ {initdb, migrar, retro}` distingue
  «la ejecutó el arranque», «la aplicó el migrador» y «se dio por aplicada sin ejecutarla».
- **Funciones nuevas:** `registrar_version(text,text,text,text)`,
  `schema_version_estado(text,text)` (`STABLE`).
- **Permisos:** `090_grants.sql` deja privilegios por defecto que darían DML completo a
  `chasquipet_app` sobre cualquier tabla nueva; `120` los revoca sobre `schema_version` y
  sobre `registrar_version`. Al rol de la aplicación le queda solo `SELECT` (verificado en
  la base viva). El registro lo escriben el arranque y el migrador, ambos como dueño.
- **Auditoría:** ninguna. La tabla es infraestructura de despliegue, no un acto de usuario;
  `auditar()` registra actos de usuario y mezclarlos degradaría la auditoría.
- **Idempotencia:** `CREATE TABLE IF NOT EXISTS`, `CREATE OR REPLACE`, `registrar_version`
  no falla al repetirse con el mismo hash. `075` es enteramente `ON CONFLICT DO NOTHING` +
  `IF NOT EXISTS`.

## 4. Integraciones

- **Bot / n8n / worker / portal:** sin cambios de contrato. Verificado tras el
  retro-registro: `/health` responde 200 y no aparecen errores de permisos en los registros
  de `worker` y `web`.
- **Arranque del contenedor `db`:** ahora tiene un paso más (`910`), posterior a
  `900_superadmin.sh`. Solo corre con el volumen vacío.
- **Respaldo/restauración:** `restaurar.sh` no necesita cambios; `schema_version` viaja en
  el dump como cualquier otra tabla, que es justamente lo que se quiere (un respaldo
  restaura también su estado de migraciones).

## 5. Pruebas ejecutadas

Contenedor efímero `postgres:16-alpine` con `db/migrations` montado (instalación limpia
real, no simulada) y base viva para lo demás. Copia de `migrar.sh` apuntada al contenedor
efímero para no ensayar contra producción.

| # | Prueba | Esperado | Obtenido | Resultado |
|---|---|---|---|---|
| 1 | Instalación limpia desde `db/migrations` (antes de `075`) | Debía completar | **Abortó en `078`**, exit 3: FK `ia_herramienta_permiso_fkey` | FAIL → origen de §8 |
| 2 | Instalación limpia con `075` | Arranque completo y registro sembrado | «Registro de versiones sembrado: 28 migraciones» y sin errores | PASS |
| 3 | Paridad del catálogo tras `075` | Igual que la base viva | `permiso` 30/30, `rol` 5/5, `rol_permiso` 93/93, `ia_herramienta` 25/25 | PASS |
| 4 | Caso exitoso: migración pendiente nueva (`999_prueba_migrador.sql`) | Se aplica y se registra | Tabla creada y fila `999 / migrar` | PASS |
| 5 | Idempotencia: correr el migrador de nuevo | No aplica nada | «Nada que aplicar: la base está al día (27 migraciones)» | PASS |
| 6 | `registrar_version` repetida con el mismo hash | `ya_registrada`, sin error | `{"ok": true, "estado": "ya_registrada"}` | PASS |
| 7 | Datos inválidos: archivo ya aplicado cuyo contenido cambió | Falla ruidosamente | `--estado` y aplicar → rc 2 con el mensaje de «no se editan las migraciones» | PASS |
| 8 | `registrar_version` con hash distinto | Excepción | `ERROR: La migración 010 ya está registrada con otro contenido…` | PASS |
| 9 | Rollback: migración que falla a la mitad (`CREATE TABLE` + `1/0`) | Ni tabla ni registro | rc 3; `no_registrada \| no_creada` | PASS |
| 10 | Ausencia de datos: base sin `schema_version`, consulta de estado | Informa y orienta | «La tabla schema_version todavía no existe…» + comando sugerido | PASS |
| 11 | Red de seguridad: base con esquema y registro vacío, modo aplicar | Se niega y remite a `--retro-registrar` | ALTO + rc 1 | PASS |
| 12 | Permisos: rol de la aplicación sobre `schema_version` | Solo `SELECT` | `SELECT` (limpia y viva) | PASS |
| 13 | Confirmación humana del retro-registro | Pide escribir `SI` | Pide y cancela si no se escribe (rc 1) | PASS |
| 14 | Retro-registro en la base viva | 27 retro + 1 aplicada | `retro 27 / migrar 1`, 28 en total | PASS |
| 15 | §Verificación del plan: ¿está `083` en la base viva? | `t` | `tiene_083 = t` | PASS |
| 16 | Estado final de la base viva | 0 pendientes | «Total: 28 aplicadas, 0 pendientes» | PASS |
| 17 | Regresión de integración tras el retro-registro | Sistema intacto | `/health` 200; sin errores en `worker`/`web` | PASS |

Las trazas de prueba (`998_prueba_rollback.sql`, `999_prueba_migrador.sql`, contenedor
efímero) se eliminaron. El único artefacto que queda es el respaldo
`backups/antes-de-migrar-a1.dump`.

## 6. Decisiones tomadas

- **`version` = prefijo de tres dígitos**, no el nombre completo: el prefijo es lo que
  ordena la ejecución y lo que el proyecto ya trata como identidad de una migración.
- **Columna `origen`**, no pedida por el plan: el retro-registro marca como aplicado algo
  que nadie ejecutó, y eso tiene que quedar distinguible el día que algo no cuadre.
- **Transacción que envuelve migración + registro**: es lo que impide el estado «se aplicó
  a medias y quedó anotada». Se comprobó que ninguna migración del repositorio contiene
  sentencias incompatibles con un bloque de transacción (`CREATE DATABASE`,
  `CONCURRENTLY`, `ALTER TYPE … ADD VALUE`).
- **El migrador no decide, consulta**: el estado de cada archivo lo resuelve
  `schema_version_estado()` en SQL, no el shell (regla C6.12).
- **`--retro-registrar` interactivo**: exige escribir `SI`. Da por aplicado lo que no
  ejecutó; no debe poder pasar por accidente.
- **Prefijo `120`** para la tabla (siguiente libre por encima de `110`, y anterior a los
  `9xx` del arranque) y **`075`** para los prerrequisitos (único hueco disponible antes de
  `078`, que es lo que la corrección exige).

## 7. Incertidumbres restantes

- El migrador asume que `psql` corre **dentro** del contenedor `db` (`ADMIN_DATABASE_URL`
  apunta al host `db`, que solo resuelve en la red de compose). En un despliegue donde la
  base no viva en compose, el script necesitaría una variante; hoy no existe ese caso.
- El respaldo previo se hace a mano (documentado en `README.md`); el migrador no lo
  dispara. Automatizarlo era ampliar el alcance de la fase.

## 8. Riesgos y problemas encontrados

**Defecto preexistente, corregido en esta fase — `HIGH_RISK`: la instalación limpia estaba
rota.** Levantando un contenedor de Postgres virgen contra `db/migrations/`, el arranque
aborta en `078_chasqui_ia.sql` (exit 3). Tres dependencias apuntan a archivos con prefijo
posterior:

1. `ia_herramienta.permiso` es FK contra `permiso(codigo)`, y los 12 códigos que usa se
   siembran en `100_seed_roles.sql`;
2. `078` termina con `GRANT … TO chasquipet_app`, rol que crea `090_grants.sql`;
3. `083` inserta en `rol_permiso` para `veterinario` y `auxiliar`, roles de `100`.

No es un error de contenido: `078`–`083` se escribieron para aplicarse **a mano sobre la
base viva**, donde `090` y `100` llevaban meses corridos, y su prefijo nunca se conformó al
orden de initdb. Por eso nadie lo notó: el único camino que lo revela es el que esta fase
estrena.

Se resolvió con `075_prerrequisitos_ia.sql`, aditivo (no edita ni renumera nada), decisión
tomada con el usuario. Alternativas descartadas: renumerar `078`–`083` a `12x` (contradice
la regla de no tocar migraciones aplicadas y cambia la clave del registro) y dejarlo solo
documentado (bloquearía la Fase A4, cuyo arnés pgTAP levanta la base desde las
migraciones).

**Riesgo residual:** `075` duplica dos bloques de seed que también viven en `100`. Si
mañana se agrega un permiso, va en `100` o en una migración nueva, **nunca** en `075`; el
archivo lo dice en su cabecera. La duplicación es de datos idempotentes, no de lógica.

## 9. Desviaciones respecto al plan

- El plan pedía sembrar `010`–`078` y `080`, `085`–`110` como aplicadas «y luego aplicar
  `079`, `081`, `082`, `083` si no lo están». Se verificó contra `pg_proc` que las cuatro
  **ya estaban aplicadas** en la base viva (`ia_llamar` contiene `preparar_consulta_clinica`,
  `despachar_receta_multiple`, `cargar_paquete_servicios` y `preparar_aviso_dueno`), así que
  el retro-registro las cubrió a todas y no hubo nada que ejecutar.
- Se agregó `075_prerrequisitos_ia.sql`, fuera del alcance literal de A1, por el defecto
  de §8.
- Se adoptó desde ya la convención de cabecera `NÚCLEO`/`VERTICAL` de la Fase A7a en las
  migraciones nuevas: cuesta cero y evita reconstruirlo después.

## 10. Trabajo pendiente

- Nada de A1 queda abierto. La base viva está registrada y al día (28/28).
- Los archivos nuevos **no están en git todavía**: el commit lo hace la Fase A2, que
  versiona `079`, `081`–`083`, el worker de avisos y los reportes, con rutas explícitas
  (nunca `git add -A`: `opencode.json` tiene una credencial real y no está ignorado).
- `backups/antes-de-migrar-a1.dump` se puede borrar cuando el usuario lo considere.
