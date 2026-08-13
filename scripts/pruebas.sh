#!/usr/bin/env bash
# =====================================================================
# Chasqui Pet — pruebas.sh
# Batería de invariantes del núcleo (Fase A4 del plan de consolidación).
#
# Uso:
#   bash scripts/pruebas.sh                 Todas las pruebas.
#   bash scripts/pruebas.sh 030             Solo las que empiezan por 030.
#   bash scripts/pruebas.sh --conservar     No derriba el contenedor al terminar
#                                           (para inspeccionar con psql).
#
# Cómo funciona: levanta una base **desde cero** con `db/migrations/`, le
# carga el andamio de `db/pruebas/000_arnes.sql` y corre cada archivo de
# prueba con pgTAP. Cada archivo vive dentro de una transacción que
# termina en ROLLBACK, así que las pruebas no se contaminan entre sí.
#
# No toca la base de trabajo ni ningún contenedor de docker-compose: el
# contenedor de pruebas es aparte, sin puertos publicados, y se destruye
# al terminar.
#
# Efecto secundario buscado: como la base se construye desde las
# migraciones, cada corrida también verifica que una instalación limpia
# sigue funcionando.
# =====================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

IMAGEN="chasquipet-pruebas"
CONTENEDOR="chasquipet-pruebas"
CONSERVAR=0
FILTRO=""

for arg in "$@"; do
  case "$arg" in
    --conservar) CONSERVAR=1 ;;
    -*) echo "Opción no reconocida: $arg" >&2; exit 1 ;;
    *)  FILTRO="$arg" ;;
  esac
done

limpiar() {
  if [ "$CONSERVAR" -eq 0 ]; then
    docker rm -f "$CONTENEDOR" >/dev/null 2>&1 || true
  else
    echo
    echo "Contenedor conservado. Para mirarlo:"
    echo "  docker exec -it ${CONTENEDOR} psql -U chasquipet -d chasquipet"
    echo "  docker rm -f ${CONTENEDOR}   # cuando termine"
  fi
}
trap limpiar EXIT

echo "==> Imagen de pruebas (postgres 16 + pgTAP)"
docker build -q -t "$IMAGEN" db/pruebas/ >/dev/null

echo "==> Base limpia desde db/migrations/"
docker rm -f "$CONTENEDOR" >/dev/null 2>&1 || true
docker run -d --name "$CONTENEDOR" \
  -e POSTGRES_USER=chasquipet -e POSTGRES_PASSWORD=pruebas -e POSTGRES_DB=chasquipet \
  -e N8N_DB_NAME=n8n -e N8N_DB_USER=n8n -e N8N_DB_PASSWORD=pruebas \
  -e APP_DB_PASSWORD=pruebas -e READONLY_DB_PASSWORD=pruebas \
  -e SUPERADMIN_TELEGRAM_USER_ID=1 -e SUPERADMIN_NOMBRE='Superadmin de pruebas' \
  -e TZ=America/Bogota \
  -v "$PWD/db/migrations:/docker-entrypoint-initdb.d:ro" \
  "$IMAGEN" >/dev/null

# El healthcheck de pg_isready responde antes de que initdb termine de
# correr los scripts, así que además se espera la señal que deja el
# último de ellos (910_registrar_versiones.sh).
listo=0
for _ in $(seq 1 90); do
  if docker logs "$CONTENEDOR" 2>&1 | grep -q 'Registro de versiones sembrado'; then
    listo=1; break
  fi
  if docker logs "$CONTENEDOR" 2>&1 | grep -qE '^psql:.*ERROR'; then
    echo "La instalación limpia falló:" >&2
    docker logs "$CONTENEDOR" 2>&1 | grep -E '^psql:.*ERROR' | head -5 >&2
    exit 1
  fi
  sleep 1
done
if [ "$listo" -eq 0 ]; then
  echo "La base de pruebas no terminó de inicializarse a tiempo." >&2
  docker logs "$CONTENEDOR" 2>&1 | tail -20 >&2
  exit 1
fi

# Terminado initdb, el entrypoint apaga el servidor temporal y lo vuelve a
# levantar. Conectarse en esa ventana falla con «the database system is
# shutting down», así que se espera al arranque definitivo.
arriba=0
for _ in $(seq 1 60); do
  if docker logs "$CONTENEDOR" 2>&1 | grep -q 'PostgreSQL init process complete' \
     && docker exec "$CONTENEDOR" pg_isready -U chasquipet -d chasquipet >/dev/null 2>&1; then
    arriba=1; break
  fi
  sleep 1
done
if [ "$arriba" -eq 0 ]; then
  echo "La base de pruebas quedó inicializada pero no volvió a aceptar conexiones." >&2
  docker logs "$CONTENEDOR" 2>&1 | tail -20 >&2
  exit 1
fi

psql_pruebas() {
  docker exec -i "$CONTENEDOR" psql -U chasquipet -d chasquipet "$@"
}

echo "==> Andamio (pgTAP y constructores de datos)"
psql_pruebas -v ON_ERROR_STOP=1 -q < db/pruebas/000_arnes.sql

echo
fallos=0
archivos=0
for archivo in db/pruebas/[0-9]*.sql; do
  nombre="$(basename "$archivo")"
  case "$nombre" in 000_*) continue ;; esac
  if [ -n "$FILTRO" ] && [[ "$nombre" != "$FILTRO"* ]]; then continue ;fi

  archivos=$((archivos + 1))
  salida="$(psql_pruebas -Atq < "$archivo" 2>&1)"
  malos="$(printf '%s\n' "$salida" | grep -c '^not ok' || true)"
  buenos="$(printf '%s\n' "$salida" | grep -c '^ok ' || true)"

  if [ "$malos" -eq 0 ] && [ "$buenos" -gt 0 ]; then
    printf '  %-32s %s pruebas ✔\n' "$nombre" "$buenos"
  else
    fallos=$((fallos + malos))
    printf '  %-32s %s ✔  %s ✘\n' "$nombre" "$buenos" "$malos"
    printf '%s\n' "$salida" | grep -vE '^ok |^1\.\.' | sed 's/^/      /'
    # Sin ninguna prueba corrida, algo se rompió antes de empezar.
    if [ "$buenos" -eq 0 ]; then fallos=$((fallos + 1)); fi
  fi
done

echo
if [ "$archivos" -eq 0 ]; then
  echo "No se encontró ningún archivo de prueba${FILTRO:+ que empiece por $FILTRO}." >&2
  exit 1
fi
if [ "$fallos" -gt 0 ]; then
  echo "FALLARON ${fallos} prueba(s)."
  exit 1
fi
echo "Todo en verde: ${archivos} archivos de prueba."
