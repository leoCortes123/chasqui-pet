#!/bin/sh
# =============================================================================
# Chasqui Pet — Respaldo automático de la base de datos
# -----------------------------------------------------------------------------
# Este script es el punto de entrada del contenedor "backup". No se ejecuta a
# mano: el contenedor lo corre solo y se queda vivo esperando la próxima hora
# de respaldo.
#
# Qué hace, todos los días a la hora BACKUP_HORA (hora de Bogotá):
#   1. Genera un pg_dump en formato custom (-Fc), ya comprimido.
#   2. Le pone fecha y hora de Bogotá en el nombre.
#   3. Borra los respaldos de más de BACKUP_RETENCION_DIAS días.
#   4. Escribe todo lo que hace en la salida estándar, visible con:
#          docker compose logs -f backup
#
# Para restaurar un respaldo use scripts/restaurar.sh
# =============================================================================

set -eu

BACKUP_DIR="${BACKUP_DIR:-/backups}"
RETENCION_DIAS="${BACKUP_RETENCION_DIAS:-14}"
HORA_BACKUP="${BACKUP_HORA:-02:30}"
BASE="${PGDATABASE:-chasquipet}"

export TZ="${TZ:-America/Bogota}"
export PGTZ="${PGTZ:-$TZ}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S %Z')] $*"
}

# --- Validaciones de arranque -------------------------------------------------
if ! echo "$HORA_BACKUP" | grep -Eq '^[0-2][0-9]:[0-5][0-9]$'; then
    log "ERROR: BACKUP_HORA='$HORA_BACKUP' no tiene el formato HH:MM. Se usa 02:30."
    HORA_BACKUP="02:30"
fi

mkdir -p "$BACKUP_DIR"

# --- Segundos que faltan hasta la próxima ejecución ---------------------------
segundos_hasta_proxima() {
    ahora=$(date +%s)
    hoy=$(date '+%Y-%m-%d')
    # Formato completo con segundos: es el que entiende tanto el `date` de
    # BusyBox (imagen alpine) como el de GNU.
    objetivo=$(date -d "$hoy $HORA_BACKUP:00" +%s 2>/dev/null || echo "")

    if [ -z "$objetivo" ]; then
        # Sin `date -d` disponible, se cae a un ciclo fijo de 24 horas.
        echo 86400
        return
    fi

    if [ "$objetivo" -le "$ahora" ]; then
        objetivo=$((objetivo + 86400))
    fi
    echo $((objetivo - ahora))
}

# --- Un respaldo ---------------------------------------------------------------
hacer_respaldo() {
    marca=$(date '+%Y%m%d-%H%M%S')
    destino="$BACKUP_DIR/chasquipet-${BASE}-${marca}.dump"
    parcial="${destino}.parcial"

    log "Iniciando respaldo de la base '$BASE' hacia $destino"

    # -Fc = formato custom, ya viene comprimido y permite restauración selectiva.
    if pg_dump -Fc -Z 6 --no-owner --no-privileges -f "$parcial" "$BASE"; then
        mv "$parcial" "$destino"
        tamano=$(du -h "$destino" | cut -f1)
        log "Respaldo terminado correctamente: $(basename "$destino") ($tamano)"
    else
        rm -f "$parcial"
        log "ERROR: falló el respaldo de la base '$BASE'. Se descartó el archivo incompleto."
        return 1
    fi
}

# --- Retención -----------------------------------------------------------------
limpiar_antiguos() {
    log "Borrando respaldos de más de $RETENCION_DIAS días en $BACKUP_DIR"
    borrados=0
    # -mtime +N borra lo que tenga más de N días completos de antigüedad.
    for viejo in $(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'chasquipet-*.dump' -mtime "+$RETENCION_DIAS" 2>/dev/null); do
        rm -f "$viejo"
        log "  eliminado: $(basename "$viejo")"
        borrados=$((borrados + 1))
    done
    # Restos de respaldos interrumpidos
    find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.parcial' -mtime +1 -delete 2>/dev/null || true
    log "Limpieza terminada: $borrados archivo(s) eliminado(s)."
    log "Respaldos disponibles: $(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'chasquipet-*.dump' | wc -l | tr -d ' ')"
}

# --- Cierre ordenado -----------------------------------------------------------
terminar() {
    log "Servicio de respaldo detenido."
    exit 0
}
trap terminar TERM INT

# --- Bucle principal -----------------------------------------------------------
log "Servicio de respaldo iniciado."
log "  Base de datos:  $BASE en ${PGHOST:-db}:${PGPORT:-5432}"
log "  Carpeta:        $BACKUP_DIR"
log "  Hora diaria:    $HORA_BACKUP ($TZ)"
log "  Retención:      $RETENCION_DIAS días"

# Espera a que la base acepte conexiones antes de programar nada.
while ! pg_isready -q; do
    log "Esperando a que la base de datos esté disponible..."
    sleep 5
done

# Respaldo inmediato si hoy todavía no hay ninguno: evita quedarse un día entero
# sin copia tras un despliegue nuevo.
if [ -z "$(find "$BACKUP_DIR" -maxdepth 1 -type f -name "chasquipet-${BASE}-$(date '+%Y%m%d')-*.dump" 2>/dev/null)" ]; then
    log "No hay respaldo del día de hoy. Se genera uno ahora."
    hacer_respaldo || true
    limpiar_antiguos
fi

while true; do
    espera=$(segundos_hasta_proxima)
    log "Próximo respaldo en $((espera / 3600))h $(((espera % 3600) / 60))m (a las $HORA_BACKUP)."
    sleep "$espera" &
    wait $!
    hacer_respaldo || true
    limpiar_antiguos
done
