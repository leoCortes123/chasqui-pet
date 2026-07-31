#!/bin/sh
# =====================================================================
# Chasqui Pet — 900_superadmin.sh
# Último paso de la inicialización: crea el superadmin y fija la
# contraseña de los roles de aplicación desde variables de entorno.
#
# Se ejecuta con "source" por el entrypoint de Postgres (el repositorio
# vive en NTFS y no admite el bit de ejecución), así que todo el cuerpo
# va dentro de una función que corre en un subshell.
# =====================================================================

chasquipet_seed_superadmin() (
  set -eu

  psql_run() {
    psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" "$@"
  }

  # --- Contraseñas de los roles de aplicación --------------------------
  if [ -n "${APP_DB_PASSWORD:-}" ]; then
    psql_run -c "ALTER ROLE chasquipet_app PASSWORD '${APP_DB_PASSWORD}'"
    echo "[chasquipet] Contraseña del rol chasquipet_app configurada."
  else
    echo "[chasquipet] AVISO: APP_DB_PASSWORD sin definir; chasquipet_app no podrá conectarse."
  fi

  if [ -n "${READONLY_DB_PASSWORD:-}" ]; then
    psql_run -c "ALTER ROLE chasquipet_lectura PASSWORD '${READONLY_DB_PASSWORD}'"
  fi

  # --- Superadmin inicial ---------------------------------------------
  tid="${SUPERADMIN_TELEGRAM_USER_ID:-}"
  nombre="${SUPERADMIN_NOMBRE:-Superadministrador}"

  case "$tid" in
    ''|*[!0-9]*)
      echo "[chasquipet] AVISO: SUPERADMIN_TELEGRAM_USER_ID vacío o no numérico."
      echo "[chasquipet] Ningún usuario tiene acceso todavía. Consíguelo con @userinfobot,"
      echo "[chasquipet] ponlo en .env y ejecuta: bash scripts/crear-superadmin.sh"
      return 0
      ;;
  esac

  psql_run -c "SELECT crear_superadmin_inicial(${tid}::bigint, \$\$${nombre}\$\$)" >/dev/null
  echo "[chasquipet] Superadmin creado para el Telegram user id ${tid} (${nombre})."
)

chasquipet_seed_superadmin
