# v677: node:20 → node:22 (Node 20 é EOL desde abr/2026 e NÃO recebeu o
# security release de 21/out/2026 — CVEs high incl. Brotli RCE + TLS bypass).
# A linha 22.x recebeu a correção (22.23.4).
FROM node:22-slim

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY . .

RUN groupadd -r nodeuser && useradd -r -g nodeuser -m nodeuser

# Create data dir with correct permissions (Fly volume mounts as root)
RUN mkdir -p /data && chown nodeuser:nodeuser /data

USER nodeuser

EXPOSE 8080

CMD ["node", "server.js"]
