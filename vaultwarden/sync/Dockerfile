FROM node:24.16.0-alpine3.22

# openssl: self-signed certificate for the loopback TLS proxy the bw CLI talks through
RUN apk add --no-cache openssl

WORKDIR /app
ENV NODE_ENV=production \
    STATE_DIR=/state

COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund && npm cache clean --force

COPY src ./src

VOLUME /state
HEALTHCHECK --interval=60s --timeout=10s --start-period=120s CMD ["node", "/app/src/main.ts", "--health"]

ENTRYPOINT ["node", "/app/src/main.ts"]
