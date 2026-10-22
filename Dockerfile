FROM node:22-alpine

WORKDIR /app

COPY server.js /app/server.js

USER node

EXPOSE 8877

CMD ["node", "server.js"]