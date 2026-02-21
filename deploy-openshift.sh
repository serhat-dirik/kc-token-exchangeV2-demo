#!/bin/bash
# =============================================================================
# Deploy KC Token Exchange V2 Demo to OpenShift
#
# Usage:
#   ./deploy-openshift.sh [--mode provisioning|spi] [--namespace <ns>] [--skip-build]
#
# Modes:
#   provisioning (default) — Pre-creates users, orgs, federated links
#   spi                    — JIT user provisioning via custom Keycloak SPI
#
# What this script does:
#   1. Creates/switches to the target namespace
#   2. Applies ImageStreams + BuildConfigs, triggers builds (unless --skip-build)
#   3. Creates realm ConfigMaps from realm JSONs (patching localhost URLs)
#   4. Creates app ConfigMaps with Route URLs for OIDC and service chaining
#   5. Applies all Deployments, Services, Routes
#   6. In SPI mode, patches KC-B and KC-C to use the kc-spi image
#   7. Runs the provisioning Job
#
# Prerequisites:
#   - oc CLI logged into an OpenShift cluster
#   - Sufficient quota for 6 pods + 3 builds
# =============================================================================

set -euo pipefail

# ---- Defaults ----
MODE="provisioning"
NAMESPACE=""
SKIP_BUILD=false

# ---- Parse args ----
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)
            MODE="$2"
            shift 2
            ;;
        --namespace|-n)
            NAMESPACE="$2"
            shift 2
            ;;
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--mode provisioning|spi] [--namespace <ns>] [--skip-build]"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Validate mode
if [[ "$MODE" != "provisioning" && "$MODE" != "spi" ]]; then
    echo "ERROR: --mode must be 'provisioning' or 'spi'"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OPENSHIFT_DIR="${SCRIPT_DIR}/openshift"
REALM_DIR="${SCRIPT_DIR}/keycloak/realms"

echo "=============================================="
echo " KC Token Exchange V2 Demo - OpenShift Deploy"
echo " Mode: ${MODE}"
echo "=============================================="
echo ""

# ---- Step 1: Namespace ----
if [[ -n "$NAMESPACE" ]]; then
    echo "[1/9] Creating/switching to namespace: ${NAMESPACE}"
    oc new-project "${NAMESPACE}" 2>/dev/null || oc project "${NAMESPACE}"
else
    NAMESPACE=$(oc project -q)
    echo "[1/9] Using current namespace: ${NAMESPACE}"
fi
echo ""

# ---- Step 2: ImageStreams + BuildConfigs ----
echo "[2/9] Applying ImageStreams and BuildConfigs..."
oc apply -f "${OPENSHIFT_DIR}/imagestreams.yaml"
oc apply -f "${OPENSHIFT_DIR}/buildconfigs.yaml"

if [[ "$SKIP_BUILD" == "false" ]]; then
    echo "  Starting builds..."
    oc start-build kc-demo-app --wait=false || true
    oc start-build kc-demo-provision --wait=false || true
    if [[ "$MODE" == "spi" ]]; then
        oc start-build kc-spi --wait=false || true
    fi
    echo "  Builds started. They will run in the background."
else
    echo "  Skipping builds (--skip-build)."
fi
echo ""

# ---- Step 3: Apply Services and Routes (needed before we can read Route hostnames) ----
echo "[3/9] Applying Services and Routes..."
oc apply -f "${OPENSHIFT_DIR}/services.yaml"
oc apply -f "${OPENSHIFT_DIR}/routes.yaml"
echo ""

# ---- Step 4: Discover Route URLs ----
echo "[4/9] Discovering Route URLs..."

# Wait for Routes to get hostnames
for i in $(seq 1 30); do
    KC_A_HOST=$(oc get route kc-a -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    if [[ -n "$KC_A_HOST" ]]; then
        break
    fi
    echo "  Waiting for Routes to be assigned hostnames..."
    sleep 2
done

KC_A_HOST=$(oc get route kc-a -o jsonpath='{.spec.host}')
KC_B_HOST=$(oc get route kc-b -o jsonpath='{.spec.host}')
KC_C_HOST=$(oc get route kc-c -o jsonpath='{.spec.host}')
APP_A_HOST=$(oc get route app-a -o jsonpath='{.spec.host}')

KC_A_ROUTE="https://${KC_A_HOST}"
KC_B_ROUTE="https://${KC_B_HOST}"
KC_C_ROUTE="https://${KC_C_HOST}"
APP_A_ROUTE="https://${APP_A_HOST}"

echo "  KC-A Route:  ${KC_A_ROUTE}"
echo "  KC-B Route:  ${KC_B_ROUTE}"
echo "  KC-C Route:  ${KC_C_ROUTE}"
echo "  App-A Route: ${APP_A_ROUTE}"
echo ""

# ---- Step 5: Create realm ConfigMaps (patching URLs) ----
echo "[5/9] Creating realm ConfigMaps with patched URLs..."

# Realm-A: patch localhost:8081 -> App-A Route, localhost:8280 -> KC-B Route (audience mapper)
REALM_A_JSON=$(cat "${REALM_DIR}/realm-a.json" \
    | sed "s|http://localhost:8081|${APP_A_ROUTE}|g" \
    | sed "s|http://localhost:8280|${KC_B_ROUTE}|g")

# Realm-B: patch localhost:8180 -> KC-A Route (issuer, auth, token, logout URLs)
#          patch host.containers.internal:8180 -> kc-a:8080 (internal jwks, userinfo)
#          patch localhost:8380 -> KC-C Route (audience mapper)
REALM_B_JSON=$(cat "${REALM_DIR}/realm-b.json" \
    | sed "s|http://localhost:8180|${KC_A_ROUTE}|g" \
    | sed "s|http://host.containers.internal:8180|http://kc-a:8080|g" \
    | sed "s|http://localhost:8380|${KC_C_ROUTE}|g")

# Realm-C: patch localhost:8280 -> KC-B Route (issuer, auth, token, logout URLs)
#          patch host.containers.internal:8280 -> kc-b:8080 (internal jwks, userinfo)
REALM_C_JSON=$(cat "${REALM_DIR}/realm-c.json" \
    | sed "s|http://localhost:8280|${KC_B_ROUTE}|g" \
    | sed "s|http://host.containers.internal:8280|http://kc-b:8080|g")

# Delete existing ConfigMaps to avoid immutable field errors
oc delete configmap kc-a-realm kc-b-realm kc-c-realm 2>/dev/null || true

# Create ConfigMaps from the patched JSON
echo "$REALM_A_JSON" | oc create configmap kc-a-realm --from-file=realm-a.json=/dev/stdin
echo "$REALM_B_JSON" | oc create configmap kc-b-realm --from-file=realm-b.json=/dev/stdin
echo "$REALM_C_JSON" | oc create configmap kc-c-realm --from-file=realm-c.json=/dev/stdin

oc label configmap kc-a-realm app.kubernetes.io/part-of=kc-token-exchange-demo --overwrite
oc label configmap kc-b-realm app.kubernetes.io/part-of=kc-token-exchange-demo --overwrite
oc label configmap kc-c-realm app.kubernetes.io/part-of=kc-token-exchange-demo --overwrite

echo "  Realm ConfigMaps created with patched URLs."
echo ""

# ---- Step 6: Create app ConfigMaps ----
# These contain the Quarkus config overrides.
# QUARKUS_OIDC_AUTH_SERVER_URL uses Route URL (browser needs it for login + OIDC discovery).
# APP_TARGET_KC_TOKEN_URL uses Route URL (issuer claim must match IDP config in realm JSON).
# APP_TARGET_SERVICE_URL uses internal Service URL (pod-to-pod, no external hop needed).
echo "[6/9] Creating app ConfigMaps..."

oc delete configmap app-a-config app-b-config app-c-config 2>/dev/null || true

oc create configmap app-a-config \
    --from-literal=APP_NAME="App-A (UI + Service)" \
    --from-literal=QUARKUS_OIDC_AUTH_SERVER_URL="${KC_A_ROUTE}/realms/realm-a" \
    --from-literal=QUARKUS_OIDC_CLIENT_ID="app-a-client" \
    --from-literal=QUARKUS_OIDC_APPLICATION_TYPE="web-app" \
    --from-literal=QUARKUS_OIDC_ROLES_SOURCE="accesstoken" \
    --from-literal=QUARKUS_HTTP_PROXY_PROXY_ADDRESS_FORWARDING="true" \
    --from-literal=QUARKUS_HTTP_PROXY_ENABLE_FORWARDED_HOST="true" \
    --from-literal=QUARKUS_HTTP_PROXY_ENABLE_FORWARDED_PREFIX="true" \
    --from-literal=APP_TARGET_SERVICE_URL="http://app-b:8080/api/hello" \
    --from-literal=APP_TARGET_KC_TOKEN_URL="${KC_B_ROUTE}/realms/realm-b/protocol/openid-connect/token" \
    --from-literal=APP_TARGET_KC_CLIENT_ID="app-a-m2m-client"

oc create configmap app-b-config \
    --from-literal=APP_NAME="App-B (Service)" \
    --from-literal=QUARKUS_OIDC_AUTH_SERVER_URL="${KC_B_ROUTE}/realms/realm-b" \
    --from-literal=QUARKUS_OIDC_CLIENT_ID="app-b-client" \
    --from-literal=QUARKUS_OIDC_APPLICATION_TYPE="service" \
    --from-literal=QUARKUS_OIDC_ROLES_SOURCE="accesstoken" \
    --from-literal=QUARKUS_HTTP_PROXY_PROXY_ADDRESS_FORWARDING="true" \
    --from-literal=QUARKUS_HTTP_PROXY_ENABLE_FORWARDED_HOST="true" \
    --from-literal=QUARKUS_HTTP_PROXY_ENABLE_FORWARDED_PREFIX="true" \
    --from-literal=APP_TARGET_SERVICE_URL="http://app-c:8080/api/hello" \
    --from-literal=APP_TARGET_KC_TOKEN_URL="${KC_C_ROUTE}/realms/realm-c/protocol/openid-connect/token" \
    --from-literal=APP_TARGET_KC_CLIENT_ID="app-b-m2m-client"

oc create configmap app-c-config \
    --from-literal=APP_NAME="App-C (Terminal Service)" \
    --from-literal=QUARKUS_OIDC_AUTH_SERVER_URL="${KC_C_ROUTE}/realms/realm-c" \
    --from-literal=QUARKUS_OIDC_CLIENT_ID="app-c-client" \
    --from-literal=QUARKUS_OIDC_APPLICATION_TYPE="service" \
    --from-literal=QUARKUS_OIDC_ROLES_SOURCE="accesstoken" \
    --from-literal=QUARKUS_HTTP_PROXY_PROXY_ADDRESS_FORWARDING="true" \
    --from-literal=QUARKUS_HTTP_PROXY_ENABLE_FORWARDED_HOST="true" \
    --from-literal=QUARKUS_HTTP_PROXY_ENABLE_FORWARDED_PREFIX="true"

oc label configmap app-a-config app=app-a app.kubernetes.io/part-of=kc-token-exchange-demo --overwrite
oc label configmap app-b-config app=app-b app.kubernetes.io/part-of=kc-token-exchange-demo --overwrite
oc label configmap app-c-config app=app-c app.kubernetes.io/part-of=kc-token-exchange-demo --overwrite

echo "  App ConfigMaps created."
echo ""

# ---- Step 7: Apply Secrets and Deployments ----
echo "[7/9] Applying Secrets and Deployments..."
oc apply -f "${OPENSHIFT_DIR}/kc-config.yaml"
oc apply -f "${OPENSHIFT_DIR}/kc-secret.yaml"
oc apply -f "${OPENSHIFT_DIR}/app-secrets.yaml"

# Patch KC deployments with actual Route URLs
for KC_INSTANCE in a b c; do
    DEPLOY_FILE="${OPENSHIFT_DIR}/kc-${KC_INSTANCE}-deployment.yaml"
    ROUTE_VAR="KC_$(echo ${KC_INSTANCE} | tr '[:lower:]' '[:upper:]')_ROUTE"
    ROUTE_URL="${!ROUTE_VAR}"

    sed "s|PLACEHOLDER_KC_$(echo ${KC_INSTANCE} | tr '[:lower:]' '[:upper:]')_ROUTE|${ROUTE_URL}|g" \
        "${DEPLOY_FILE}" | oc apply -f -
done

# Get the app image reference from the ImageStream
APP_IMAGE=$(oc get istag kc-demo-app:latest -o jsonpath='{.image.dockerImageReference}' 2>/dev/null || echo "")
if [[ -z "$APP_IMAGE" ]]; then
    # Build may not be done yet; use the ImageStream tag reference
    APP_IMAGE="kc-demo-app:latest"
    echo "  NOTE: kc-demo-app build may still be in progress. Using ImageStream tag reference."
fi

# Apply app deployments with patched image
for APP_INSTANCE in a b c; do
    DEPLOY_FILE="${OPENSHIFT_DIR}/app-${APP_INSTANCE}-deployment.yaml"
    sed "s|PLACEHOLDER_APP_IMAGE|${APP_IMAGE}|g" "${DEPLOY_FILE}" | oc apply -f -
done

echo "  Deployments applied."
echo ""

# ---- Step 8: SPI mode - patch KC-B and KC-C images ----
if [[ "$MODE" == "spi" ]]; then
    echo "[8/9] SPI mode: patching KC-B and KC-C to use kc-spi image..."

    SPI_IMAGE=$(oc get istag kc-spi:latest -o jsonpath='{.image.dockerImageReference}' 2>/dev/null || echo "")
    if [[ -z "$SPI_IMAGE" ]]; then
        SPI_IMAGE="kc-spi:latest"
        echo "  NOTE: kc-spi build may still be in progress. Using ImageStream tag reference."
    fi

    oc set image deployment/kc-b keycloak="${SPI_IMAGE}"
    oc set image deployment/kc-c keycloak="${SPI_IMAGE}"
    echo "  KC-B and KC-C patched to use kc-spi image."
else
    echo "[8/9] Provisioning mode: KC-B and KC-C use standard Keycloak image (no SPI)."
fi
echo ""

# ---- Step 9: Wait for KC instances, then run provisioning Job ----
echo "[9/9] Waiting for Keycloak instances to be ready before provisioning..."

# Wait for all builds to complete first
if [[ "$SKIP_BUILD" == "false" ]]; then
    echo "  Waiting for kc-demo-app build..."
    oc wait --for=condition=Complete build -l buildconfig=kc-demo-app --timeout=600s 2>/dev/null || true
    echo "  Waiting for kc-demo-provision build..."
    oc wait --for=condition=Complete build -l buildconfig=kc-demo-provision --timeout=600s 2>/dev/null || true
    if [[ "$MODE" == "spi" ]]; then
        echo "  Waiting for kc-spi build..."
        oc wait --for=condition=Complete build -l buildconfig=kc-spi --timeout=600s 2>/dev/null || true
    fi
fi

echo "  Waiting for KC deployments to be ready..."
oc rollout status deployment/kc-a --timeout=300s
oc rollout status deployment/kc-b --timeout=300s
oc rollout status deployment/kc-c --timeout=300s
echo "  All KC instances are ready."
echo ""

# Get provision image
PROVISION_IMAGE=$(oc get istag kc-demo-provision:latest -o jsonpath='{.image.dockerImageReference}' 2>/dev/null || echo "")
if [[ -z "$PROVISION_IMAGE" ]]; then
    PROVISION_IMAGE="kc-demo-provision:latest"
fi

# Determine which script to run
if [[ "$MODE" == "provisioning" ]]; then
    PROVISION_SCRIPT="provision-users.sh"
else
    PROVISION_SCRIPT="provision-minimal.sh"
fi

# Delete any existing provisioning job
oc delete job kc-provision-${MODE} 2>/dev/null || true

# Process and apply the job template
sed -e "s|PLACEHOLDER_MODE|${MODE}|g" \
    -e "s|PLACEHOLDER_PROVISION_IMAGE|${PROVISION_IMAGE}|g" \
    -e "s|PLACEHOLDER_PROVISION_SCRIPT|${PROVISION_SCRIPT}|g" \
    "${OPENSHIFT_DIR}/provision-job-template.yaml" | oc apply -f -

echo "  Provisioning Job 'kc-provision-${MODE}' created."
echo "  Waiting for provisioning to complete..."
oc wait --for=condition=Complete job/kc-provision-${MODE} --timeout=300s || {
    echo "  WARNING: Provisioning job did not complete within timeout."
    echo "  Check logs: oc logs job/kc-provision-${MODE}"
}
echo ""

# ---- Summary ----
echo "=============================================="
echo " Deployment Complete!"
echo "=============================================="
echo ""
echo "  Mode:     ${MODE}"
echo "  KC-A:     ${KC_A_ROUTE}  (admin: admin/admin)"
echo "  KC-B:     ${KC_B_ROUTE}  (admin: admin/admin)"
echo "  KC-C:     ${KC_C_ROUTE}  (admin: admin/admin)"
echo "  App-A:    ${APP_A_ROUTE}"
echo ""
echo "  Test users (login via App-A):"
echo "    alice / alice"
echo "    bob   / bob"
echo ""
if [[ "$MODE" == "spi" ]]; then
    echo "  SPI mode: Users are provisioned JIT on first JWT Grant."
else
    echo "  Provisioning mode: Users pre-created in all KC instances."
fi
echo ""
echo "  Useful commands:"
echo "    oc logs job/kc-provision-${MODE}    # Provisioning logs"
echo "    oc logs deployment/kc-a             # KC-A logs"
echo "    oc logs deployment/app-a            # App-A logs"
echo "    oc get pods                         # Pod status"
echo "=============================================="
