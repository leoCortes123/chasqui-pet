#!/bin/sh
# =====================================================================
# Chasqui Pet — registrar-publico.sh
#
# Mantiene al día la URL pública del sistema. Corre como un servicio, no
# como un comando que alguien recuerda ejecutar.
#
# Un quick tunnel de Cloudflare cambia de dirección en cada arranque, y de
# esa dirección dependen dos cosas que si no quedan mudas:
#   · el webhook de Telegram, que es por donde entra todo el bot;
#   · `config.portal_url`, con la que el bot arma el enlace de ingreso al
#     portal (`077_portal_enlace.sql`).
#
# Este contenedor es el único que sabe cómo se llama el túnel hoy, así que
# es el que le avisa a los dos. Con WEBHOOK_URL fija (dominio propio) no
# descubre nada: usa esa y se comporta igual.
# =====================================================================
set -eu

command -v curl >/dev/null 2>&1 || apk add --no-cache curl >/dev/null 2>&1
command -v psql >/dev/null 2>&1 || apk add --no-cache postgresql-client >/dev/null 2>&1

: "${TELEGRAM_BOT_TOKEN:?falta TELEGRAM_BOT_TOKEN}"
RUTA="${TELEGRAM_WEBHOOK_PATH:-chasquipet-telegram}"
ESPERA="${REGISTRADOR_INTERVALO_SEG:-60}"

descubrir_url() {
  # Con una URL fija no hay nada que descubrir.
  if [ -n "${WEBHOOK_URL:-}" ]; then
    echo "$WEBHOOK_URL"
    return 0
  fi
  # cloudflared publica el hostname del quick tunnel en su puerto de métricas.
  host=$(curl -sf --max-time 5 http://cloudflared:2000/quicktunnel 2>/dev/null \
         | sed -n 's/.*"hostname"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  [ -n "$host" ] && echo "https://$host"
}

anterior=''

while true; do
  base=$(descubrir_url || true)

  if [ -z "$base" ]; then
    echo "[registrador] sin URL todavía (¿cloudflared arrancando?), reintento en 10s"
    sleep 10
    continue
  fi

  if [ "$base" != "$anterior" ]; then
    destino="${base%/}/webhook/$RUTA"
    echo "[registrador] registrando $destino"

    respuesta=$(curl -sf --max-time 15 \
      -d "url=$destino" \
      -d 'allowed_updates=["message","callback_query"]' \
      -d "drop_pending_updates=true" \
      "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/setWebhook" 2>&1) || respuesta='fallo de red'

    case "$respuesta" in
      *'"ok":true'*)
        echo "[registrador] webhook ok"
        anterior="$base"
        ;;
      *)
        echo "[registrador] ERROR: $respuesta"
        ;;
    esac
  fi

  # La misma URL es la del portal: el proxy manda /webhook a n8n y todo lo
  # demás a la web, así que sale por el mismo hostname.
  #
  # Esto va FUERA del bloque de arriba, en cada vuelta: si la base todavía no
  # estaba lista en el momento en que cambió el túnel, hacerlo una sola vez
  # dejaría el enlace de ingreso apuntando a una dirección muerta hasta el
  # siguiente reinicio. Con el UPDATE condicionado a `valor <> ...`, repetirlo
  # no escribe nada cuando ya está al día.
  escrito=$(psql -v ON_ERROR_STOP=1 -qtA \
    -c "UPDATE config SET valor = '${base%/}', updated_at = now()
         WHERE clave = 'portal_url' AND valor <> '${base%/}'
       RETURNING valor" 2>/dev/null) || escrito='__fallo__'

  case "$escrito" in
    __fallo__) echo "[registrador] aviso: no pude escribir portal_url (¿base arrancando?)" ;;
    '')        : ;;   # ya estaba al día
    *)         echo "[registrador] portal_url = $escrito" ;;
  esac

  sleep "$ESPERA"
done
