#!/bin/bash
# =============================================================================
# Start all 3 Keycloak instances using podman-compose.
#
# Two modes:
#   --mode provisioning  (default) Pre-provisions users via provision-users.sh
#   --mode spi           Mounts JIT SPI JAR, minimal provisioning (orgs only)
#
# KC-A: http://localhost:8180 (realm-a) - admin/admin
# KC-B: http://localhost:8280 (realm-b) - admin/admin
# KC-C: http://localhost:8380 (realm-c) - admin/admin
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ---- Parse arguments ----
MODE="provisioning"
while [[ $# -gt 0 ]]; do
  case $1 in
    --mode)
      MODE="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--mode provisioning|spi]"
      exit 1
      ;;
  esac
done

if [[ "$MODE" != "provisioning" && "$MODE" != "spi" ]]; then
  echo "ERROR: Invalid mode '$MODE'. Use 'provisioning' or 'spi'."
  exit 1
fi

# ---- Resolve Podman ----
if [ -x /opt/podman/bin/podman ]; then
  export PODMAN=/opt/podman/bin/podman
elif command -v podman &>/dev/null; then
  export PODMAN=$(command -v podman)
else
  echo "ERROR: podman not found. Install Podman Desktop or brew install podman."
  exit 1
fi

export PATH="$(dirname "$PODMAN"):$PATH"

# ---- Resolve podman-compose ----
if command -v podman-compose &>/dev/null; then
  COMPOSE="podman-compose"
elif [ -x /opt/homebrew/bin/podman-compose ]; then
  COMPOSE="/opt/homebrew/bin/podman-compose"
else
  echo "ERROR: podman-compose not found. Install via: pip install podman-compose"
  exit 1
fi

echo "Using podman: $PODMAN ($($PODMAN --version))"
echo "Using compose: $COMPOSE"

# ---- Ensure Podman machine is running ----
if ! $PODMAN machine inspect 2>/dev/null | grep -q '"State": "running"'; then
  echo "Podman machine not running. Initializing..."
  if ! $PODMAN machine list --format '{{.Name}}' 2>/dev/null | grep -q .; then
    $PODMAN machine init --cpus 4 --memory 4096 --disk-size 20
  fi
  $PODMAN machine start
  echo "Podman machine started."
fi

# ---- SPI mode: build JAR if needed ----
if [ "$MODE" = "spi" ]; then
  SPI_JAR="$SCRIPT_DIR/spi/target/kc-jit-jwt-grant-spi-1.0.0-SNAPSHOT.jar"
  if [ ! -f "$SPI_JAR" ]; then
    echo ""
    echo "Building SPI JAR..."
    export JAVA_HOME=${JAVA_HOME:-$HOME/.sdkman/candidates/java/current}
    export PATH=$HOME/.sdkman/candidates/maven/current/bin:$JAVA_HOME/bin:$PATH
    ./mvnw package -pl spi -DskipTests
    echo "SPI JAR built: $SPI_JAR"
  else
    echo "SPI JAR already exists: $SPI_JAR"
  fi
fi

# ---- Start containers ----
echo ""
echo "================================================"
echo " Starting 3 Keycloak instances with Podman"
echo " Mode: $MODE"
echo "================================================"
echo ""
echo " KC-A: http://localhost:8180  (realm-a, user-facing)"
echo " KC-B: http://localhost:8280  (realm-b, service tier)"
echo " KC-C: http://localhost:8380  (realm-c, terminal tier)"
echo ""
echo " Admin console: admin / admin"
if [ "$MODE" = "spi" ]; then
  echo " SPI:  JIT JWT Grant (mounted into KC-B, KC-C)"
fi
echo "================================================"

if [ "$MODE" = "spi" ]; then
  PODMAN_BINARY="$PODMAN" $COMPOSE -f docker-compose.yml -f docker-compose.spi.yml up -d
else
  PODMAN_BINARY="$PODMAN" $COMPOSE up -d
fi

# ---- Wait for health ----
echo ""
echo "Waiting for Keycloak instances to be healthy..."
echo "(This may take 30-60 seconds on first run)"
echo ""

for port in 8180 8280 8380; do
  echo -n "Waiting for KC on port $port..."
  for i in $(seq 1 60); do
    if curl -s -o /dev/null -w "%{http_code}" "http://localhost:$port/realms/master" 2>/dev/null | grep -q "200"; then
      echo " READY"
      break
    fi
    sleep 2
    echo -n "."
  done
done

echo ""
echo "All Keycloak instances are up and realms are imported!"
echo ""

# ---- Run provisioning ----
if [ "$MODE" = "provisioning" ]; then
  echo "Provisioning users and federated identity links..."
  echo ""
  "$SCRIPT_DIR/provision-users.sh"
else
  echo "Running minimal provisioning (organizations + IDP links + scope)..."
  echo "Users will be created JIT by the custom SPI on first JWT Grant."
  echo ""
  "$SCRIPT_DIR/provision-minimal.sh"
fi

echo ""
echo "You can now start the Quarkus applications:"
echo "  ./run-app-a.sh   (UI + Service, port 8081)"
echo "  ./run-app-b.sh   (Service, port 8082)"
echo "  ./run-app-c.sh   (Terminal Service, port 8083)"
