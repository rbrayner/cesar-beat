FROM node:12-alpine

RUN apk add --no-cache git

RUN git clone --depth 1 https://github.com/OWASP/NodejsGoat.git /app
WORKDIR /app
RUN npm install --production --no-cache

EXPOSE 4000
CMD ["sh", "-c", "node artifacts/db-reset.js && npm start"]
