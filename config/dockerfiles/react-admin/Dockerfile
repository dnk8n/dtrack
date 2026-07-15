# syntax=docker/dockerfile:1

# Build
FROM node:24 as react-build
WORKDIR /app
COPY ./package.json ./yarn.lock ./
RUN yarn
COPY . ./
ARG VITE_MSAL_CLIENT_ID
ARG VITE_MSAL_AUTHORITY
ARG VITE_APP_BASE_URI
ARG VITE_API_BASE_URI
RUN for var in VITE_MSAL_CLIENT_ID VITE_MSAL_AUTHORITY VITE_APP_BASE_URI VITE_API_BASE_URI; do \
  eval val="\$$var"; \
  if [ -z "$val" ]; then \
  echo "$var not set"; \
  exit 1; \
  else \
  echo "$var is set to $val"; \
  fi; \
  done && \
  echo "All required environment variables are set."
ARG VITE_PALETTE_PRIMARY
ARG VITE_PALETTE_SECONDARY
ARG VITE_ENVIRONMENT
ARG VITE_JWT_SECRET
RUN yarn build

# Production
FROM nginx:alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=react-build /app/dist /usr/share/nginx/html
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
