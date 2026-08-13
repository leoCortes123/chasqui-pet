#!/bin/sh
# =====================================================================
# Chasqui Pet — 910_registrar_versiones.sh
# Ámbito: NÚCLEO.
#
# Último paso de la inicialización, después de 900_superadmin.sh:
# siembra `schema_version` con TODAS las migraciones .sql que el
# entrypoint acaba de aplicar.
#
# ¿Por qué hace falta? Porque hay dos caminos para poner el esquema en
# pie —volumen nuevo (initdb) y base viva (scripts/migrar.sh)— y si el
# primero no deja rastro, el segundo intentaría aplicar de nuevo los 25
# archivos sobre una base ya construida. Con este paso, los dos caminos
# terminan en el mismo estado: base creada + registro completo.
#
# Solo registra los .sql: son los que recorre scripts/migrar.sh. Los
# .sh de esta carpeta (000, 900 y este mismo) son parte del arranque del
# contenedor, no migraciones re-aplicables.
#
# Se ejecuta con "source" por el entrypoint de Postgres (el repositorio
# vive en NTFS y no admite el bit de ejecución), así que todo el cuerpo
# va dentro de una función que corre en un subshell.
# =====================================================================

chasquipet_registrar_versiones() (
  set -eu

  psql_run() {
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" "$@"
  }

  # Ruta fija a propósito: el entrypoint hace "source" de este archivo, así
  # que $0 es el shell del entrypoint y no sirve para deducir el directorio.
  dir="/docker-entrypoint-initdb.d"
  n=0

  for archivo in "$dir"/*.sql; do
    [ -f "$archivo" ] || continue
    nombre="$(basename "$archivo")"
    version="$(printf '%s' "$nombre" | cut -c1-3)"
    hash="$(sha256sum "$archivo" | cut -d' ' -f1)"

    psql_run -q -c "SELECT registrar_version('${version}', '${nombre}', '${hash}', 'initdb')" >/dev/null
    n=$((n + 1))
  done

  echo "[chasquipet] Registro de versiones sembrado: ${n} migraciones marcadas como aplicadas (origen initdb)."
)

chasquipet_registrar_versiones
