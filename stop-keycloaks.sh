#!/bin/bash
# Stop all Keycloak instances (works for both provisioning and SPI modes)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# Resolve podman binary
if [ -x /opt/podman/bin/podman ]; then
  export PODMAN=/opt/podman/bin/podman
elif command -v podman &>/dev/null; then
  export PODMAN=$(command -v podman)
fi

# Ensure podman is in PATH for podman-compose
export PATH="$(dirname "${PODMAN:-podman}"):$PATH"

# Resolve podman-compose
if command -v podman-compose &>/dev/null; then
  COMPOSE="podman-compose"
elif [ -x /opt/homebrew/bin/podman-compose ]; then
  COMPOSE="/opt/homebrew/bin/podman-compose"
else
  COMPOSE="podman-compose"
fi

echo "Stopping all Keycloak instances..."

# Try stopping with SPI override first (covers both modes),
# fall back to base compose only
if [ -f docker-compose.spi.yml ]; then
  PODMAN_BINARY="${PODMAN:-podman}" $COMPOSE -f docker-compose.yml -f docker-compose.spi.yml down 2>/dev/null || \
  PODMAN_BINARY="${PODMAN:-podman}" $COMPOSE down
else
  PODMAN_BINARY="${PODMAN:-podman}" $COMPOSE down
fi

echo "Done."
