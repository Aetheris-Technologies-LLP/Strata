# ═══════════════════════════════════════
# Strata v0.2.0 — Dockerfile
# Usage: docker build -t strata .
#        docker run -d -p 11435:11435 --env-file .env strata
# ═══════════════════════════════════════

FROM node:20-alpine

# Metadata
LABEL maintainer="Tristen Markham"
LABEL description="Strata Model Gateway"
LABEL version="0.2.0"

# Create app directory
WORKDIR /app

# Install dependencies first (layer caching)
COPY package*.json ./
RUN npm install --omit=dev

# Copy source
COPY server.js .
COPY cli.js .
COPY strata.config.json .

# Create log directory
RUN mkdir -p /var/log/strata

# Expose port
EXPOSE 11435

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost:11435/health | grep -q "online" || exit 1

# Run
CMD ["node", "server.js"]
