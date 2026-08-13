#!/usr/bin/env bash
# =====================================================================
# Chasqui Pet — migrar.sh
# Aplica a una base YA INICIALIZADA las migraciones de db/migrations que
# todavía no están registradas en `schema_version` (Fase A1 del plan de
# consolidación).
#
# Contexto: la imagen de Postgres solo ejecuta /docker-entrypoint-initdb.d
# cuando el volumen está vacío. En una base viva, una migración nueva no
# se aplica sola. Este script es el único camino previsto para aplicarla.
#
# Uso:
#   bash scripts/migrar.sh --estado        Solo informa: qué falta, qué sobra.
#   bash scripts/migrar.sh                 Aplica las pendientes, en orden.
#   bash scripts/migrar.sh --retro-registrar
#                                          Marca como aplicadas las migraciones
#                                          que YA corrieron en esta base, sin
#                                          ejecutarlas. Es el arranque del
#                                          registro en una base preexistente.
#
# Reglas que respeta:
#   · Orden alfabético estricto, el mismo de initdb.
#   · Cada migración se aplica dentro de UNA transacción junto con su
#     registro: o quedan las dos cosas, o no queda ninguna.
#   · Si un archivo ya aplicado cambió de contenido (hash distinto), se
#     detiene. Las migraciones aplicadas no se editan; se crea una nueva.
#   · Usa ADMIN_DATABASE_URL (el dueño de la base), nunca el rol de la
#     aplicación. La URL nunca se imprime.
# =====================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  echo "No existe el archivo .env. Cópielo desde .env.example y complételo." >&2
  exit 1
fi

set -a; . ./.env; set +a

if [ -z "${ADMIN_DATABASE_URL:-}" ]; then
  echo "Falta ADMIN_DATABASE_URL en .env: el migrador necesita conectarse como dueño de la base." >&2
  exit 1
fi

MODO="aplicar"
case "${1:-}" in
  --estado)           MODO="estado" ;;
  --retro-registrar)  MODO="retro" ;;
  "")                 ;;
  *)
    echo "Opción no reconocida: $1" >&2
    echo "Uso: bash scripts/migrar.sh [--estado | --retro-registrar]" >&2
    exit 1
    ;;
esac

# La URL apunta al host 'db', que solo resuelve dentro de la red de compose:
# por eso psql corre dentro del contenedor. La URL viaja por el entorno del
# proceso, no por la línea de comandos, para que no aparezca en `ps`.
# psql dentro del contenedor, leyendo la URL desde el entorno del contenedor.
en_db() {
  docker compose exec -T -e MIGRAR_URL="${ADMIN_DATABASE_URL}" db \
    sh -c 'exec psql "$MIGRAR_URL" -v ON_ERROR_STOP=1 "$@"' sh "$@"
}

# `docker compose exec -T` consume la entrada estándar del script. Las
# consultas no la necesitan, y si la dejan abierta se tragan lo que el
# usuario escribe en la confirmación del retro-registro: por eso van con
# la entrada cerrada. La única que sí la usa es aplicar_archivo(), que le
# pasa el .sql por una tubería.
consulta() {  # devuelve un valor escalar
  en_db -At -c "$1" </dev/null
}

# --- El registro tiene que existir antes de poder consultarlo ---------
# La propia tabla llega en una migración (120_schema_version.sql), así que
# hay un arranque en frío: si no existe, se aplica ese archivo primero.
ARCHIVO_REGISTRO="$(ls db/migrations/*_schema_version.sql | head -n 1)"

aplicar_archivo() {  # $1 = ruta, $2 = origen a registrar
  local ruta="$1" origen="$2"
  local nombre version hash
  nombre="$(basename "$ruta")"
  version="$(printf '%s' "$nombre" | cut -c1-3)"
  hash="$(sha256sum "$ruta" | cut -d' ' -f1)"

  # El archivo y su registro entran en la MISMA transacción: si la
  # migración falla a la mitad, no queda anotada como aplicada.
  {
    echo "BEGIN;"
    cat "$ruta"
    echo ";"
    echo "SELECT registrar_version('${version}', '${nombre}', '${hash}', '${origen}');"
    echo "COMMIT;"
  } | en_db -q -f - >/dev/null
}

registrar_sin_aplicar() {  # $1 = ruta
  local ruta="$1" nombre version hash
  nombre="$(basename "$ruta")"
  version="$(printf '%s' "$nombre" | cut -c1-3)"
  hash="$(sha256sum "$ruta" | cut -d' ' -f1)"
  en_db -At -c "SELECT registrar_version('${version}', '${nombre}', '${hash}', 'retro')" </dev/null >/dev/null
}

estado_de() {  # $1 = ruta → pendiente | aplicada | modificada
  local ruta="$1" version hash
  version="$(printf '%s' "$(basename "$ruta")" | cut -c1-3)"
  hash="$(sha256sum "$ruta" | cut -d' ' -f1)"
  consulta "SELECT schema_version_estado('${version}', '${hash}')"
}

HAY_REGISTRO="$(consulta "SELECT (to_regclass('public.schema_version') IS NOT NULL)::text")"
BASE_CON_DATOS="$(consulta "SELECT (to_regclass('public.usuario') IS NOT NULL)::text")"

if [ "$HAY_REGISTRO" != "true" ]; then
  if [ "$MODO" = "estado" ]; then
    echo "La tabla schema_version todavía no existe en esta base."
    if [ "$BASE_CON_DATOS" = "true" ]; then
      echo "La base ya tiene esquema: empiece con  bash scripts/migrar.sh --retro-registrar"
    else
      echo "Base vacía: ejecute  bash scripts/migrar.sh"
    fi
    exit 0
  fi
  echo "==> Creando el registro de versiones ($(basename "$ARCHIVO_REGISTRO"))"
  aplicar_archivo "$ARCHIVO_REGISTRO" "migrar"
fi

# --- Red de seguridad: base con esquema y registro casi vacío ---------
# Aplicar 010–110 sobre una base que ya los tiene sería, en el mejor caso,
# ruido; en el peor, un desastre. Si el registro está prácticamente vacío
# pero la base ya tiene esquema, el paso correcto es retro-registrar.
REGISTRADAS="$(consulta "SELECT count(*) FROM schema_version")"
if [ "$MODO" = "aplicar" ] && [ "$BASE_CON_DATOS" = "true" ] && [ "$REGISTRADAS" -le 1 ]; then
  echo "ALTO: esta base ya tiene esquema pero el registro de versiones está vacío." >&2
  echo "Aplicar las migraciones ahora las repetiría sobre datos reales." >&2
  echo "Primero: bash scripts/migrar.sh --retro-registrar" >&2
  exit 1
fi

# --- Convención de cabecera (Fase A7a) --------------------------------
# Cada migración declara en su cabecera si toca el NÚCLEO (identidad,
# permisos, auditoría, cola, config, inventario, cobro, compras, admin) o
# un VERTICAL (turnos veterinarios, pacientes, consulta clínica, agenda).
# Es una línea de texto, y es lo que evita tener que arqueologizar 25
# archivos el día que haya que separar el producto genérico del
# veterinario.
#
# Se exige aquí y no en las 26 migraciones anteriores a la convención:
# esas no se reescriben (una migración aplicada no se edita), y como solo
# pasan por esta reja las PENDIENTES, la regla vale hacia adelante sin
# tocar nada del pasado. Se exige, no se advierte: una convención que
# solo avisa se pierde el primer día con prisa.
ambito_declarado() {  # $1 = ruta
  head -n 20 "$1" | grep -qE '^--[[:space:]]*Ámbito:[[:space:]]*(NÚCLEO|VERTICAL)\b'
}

# --- Recorrido ---------------------------------------------------------
pendientes=0; aplicadas=0; modificadas=0; nuevas=0

if [ "$MODO" = "retro" ]; then
  echo "==> Retro-registro: se marcarán como aplicadas SIN ejecutarlas."
  echo "    Úselo solo si esta base ya tiene ese esquema. Haga respaldo antes."
  printf '    ¿Continuar? [escriba SI] '
  read -r respuesta
  if [ "$respuesta" != "SI" ]; then
    echo "Cancelado."
    exit 1
  fi
fi

# Pasada previa: si a alguna pendiente le falta el ámbito, no se aplica
# NINGUNA. Fallar a la mitad dejaría media tanda aplicada por un
# comentario, que es peor que no empezar.
if [ "$MODO" = "aplicar" ]; then
  sin_ambito=""
  for ruta in db/migrations/*.sql; do
    if [ "$(estado_de "$ruta")" = "pendiente" ] && ! ambito_declarado "$ruta"; then
      sin_ambito="${sin_ambito} $(basename "$ruta")"
    fi
  done
  if [ -n "$sin_ambito" ]; then
    echo "ALTO: hay migraciones pendientes sin declarar su ámbito en la cabecera:" >&2
    for n in $sin_ambito; do echo "  · $n" >&2; done
    echo >&2
    echo "Agregue una de estas dos líneas al comentario de cabecera (primeras 20 líneas):" >&2
    echo "  -- Ámbito: NÚCLEO   (identidad, permisos, auditoría, cola, config," >&2
    echo "  --                   inventario, cobro, compras, admin)" >&2
    echo "  -- Ámbito: VERTICAL (turnos veterinarios, pacientes, consulta clínica, agenda)" >&2
    exit 3
  fi
fi

for ruta in db/migrations/*.sql; do
  nombre="$(basename "$ruta")"
  estado="$(estado_de "$ruta")"

  case "$estado" in
    aplicada)
      aplicadas=$((aplicadas + 1))
      if [ "$MODO" = "estado" ]; then printf '  %-40s aplicada\n' "$nombre"; fi
      ;;
    modificada)
      modificadas=$((modificadas + 1))
      printf '  %-40s MODIFICADA DESPUÉS DE APLICARSE\n' "$nombre" >&2
      ;;
    pendiente)
      pendientes=$((pendientes + 1))
      case "$MODO" in
        estado)
          if ambito_declarado "$ruta"; then
            printf '  %-40s pendiente\n' "$nombre"
          else
            printf '  %-40s pendiente (SIN ÁMBITO EN LA CABECERA)\n' "$nombre"
          fi
          ;;
        retro)
          registrar_sin_aplicar "$ruta"
          nuevas=$((nuevas + 1))
          printf '  %-40s retro-registrada\n' "$nombre"
          ;;
        aplicar)
          printf '  %-40s aplicando... ' "$nombre"
          aplicar_archivo "$ruta" "migrar"
          nuevas=$((nuevas + 1))
          echo "ok"
          ;;
      esac
      ;;
  esac
done

if [ "$modificadas" -gt 0 ]; then
  echo >&2
  echo "Se detectaron ${modificadas} migración(es) ya aplicadas cuyo archivo cambió." >&2
  echo "Regla del proyecto: una migración aplicada no se edita; cree una nueva con el" >&2
  echo "siguiente prefijo libre y revierta el cambio en el archivo original." >&2
  exit 2
fi

echo
case "$MODO" in
  estado) echo "Total: ${aplicadas} aplicadas, ${pendientes} pendientes." ;;
  retro)  echo "Listo: ${nuevas} migraciones retro-registradas, ${aplicadas} ya estaban." ;;
  aplicar)
    if [ "$nuevas" -eq 0 ]; then
      echo "Nada que aplicar: la base está al día (${aplicadas} migraciones)."
    else
      echo "Listo: ${nuevas} migraciones aplicadas, ${aplicadas} ya estaban."
    fi
    ;;
esac
