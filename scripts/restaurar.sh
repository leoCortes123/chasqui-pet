#!/usr/bin/env bash
# =============================================================================
# Chasqui Pet — Restauración de un respaldo
# -----------------------------------------------------------------------------
# USO:
#     bash scripts/restaurar.sh backups/chasquipet-chasquipet-20260730-023000.dump
#     bash scripts/restaurar.sh              (muestra los respaldos disponibles)
#
# (Si el repositorio está en un disco que conserva permisos, también funciona
#  como ./scripts/restaurar.sh tras un chmod +x.)
#
# ADVERTENCIA: la restauración BORRA los datos actuales de la base y los
# reemplaza por los del respaldo. Todo lo registrado después de la fecha del
# respaldo se pierde. El script pide confirmación escrita antes de tocar nada.
#
# Se ejecuta desde el equipo anfitrión, con los contenedores levantados.
# =============================================================================

set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$RAIZ"

SERVICIO_DB="db"
DIR_BACKUPS="$RAIZ/backups"

rojo()    { printf '\033[31m%s\033[0m\n' "$*"; }
amarillo(){ printf '\033[33m%s\033[0m\n' "$*"; }
verde()   { printf '\033[32m%s\033[0m\n' "$*"; }

# --- Comprobaciones previas ---------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    rojo "ERROR: no se encontró 'docker'. Instálelo o ejecute este script en el servidor de la clínica."
    exit 1
fi

if [[ ! -f "$RAIZ/.env" ]]; then
    rojo "ERROR: no existe el archivo .env en $RAIZ"
    echo "Cópielo desde .env.example y complete los valores."
    exit 1
fi

# Se leen las credenciales del .env sin exportarlas al entorno del script.
POSTGRES_USER="$(grep -E '^POSTGRES_USER=' "$RAIZ/.env" | tail -n1 | cut -d= -f2-)"
POSTGRES_DB="$(grep -E '^POSTGRES_DB=' "$RAIZ/.env" | tail -n1 | cut -d= -f2-)"
POSTGRES_USER="${POSTGRES_USER:-chasquipet}"
POSTGRES_DB="${POSTGRES_DB:-chasquipet}"

listar_respaldos() {
    echo "Respaldos disponibles en $DIR_BACKUPS:"
    echo
    if ! ls -1 "$DIR_BACKUPS"/*.dump >/dev/null 2>&1; then
        amarillo "  (no hay ningún respaldo todavía)"
        return
    fi
    ls -lht "$DIR_BACKUPS"/*.dump | awk '{printf "  %-52s %8s  %s %s %s\n", $9, $5, $6, $7, $8}'
}

# --- Argumento ----------------------------------------------------------------
if [[ $# -lt 1 ]]; then
    listar_respaldos
    echo
    echo "Uso: $0 <ruta-del-respaldo.dump>"
    exit 1
fi

ARCHIVO="$1"
if [[ ! -f "$ARCHIVO" ]]; then
    # Se permite pasar solo el nombre del archivo.
    if [[ -f "$DIR_BACKUPS/$ARCHIVO" ]]; then
        ARCHIVO="$DIR_BACKUPS/$ARCHIVO"
    else
        rojo "ERROR: no existe el archivo '$ARCHIVO'."
        echo
        listar_respaldos
        exit 1
    fi
fi

ARCHIVO="$(cd "$(dirname "$ARCHIVO")" && pwd)/$(basename "$ARCHIVO")"
NOMBRE="$(basename "$ARCHIVO")"
TAMANO="$(du -h "$ARCHIVO" | cut -f1)"
FECHA="$(date -r "$ARCHIVO" '+%Y-%m-%d %H:%M:%S')"

# --- Confirmación interactiva --------------------------------------------------
echo
amarillo "==============================================================="
amarillo "  RESTAURACIÓN DE LA BASE DE DATOS DE CHASQUI PET"
amarillo "==============================================================="
echo
echo "  Respaldo:       $NOMBRE"
echo "  Tamaño:         $TAMANO"
echo "  Fecha archivo:  $FECHA"
echo "  Base destino:   $POSTGRES_DB (contenedor '$SERVICIO_DB')"
echo
rojo "  Esto BORRA todos los datos actuales de la base '$POSTGRES_DB'"
rojo "  y los reemplaza por los del respaldo. La operación NO se puede"
rojo "  deshacer. Todo lo registrado después del respaldo se pierde:"
rojo "  turnos, consultas, movimientos de inventario, pagos y caja."
echo
echo "  Para continuar escriba exactamente:  RESTAURAR"
echo "  Cualquier otra cosa cancela."
echo
read -r -p "  > " CONFIRMACION

if [[ "$CONFIRMACION" != "RESTAURAR" ]]; then
    echo
    verde "Cancelado. No se modificó nada."
    exit 0
fi

# --- Respaldo de seguridad previo ----------------------------------------------
echo
echo "Verificando que la base esté disponible..."
if ! docker compose exec -T "$SERVICIO_DB" pg_isready -U "$POSTGRES_USER" -q; then
    rojo "ERROR: la base de datos no responde. Levante los servicios con 'docker compose up -d db'."
    exit 1
fi

PREVIO="$DIR_BACKUPS/pre-restauracion-$(date '+%Y%m%d-%H%M%S').dump"
echo "Guardando el estado actual antes de restaurar en:"
echo "  $PREVIO"
mkdir -p "$DIR_BACKUPS"
if docker compose exec -T "$SERVICIO_DB" \
        pg_dump -U "$POSTGRES_USER" -Fc --no-owner --no-privileges "$POSTGRES_DB" > "$PREVIO"; then
    verde "Estado actual guardado."
else
    rm -f "$PREVIO"
    amarillo "No se pudo guardar el estado actual (¿base vacía?). Se continúa."
fi

# --- Restauración ---------------------------------------------------------------
echo
echo "Cerrando conexiones abiertas a '$POSTGRES_DB'..."
docker compose exec -T "$SERVICIO_DB" psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$POSTGRES_DB' AND pid <> pg_backend_pid();" \
    >/dev/null

echo "Restaurando '$NOMBRE'..."
# --clean --if-exists elimina los objetos existentes antes de recrearlos.
# pg_restore reporta avisos benignos; solo un código de salida distinto de 0
# con errores reales debe detenernos, por eso se captura la salida.
set +e
docker compose exec -T "$SERVICIO_DB" \
    pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
        --clean --if-exists --no-owner --no-privileges --exit-on-error < "$ARCHIVO"
CODIGO=$?
set -e

echo
if [[ $CODIGO -eq 0 ]]; then
    verde "==============================================================="
    verde "  Restauración completada correctamente."
    verde "==============================================================="
    echo
    echo "Reinicie los servicios que dependen de la base:"
    echo "  docker compose restart worker web n8n"
else
    rojo "==============================================================="
    rojo "  La restauración terminó con errores (código $CODIGO)."
    rojo "==============================================================="
    echo
    echo "El estado anterior quedó guardado en:"
    echo "  $PREVIO"
    echo "Para volver atrás ejecute:"
    echo "  $0 $PREVIO"
    exit "$CODIGO"
fi
