# Stage 1: Build the React app
FROM --platform=linux/arm64 node:20-slim AS build
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci
COPY . .
RUN npm run build

# Stage 2: Serve with nginx (non-root)
# nginxinc/nginx-unprivileged runs as UID 101 and listens on port 8080,
# eliminating the need for root privileges inside the container.
FROM --platform=linux/arm64 nginxinc/nginx-unprivileged:alpine
COPY --from=build /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 8080
CMD ["nginx", "-g", "daemon off;"]
