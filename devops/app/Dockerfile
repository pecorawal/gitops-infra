# Imagem de runtime enxuta (UBI 9 + Node.js 20). Sem npm install: a app não
# tem dependências, então o build é rápido e não depende de internet.
FROM registry.access.redhat.com/ubi9/nodejs-20-minimal:latest
WORKDIR /opt/app-root/src
COPY package.json lib.js server.js ./
ENV PORT=8080
EXPOSE 8080
USER 1001
CMD ["node", "server.js"]
