#!/usr/bin/env bash
# =====================================================================
# Chasqui Pet — cargar-demo.sh
# Carga un día de operación simulado para la presentación al cliente.
#
# Uso:   bash scripts/cargar-demo.sh
#
# ATENCIÓN: borra los datos de demostración anteriores, incluidos TODOS
# los turnos del día en curso y el personal de prueba. No toca la sede,
# los consultorios, los tipos de servicio, los roles, los permisos, la
# configuración ni el superadministrador real.
#
# No ejecute este script sobre una base con datos reales de la clínica.
# =====================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  echo "No existe el archivo .env. Cópielo desde .env.example y complételo." >&2
  exit 1
fi

set -a; . ./.env; set +a

psql_demo() {
  docker compose exec -T db psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
    -v ON_ERROR_STOP=1 "$@"
}

# `docker compose exec -T` consume TODA la entrada estándar. Sin este
# </dev/null, la comprobación se traga la respuesta del usuario y el `read`
# de más abajo se queda sin nada que leer.
if ! psql_demo -tAc 'SELECT 1' </dev/null >/dev/null 2>&1; then
  echo "No se pudo conectar a la base. ¿Está levantada? Pruebe: docker compose up -d db" >&2
  exit 1
fi

echo "==================================================================="
echo " Carga de datos de demostración"
echo "==================================================================="
echo
echo " Esto BORRA los turnos de hoy y el personal de prueba anterior."
echo " Los datos reales de la clínica se perderían."
echo
printf " Escriba CARGAR para continuar: "
read -r confirmacion
if [ "$confirmacion" != "CARGAR" ]; then
  echo "Cancelado. No se modificó nada."
  exit 0
fi

echo
for archivo in db/demo/*.sql; do
  [ -e "$archivo" ] || { echo "No hay archivos en db/demo/."; exit 1; }
  echo "==> $(basename "$archivo")"
  psql_demo -q < "$archivo"
done

echo
echo "==> Resumen de la jornada cargada"
psql_demo <<'SQL'
SELECT estado, count(*) AS turnos
  FROM turno
 WHERE fecha = hoy_bogota()
 GROUP BY estado
 ORDER BY turnos DESC;

SELECT count(*) AS personal_de_demo
  FROM usuario
 WHERE telegram_user_id BETWEEN 900000000 AND 900000099;

SELECT estado,
       count(*)          AS cuentas,
       pesos(sum(total)) AS valor
  FROM cuenta
 WHERE fecha = hoy_bogota()
 GROUP BY estado
 ORDER BY cuentas DESC;

SELECT estado,
       count(*)                AS entradas,
       pesos(sum(valor_total)) AS valor
  FROM entrada_inventario
 GROUP BY estado
 ORDER BY entradas DESC;
SQL

sede=$(psql_demo -tAc "SELECT id FROM sede WHERE activa ORDER BY created_at LIMIT 1" </dev/null | tr -d '[:space:]')

echo "==================================================================="
echo " Todo listo para la demostración"
echo "==================================================================="
echo
echo " Pantalla de sala de espera (ábrala en pantalla completa):"
echo "   ${WEB_PUBLIC_URL:-http://localhost:3000}/pantalla/${sede}"
echo
echo " Enlace del QR de la entrada:"
echo "   https://t.me/${TELEGRAM_BOT_USERNAME:-su_bot}?start=turno-${sede}"
echo
echo " Recuerde: el personal de demostración tiene ids de Telegram falsos"
echo " (rango 900000001 en adelante), así que no puede entrar al bot de"
echo " verdad. Para operar el bot en vivo use su propio usuario:"
echo "   bash scripts/crear-superadmin.sh"
echo
