# ---------- Etapa 1: build ----------
FROM node:24-alpine AS builder

WORKDIR /app

# Primero solo los archivos de dependencias y Prisma, para aprovechar la caché de capas.
# El schema se necesita porque el "postinstall" ejecuta "prisma generate".
COPY package*.json prisma7.config.ts ./
COPY prisma ./prisma
RUN npm ci

COPY . .
RUN npm run build

# ---------- Etapa 2: runtime ----------
FROM node:24-alpine AS runner

LABEL org.opencontainers.image.source="https://github.com/Lautaro24Fer/coderhouse-devops-example" \
      org.opencontainers.image.description="API backend en NestJS + Prisma del curso de DevOps de coderhouse" \
      org.opencontainers.image.licenses="UNLICENSED" \
      org.opencontainers.image.title="mi-api"

ENV NODE_ENV=production
WORKDIR /app

# Solo dependencias de producción. --ignore-scripts evita el "postinstall"
# (prisma es devDependency y el cliente ya viene compilado dentro de dist/).
COPY package*.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force

COPY --from=builder /app/dist ./dist

# Usuario sin privilegios que ya trae la imagen oficial de Node
USER node

EXPOSE 3000

CMD ["node", "dist/main"]
