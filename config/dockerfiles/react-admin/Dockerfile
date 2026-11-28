# syntax=docker/dockerfile:1

# Build
FROM node:24 AS react-build
WORKDIR /app
COPY ./package.json ./yarn.lock ./
RUN yarn
COPY . ./
# RUNTIME_CONFIG=true builds the publishable production image: no tenant,
# client or host is baked in; the container writes /config.js from its
# environment at start (40-dtrack-config.sh). Otherwise (local dev, demo,
# tests) the connection settings are required build args.
ARG RUNTIME_CONFIG=false
ARG VITE_MSAL_CLIENT_ID
ARG VITE_MSAL_AUTHORITY
ARG VITE_APP_BASE_URI
ARG VITE_API_BASE_URI
RUN if [ "$RUNTIME_CONFIG" = "true" ]; then \
  echo "Runtime-configured build: settings come from the container environment."; \
  else \
  for var in VITE_MSAL_CLIENT_ID VITE_MSAL_AUTHORITY VITE_APP_BASE_URI VITE_API_BASE_URI; do \
  eval val="\$$var"; \
  if [ -z "$val" ]; then \
  echo "$var not set"; \
  exit 1; \
  else \
  echo "$var is set to $val"; \
  fi; \
  done && \
  echo "All required environment variables are set."; \
  fi
ARG VITE_PALETTE_PRIMARY
ARG VITE_PALETTE_SECONDARY
# BUILD_MODE picks the Vite mode. "demo" loads the committed .env.demo
# (demo login and its local-only signing secret); "production" never reads
# that file. No secret is passed as a build arg, so none ends up in the image
# history or metadata. A runtime-configured (publishable) image is always a
# production build.
ARG BUILD_MODE=production
RUN case "$BUILD_MODE" in production|demo) ;; *) echo "BUILD_MODE must be production or demo"; exit 1;; esac && \
  if [ "$RUNTIME_CONFIG" = "true" ] && [ "$BUILD_MODE" != "production" ]; then \
  echo "RUNTIME_CONFIG=true images must be production builds"; exit 1; \
  fi && \
  yarn build --mode "$BUILD_MODE"

# Production
FROM nginx:alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
# COPY then chmod, not COPY --chmod: --chmod needs BuildKit, and the
# classic builder (e.g. docker without buildx, as compose uses for local
# dev and tests on some machines) rejects it.
COPY 40-dtrack-config.sh /docker-entrypoint.d/40-dtrack-config.sh
RUN chmod 755 /docker-entrypoint.d/40-dtrack-config.sh
COPY --from=react-build /app/dist /usr/share/nginx/html
ARG RUNTIME_CONFIG=false
RUN if [ "$RUNTIME_CONFIG" = "true" ]; then touch /usr/share/nginx/html/.runtime-config; fi
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
