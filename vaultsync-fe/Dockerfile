FROM node:24-alpine AS build
WORKDIR /src
COPY package.json package-lock.json* ./
COPY apps ./apps
COPY packages ./packages
COPY tsconfig.base.json ./
RUN npm install
RUN npm run build

FROM nginx:1.27-alpine
COPY docker/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /src/dist/portal /usr/share/nginx/html/portal
COPY --from=build /src/dist/admin /usr/share/nginx/html/admin
RUN mkdir -p /usr/share/nginx/html/downloads
