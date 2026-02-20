#!/bin/bash
# =============================================================================
# Build all modules (app + SPI JAR).
#
# Usage:
#   ./build.sh              # Build both modules
#   ./build.sh --app        # Build only the Quarkus app
#   ./build.sh --spi        # Build only the SPI JAR
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

export JAVA_HOME=${JAVA_HOME:-$HOME/.sdkman/candidates/java/current}
export PATH=$HOME/.sdkman/candidates/maven/current/bin:$JAVA_HOME/bin:$PATH

# ---- Parse arguments ----
BUILD_APP=false
BUILD_SPI=false

if [ $# -eq 0 ]; then
  BUILD_APP=true
  BUILD_SPI=true
fi

while [[ $# -gt 0 ]]; do
  case $1 in
    --app)
      BUILD_APP=true
      shift
      ;;
    --spi)
      BUILD_SPI=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--app] [--spi]"
      exit 1
      ;;
  esac
done

echo "================================================"
echo " Building KC Token Exchange V2 Demo"
echo "================================================"

if $BUILD_APP && $BUILD_SPI; then
  echo " Modules: app + spi"
  echo "================================================"
  ./mvnw package -DskipTests
elif $BUILD_APP; then
  echo " Module:  app"
  echo "================================================"
  ./mvnw package -pl app -DskipTests
elif $BUILD_SPI; then
  echo " Module:  spi"
  echo "================================================"
  ./mvnw package -pl spi -DskipTests
fi

echo ""
echo "================================================"
echo " Build complete!"
if $BUILD_APP; then
  echo "  App:  app/target/*.jar"
fi
if $BUILD_SPI; then
  echo "  SPI:  spi/target/kc-jit-jwt-grant-spi-1.0.0-SNAPSHOT.jar"
fi
echo "================================================"
