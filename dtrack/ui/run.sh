#!/usr/bin/env bash
# Start the compose stack in dev or debug mode from within dtrack/ui, and
# with --local also run Vite on the host against it (yarn dev / yarn debug).
# No -u: empty-array expansion under set -u breaks on macOS's stock bash 3.2.
set -eo pipefail

ACTION="${1:-}"
BUILD_FLAGS=()
[[ "${2:-}" == "--local" ]] || BUILD_FLAGS=(--build --pull=always)

if [[ "$ACTION" == "debug" ]]; then
  (cd "$(pwd)/../.." &&
    docker compose -f docker-compose.yaml \
      -f config/docker-compose.overrides/dev.yaml \
      -f config/docker-compose.overrides/debug.yaml \
      up -d "${BUILD_FLAGS[@]}")
  export VITE_ENVIRONMENT=DEBUG
  export VITE_JWT_SECRET=Dummy5ecr3t4D3bug0n1yN0T4Pr0D123
  export VITE_PALETTE_PRIMARY=#5F6368
  export VITE_PALETTE_SECONDARY=#B0B3B8
elif [[ "$ACTION" == "dev" ]]; then
  docker compose up -d "${BUILD_FLAGS[@]}"
fi

if [[ "${2:-}" == "--local" ]]; then
  exec ./node_modules/.bin/vite
fi
