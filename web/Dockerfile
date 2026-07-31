# =============================================================================
# Chasqui Pet — Portal web y pantalla pública de turnos (Next.js App Router)
# -----------------------------------------------------------------------------
# Construcción en tres etapas para que la imagen final solo lleve lo necesario
# para servir: Next.js en modo "standalone".
# Requiere en next.config.js:   output: 'standalone'
# =============================================================================

# --- Etapa 1: dependencias ---------------------------------------------------
FROM node:22-alpine AS deps

WORKDIR /app

COPY package*.json ./
RUN npm ci


# --- Etapa 2: construcción ---------------------------------------------------
FROM node:22-alpine AS builder

WORKDIR /app

ENV NEXT_TELEMETRY_DISABLED=1 \
    TZ=America/Bogota

COPY --from=deps /app/node_modules ./node_modules
COPY . .

RUN npm run build


# --- Etapa 3: imagen final ---------------------------------------------------
FROM node:22-alpine AS runtime

# Zona horaria de Bogotá: las fechas que se muestran en el portal, la pantalla
# de turnos y los reportes se presentan en hora local.
RUN apk add --no-cache tzdata \
    && cp /usr/share/zoneinfo/America/Bogota /etc/localtime \
    && echo "America/Bogota" > /etc/timezone

ENV NODE_ENV=production \
    TZ=America/Bogota \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    HOSTNAME=0.0.0.0

WORKDIR /app

# La salida standalone trae su propio server.js y solo las dependencias que el
# build detectó como usadas en tiempo de ejecución.
COPY --from=builder --chown=node:node /app/public ./public
COPY --from=builder --chown=node:node /app/.next/standalone ./
COPY --from=builder --chown=node:node /app/.next/static ./.next/static

USER node

EXPOSE 3000

CMD ["node", "server.js"]
