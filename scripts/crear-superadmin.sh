#!/usr/bin/env bash
# =====================================================================
# Chasqui Pet — crear-superadmin.sh
# Crea (o repara) el superadministrador a partir de un id de Telegram.
#
# Uso:   bash scripts/crear-superadmin.sh [telegram_user_id] [nombre]
# Sin argumentos toma SUPERADMIN_TELEGRAM_USER_ID y SUPERADMIN_NOMBRE de .env
#
# ¿Cómo obtener el id de Telegram? Escríbale a @userinfobot desde la cuenta
# que va a administrar el sistema; responde con un número. Ese es el id.
# =====================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  echo "No existe el archivo .env. Cópielo desde .env.example y complételo." >&2
  exit 1
fi

set -a; . ./.env; set +a

TID="${1:-${SUPERADMIN_TELEGRAM_USER_ID:-}}"
NOMBRE="${2:-${SUPERADMIN_NOMBRE:-Superadministrador}}"

case "$TID" in
  ''|*[!0-9]*)
    echo "Debe indicar un id de Telegram numérico." >&2
    echo "  bash scripts/crear-superadmin.sh 123456789 'Leonardo'" >&2
    exit 1
    ;;
esac

echo "==> Creando superadministrador ${NOMBRE} (Telegram ${TID})"
docker compose exec -T db psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -v ON_ERROR_STOP=1 <<SQL
SELECT crear_superadmin_inicial(${TID}::bigint, \$\$${NOMBRE}\$\$);
SELECT u.nombre_completo, u.telegram_user_id,
       string_agg(ur.rol_codigo, ', ') AS roles
  FROM usuario u
  JOIN usuario_rol ur ON ur.usuario_id = u.id
 WHERE u.telegram_user_id = ${TID}
 GROUP BY 1, 2;
SQL

echo
echo "Listo. Escríbale /menu al bot desde esa cuenta de Telegram."
