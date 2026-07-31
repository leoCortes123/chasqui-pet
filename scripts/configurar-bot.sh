#!/usr/bin/env bash
# =====================================================================
# Chasqui Pet — configurar-bot.sh
# Registra el webhook de Telegram contra n8n, fija los comandos del bot
# y muestra el enlace del QR de la sala de espera.
#
# Uso:   bash scripts/configurar-bot.sh
# =====================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  echo "No existe el archivo .env. Cópielo desde .env.example y complételo." >&2
  exit 1
fi

set -a; . ./.env; set +a

: "${TELEGRAM_BOT_TOKEN:?Falta TELEGRAM_BOT_TOKEN en .env}"
: "${WEBHOOK_URL:?Falta WEBHOOK_URL en .env}"

API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"
RUTA_WEBHOOK="${WEBHOOK_URL%/}/webhook/chasquipet-telegram"

echo "==> Verificando el token del bot"
respuesta=$(curl -sS "${API}/getMe")
if ! echo "$respuesta" | grep -q '"ok":true'; then
  echo "El token no es válido. Respuesta de Telegram:" >&2
  echo "$respuesta" >&2
  exit 1
fi
usuario_bot=$(echo "$respuesta" | sed -n 's/.*"username":"\([^"]*\)".*/\1/p')
echo "    Bot: @${usuario_bot}"

# Telegram exige HTTPS para los webhooks. En una demo local, WEBHOOK_URL suele
# ser http://localhost, que Telegram rechaza. En ese caso el bot funciona por
# sondeo (polling) desde n8n, o se expone n8n con un túnel (cloudflared, ngrok).
case "$RUTA_WEBHOOK" in
  https://*)
    echo "==> Registrando el webhook"
    echo "    ${RUTA_WEBHOOK}"
    curl -sS -X POST "${API}/setWebhook" \
      -d "url=${RUTA_WEBHOOK}" \
      -d "allowed_updates=[\"message\",\"callback_query\"]" \
      -d "drop_pending_updates=true" | sed 's/^/    /'
    echo
    ;;
  *)
    echo "==> AVISO: WEBHOOK_URL no es HTTPS (${RUTA_WEBHOOK})."
    echo "    Telegram sólo acepta webhooks HTTPS. Para la demo local, expón n8n"
    echo "    con un túnel y vuelve a ejecutar este script, por ejemplo:"
    echo "        cloudflared tunnel --url http://localhost:5678"
    echo "    Luego pon esa URL https en WEBHOOK_URL dentro de .env."
    ;;
esac

echo "==> Configurando los comandos del bot"
curl -sS -X POST "${API}/setMyCommands" \
  -H 'Content-Type: application/json' \
  -d '{"commands":[
        {"command":"menu","description":"Menú principal"},
        {"command":"cola","description":"Pacientes en espera"},
        {"command":"ayuda","description":"Ayuda"}
      ]}' | sed 's/^/    /'
echo

echo "==> Enlace para el código QR de la entrada"
sede=$(docker compose exec -T db psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -tAc \
        "SELECT id FROM sede WHERE activa ORDER BY created_at LIMIT 1" 2>/dev/null | tr -d '[:space:]' || true)

if [ -n "$sede" ]; then
  echo "    https://t.me/${usuario_bot}?start=turno-${sede}"
  echo
  echo "    Imprima ese enlace como código QR y péguelo en la entrada."
  echo "    Pantalla de sala de espera: ${WEB_PUBLIC_URL:-http://localhost:3000}/pantalla/${sede}"
else
  echo "    No se pudo consultar la sede (¿está levantada la base?)."
  echo "    Ejecute 'docker compose up -d db' y vuelva a intentar."
fi

echo
echo "Listo."
