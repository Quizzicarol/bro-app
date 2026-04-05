FROM node:20-slim

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
