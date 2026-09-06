# syntax=docker/dockerfile:1

# ===============================================================
# wacrm — imagen de producción (Next.js 16, salida standalone)
#
# Pensada para EasyPanel (App → Build → Dockerfile), pero sirve
# igual con `docker build` / `docker compose` (ver docs/docker.md).
#
# EasyPanel: las variables que definas en la pestaña "Environment"
# del servicio se pasan automáticamente como `--build-arg` durante
# el build Y como variables de entorno en runtime. Por eso los
# `NEXT_PUBLIC_*` de abajo sólo necesitan estar declarados como ARG:
# EasyPanel los rellena. Los secretos server-only (SERVICE_ROLE_KEY,
# ENCRYPTION_KEY, META_APP_SECRET, ...) NO se declaran como ARG para
# que no queden horneados en la imagen; se leen en runtime.
# ===============================================================

# ---------------------------------------------------------------
# Base — Node fijado + compat glibc para sharp (optimización de
# imágenes de Next) sobre Alpine/musl.
# ---------------------------------------------------------------
FROM node:20-alpine AS base
RUN apk add --no-cache libc6-compat
WORKDIR /app

# ---------------------------------------------------------------
# Stage 1 — dependencias (cacheado hasta que cambie package*.json)
# ---------------------------------------------------------------
FROM base AS deps
COPY package.json package-lock.json ./
RUN npm ci

# ---------------------------------------------------------------
# Stage 2 — build
#
# Los NEXT_PUBLIC_* se inyectan en el bundle de cliente en tiempo
# de build, así que llegan como build args. Si cambias cualquiera
# de ellos en EasyPanel hay que reconstruir (Deploy con rebuild),
# no basta reiniciar.
# ---------------------------------------------------------------
FROM base AS builder
COPY --from=deps /app/node_modules ./node_modules
COPY . .

ARG NEXT_PUBLIC_SUPABASE_URL
ARG NEXT_PUBLIC_SUPABASE_ANON_KEY
ARG NEXT_PUBLIC_SITE_URL
ARG NEXT_PUBLIC_APP_LOCALE=en
ENV NEXT_PUBLIC_SUPABASE_URL=$NEXT_PUBLIC_SUPABASE_URL \
    NEXT_PUBLIC_SUPABASE_ANON_KEY=$NEXT_PUBLIC_SUPABASE_ANON_KEY \
    NEXT_PUBLIC_SITE_URL=$NEXT_PUBLIC_SITE_URL \
    NEXT_PUBLIC_APP_LOCALE=$NEXT_PUBLIC_APP_LOCALE \
    NEXT_TELEMETRY_DISABLED=1

RUN npm run build

# ---------------------------------------------------------------
# Stage 3 — runtime mínimo (sólo el bundle standalone)
# ---------------------------------------------------------------
FROM base AS runner
ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    HOSTNAME=0.0.0.0

RUN addgroup -S nextjs && adduser -S nextjs -G nextjs

COPY --from=builder --chown=nextjs:nextjs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nextjs /app/.next/static ./.next/static
COPY --from=builder --chown=nextjs:nextjs /app/public ./public

USER nextjs
EXPOSE 3000

# EasyPanel/Swarm usa este healthcheck para marcar el contenedor
# como sano antes de enrutar tráfico. 200-499 cuentan como vivo
# (p. ej. el 307 de la home a /login cuando no hay sesión).
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||3000)).then(r=>process.exit(r.status<500?0:1)).catch(()=>process.exit(1))"

CMD ["node", "server.js"]
