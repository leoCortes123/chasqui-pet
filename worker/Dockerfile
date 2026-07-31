# =============================================================================
# Chasqui Pet — Worker de tareas asíncronas
# -----------------------------------------------------------------------------
# Procesa la cola tarea_async: recibos, notificaciones de Telegram, reportes,
# alertas de inventario y demás trabajo diferido. El webhook nunca hace este
# trabajo en línea, para poder responder en menos de un segundo.
# =============================================================================

# --- Etapa 1: dependencias ---------------------------------------------------
FROM node:22-alpine AS deps

WORKDIR /app

# Solo los manifiestos: así esta capa se reutiliza mientras no cambien.
COPY package*.json ./

# npm ci instala exactamente lo del package-lock.json. --omit=dev deja fuera
# las dependencias de desarrollo, que en producción no hacen falta.
RUN npm ci --omit=dev && npm cache clean --force


# --- Etapa 2: imagen final ---------------------------------------------------
FROM node:22-alpine AS runtime

# Zona horaria de Bogotá dentro del contenedor: los logs y los cálculos de
# fechas del worker (reintentos, jobs diarios) deben coincidir con la clínica.
RUN apk add --no-cache tzdata \
    && cp /usr/share/zoneinfo/America/Bogota /etc/localtime \
    && echo "America/Bogota" > /etc/timezone

ENV TZ=America/Bogota \
    NODE_ENV=production \
    NPM_CONFIG_UPDATE_NOTIFIER=false

WORKDIR /app

COPY --from=deps /app/node_modules ./node_modules
COPY --chown=node:node . .

# No correr como root.
USER node

# Reinicio limpio ante SIGTERM: node como PID 1 con manejo explícito de señales
# en el código; init de tini vía --init del runtime de Docker si hiciera falta.
CMD ["node", "src/index.js"]
