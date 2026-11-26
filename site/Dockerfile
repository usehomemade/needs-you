# Static build, then a small web server. Coolify: build pack "Dockerfile",
# base directory /site, port 80. Pass GITHUB_TOKEN as a build arg to avoid
# GitHub's unauthenticated rate limit (optional; the page falls back).
FROM node:24-alpine AS build
WORKDIR /app
RUN corepack enable
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile
COPY . .
ARG GITHUB_TOKEN
ENV GITHUB_TOKEN=$GITHUB_TOKEN
RUN pnpm build

FROM nginx:1.29-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 80
