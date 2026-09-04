#!/usr/bin/env bash
# =====================================================================
# Chasqui Pet — simular.sh
# Banco de datos para pruebas de usuario: deja la base como una clínica
# a media jornada, con todo lo que hoy tiene el sistema (turnos,
# inventario, historia clínica, cobro, compras, agenda de citas,
# controles y remisiones) fechado en el DÍA EN CURSO.
#
# Uso:
#   bash scripts/simular.sh              # = dia
#   bash scripts/simular.sh dia          # regenera la jornada de hoy
#   bash scripts/simular.sh limpiar      # deja la base vacía de operación
#   bash scripts/simular.sh todo         # limpiar + dia
#   bash scripts/simular.sh estado       # qué hay cargado ahora mismo
#
#   --si   no preguntar (para encadenarlo en otro script)
#
# Por qué existe: los turnos y las citas son de hoy, así que una carga de
# ayer ya no sirve para probar nada. Este script se puede volver a correr
# cada mañana —o varias veces al día— y siempre deja la jornada anclada
# al momento en que se ejecuta.
#
# Qué corre, en orden:
#   db/demo/*.sql          MVP: turnos, inventario, clínica, cobro, compras
#   db/simulacion/1*.sql   bloque B: agenda, controles, remisiones, canales
#
# ATENCIÓN: es un banco de pruebas, no una herramienta de operación.
# `dia` rehace los datos de simulación y `limpiar` borra TODA la
# operación de la base, incluida la auditoría. No lo ejecute sobre datos
# reales de la clínica.
# =====================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  echo "No existe el archivo .env. Cópielo desde .env.example y complételo." >&2
  exit 1
fi

set -a; . ./.env; set +a

# `docker compose exec -T` se traga toda la entrada estándar; sin el
# </dev/null los `read` de más abajo se quedarían sin nada que leer.
psql_sim() {
  docker compose exec -T db psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
    -v ON_ERROR_STOP=1 "$@"
}

comando="${1:-dia}"
sin_preguntar=0
for arg in "$@"; do
  [ "$arg" = "--si" ] && sin_preguntar=1
done

if ! psql_sim -tAc 'SELECT 1' </dev/null >/dev/null 2>&1; then
  echo "No se pudo conectar a la base. ¿Está levantada? Pruebe: docker compose up -d db" >&2
  exit 1
fi

confirmar() {  # $1 = palabra que hay que escribir, $2 = advertencia
  [ "$sin_preguntar" = "1" ] && return 0
  echo
  echo "  $2"
  echo
  printf "  Escriba %s para continuar: " "$1"
  read -r respuesta
  if [ "$respuesta" != "$1" ]; then
    echo "Cancelado. No se modificó nada."
    exit 0
  fi
  echo
}

correr() {  # $1 = archivo .sql
  echo "==> $(basename "$1")"
  psql_sim -q < "$1"
}

resumen() {
  psql_sim <<'SQL'
\pset border 2
SELECT 'turnos de hoy'        AS dato, count(*)::text AS valor FROM turno WHERE fecha = hoy_bogota()
UNION ALL SELECT '  · en espera',       count(*)::text FROM turno WHERE fecha = hoy_bogota() AND estado = 'en_espera'
UNION ALL SELECT '  · atendidos',       count(*)::text FROM turno WHERE fecha = hoy_bogota() AND estado = 'finalizado'
UNION ALL SELECT 'pacientes',           count(*)::text FROM paciente
UNION ALL SELECT 'consultas firmadas',  count(*)::text FROM consulta WHERE estado = 'firmada'
UNION ALL SELECT 'consultas en borrador', count(*)::text FROM consulta WHERE estado = 'borrador'
UNION ALL SELECT 'citas de hoy',        count(*)::text FROM cita WHERE inicio_at::date = hoy_bogota()
UNION ALL SELECT 'citas por venir',     count(*)::text FROM cita WHERE inicio_at > now() AND estado IN ('programada','confirmada')
UNION ALL SELECT '  · sin recordatorio', count(*)::text FROM cita WHERE inicio_at > now() AND estado IN ('programada','confirmada') AND recordatorio_enviado_at IS NULL
UNION ALL SELECT 'franjas de agenda',   count(*)::text FROM disponibilidad WHERE activo
UNION ALL SELECT 'controles pendientes', count(*)::text FROM consulta WHERE estado = 'firmada' AND proxima_revision IS NOT NULL
UNION ALL SELECT '  · vencidos',        count(*)::text FROM consulta WHERE estado = 'firmada' AND proxima_revision < hoy_bogota()
UNION ALL SELECT 'remisiones pendientes', count(*)::text FROM remision WHERE estado = 'pendiente'
UNION ALL SELECT '  · vencidas',        count(*)::text FROM remision WHERE estado = 'pendiente' AND fecha_esperada < hoy_bogota()
UNION ALL SELECT 'cuentas abiertas',    count(*)::text FROM cuenta WHERE estado = 'abierta'
UNION ALL SELECT 'cobrado hoy',         pesos(COALESCE(sum(valor), 0)) FROM pago WHERE created_at::date = hoy_bogota()
UNION ALL SELECT 'medicamentos',        count(*)::text FROM medicamento
UNION ALL SELECT 'tareas pendientes',   count(*)::text FROM tarea_async WHERE estado IN ('pendiente','procesando')
UNION ALL SELECT 'tareas fallidas',     count(*)::text FROM tarea_async WHERE estado = 'fallida';
SQL
}

case "$comando" in
  estado)
    resumen
    ;;

  limpiar)
    confirmar LIMPIAR \
      "Esto BORRA toda la operación de la base: turnos, historia clínica, citas,
  remisiones, inventario, caja y auditoría. Sólo quedan la sede, los
  catálogos, la configuración y el personal real."
    correr db/simulacion/000_limpiar.sql
    echo
    echo "Base limpia."
    ;;

  dia|todo)
    if [ "$comando" = "todo" ]; then
      confirmar LIMPIAR \
        "Esto BORRA toda la operación de la base y después carga una jornada nueva."
      correr db/simulacion/000_limpiar.sql
      echo
    else
      confirmar SIMULAR \
        "Esto rehace los datos de simulación: los turnos de hoy, el personal de
  prueba, sus pacientes y todo lo que cuelga de ellos se borran y se
  vuelven a generar con la hora actual."
    fi

    # Antes de db/demo: soltar remisiones y citas, que apuntan a las
    # consultas que db/demo/010 está a punto de borrar y las bloquearían.
    correr db/simulacion/005_soltar.sql

    for archivo in db/demo/*.sql; do
      [ -e "$archivo" ] || { echo "No hay archivos en db/demo/." >&2; exit 1; }
      correr "$archivo"
    done

    # 000_limpiar.sql se salta a propósito: aquí sólo van los generadores.
    for archivo in db/simulacion/[1-9]*.sql; do
      [ -e "$archivo" ] || break
      correr "$archivo"
    done

    echo
    echo "==> Jornada simulada del $(date +%d/%m/%Y)"
    resumen

    sede=$(psql_sim -tAc "SELECT id FROM sede WHERE activa ORDER BY created_at LIMIT 1" </dev/null | tr -d '[:space:]')

    cat <<FIN

===================================================================
 Listo para probar
===================================================================

 Portal:            ${WEB_PUBLIC_URL:-http://localhost:3100}
 Pantalla de sala:  ${WEB_PUBLIC_URL:-http://localhost:3100}/pantalla/${sede}
 QR de la entrada:  https://t.me/${TELEGRAM_BOT_USERNAME:-su_bot}?start=turno-${sede}

 El personal de simulación tiene ids de Telegram falsos (900000001 en
 adelante): sirve para que las pantallas muestren nombres, pero no puede
 entrar al bot. Para operar en vivo use su propio usuario:
   bash scripts/crear-superadmin.sh

 Los avisos a dueños salen sólo hacia el chat real que encontró
 db/simulacion/130_canales.sql; el resto de los dueños quedó sin canal a
 propósito, para no llenar la cola de tareas fallidas.

FIN
    ;;

  -h|--help|ayuda)
    sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'
    ;;

  *)
    echo "Comando desconocido: $comando" >&2
    echo "Use: dia | limpiar | todo | estado   (añada --si para no preguntar)" >&2
    exit 1
    ;;
esac
