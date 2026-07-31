#!/usr/bin/env bash
# =====================================================================
# Chasqui Pet — importar-n8n.sh
# Carga en n8n la credencial de Postgres y los workflows versionados
# del repositorio, y los deja activos.
#
# Uso:   bash scripts/importar-n8n.sh
#
# Es idempotente: volver a ejecutarlo actualiza los workflows con lo que
# haya en n8n/workflows/. Ejecútelo después de cada cambio en esos JSON.
# =====================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  echo "No existe el archivo .env. Cópielo desde .env.example y complételo." >&2
  exit 1
fi

set -a; . ./.env; set +a

# La contraseña nunca se escribe en el repositorio: la credencial se arma
# en un archivo temporal dentro del contenedor y se borra al terminar.
TMP_REMOTO="/tmp/chasquipet-credencial.json"

echo "==> Creando la credencial de Postgres en n8n"
docker compose exec -T n8n sh -c "cat > ${TMP_REMOTO}" <<JSON
[
  {
    "id": "chasquipet-postgres",
    "name": "Chasqui Pet Postgres",
    "type": "postgres",
    "data": {
      "host": "db",
      "port": 5432,
      "database": "${POSTGRES_DB}",
      "user": "chasquipet_app",
      "password": "${APP_DB_PASSWORD}",
      "ssl": "disable",
      "allowUnauthorizedCerts": false,
      "maxQueryExecutionTime": 10000
    }
  }
]
JSON

docker compose exec -T n8n n8n import:credentials --input="${TMP_REMOTO}"
docker compose exec -T n8n rm -f "${TMP_REMOTO}"

echo "==> Importando los workflows"
docker compose exec -T n8n n8n import:workflow --separate --input=/workflows

echo "==> Publicando los workflows"
# `update:workflow --all --active=true` quedó obsoleto: ahora se publica uno
# a uno por id. Los ids salen del propio n8n, no del JSON.
for id in $(docker compose exec -T n8n n8n list:workflow --onlyId | tr -d '\r'); do
  docker compose exec -T n8n n8n publish:workflow --id="$id" >/dev/null
  echo "    publicado ${id}"
done

echo "==> Reiniciando n8n para que tome los webhooks y los cron"
docker compose restart n8n >/dev/null

echo
echo "Workflows cargados:"
docker compose exec -T n8n n8n list:workflow

echo
echo "Siguiente paso: bash scripts/configurar-bot.sh"
