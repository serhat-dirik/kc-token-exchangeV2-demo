#!/bin/bash
# =============================================================================
# Remove all KC Token Exchange V2 Demo resources from OpenShift.
# Does NOT delete the namespace itself (safety).
#
# Usage: ./undeploy-openshift.sh [--namespace <ns>]
# =============================================================================

set -euo pipefail

NAMESPACE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --namespace|-n) NAMESPACE="$2"; shift 2 ;;
        *) echo "Usage: $0 [--namespace <ns>]"; exit 1 ;;
    esac
done

if [[ -n "$NAMESPACE" ]]; then
    oc project "${NAMESPACE}"
else
    NAMESPACE=$(oc project -q)
fi

echo "=============================================="
echo " Removing KC Token Exchange V2 Demo resources"
echo " Namespace: ${NAMESPACE}"
echo "=============================================="
echo ""

echo "Deleting Jobs..."
oc delete job kc-provision-provisioning kc-provision-spi --ignore-not-found

echo "Deleting Deployments..."
oc delete deployment kc-a kc-b kc-c app-a app-b app-c --ignore-not-found

echo "Deleting Services..."
oc delete service kc-a kc-b kc-c app-a app-b app-c --ignore-not-found

echo "Deleting Routes..."
oc delete route kc-a kc-b kc-c app-a --ignore-not-found

echo "Deleting BuildConfigs..."
oc delete buildconfig kc-demo-app kc-spi kc-demo-provision --ignore-not-found

echo "Deleting ImageStreams..."
oc delete imagestream kc-demo-app kc-spi kc-demo-provision --ignore-not-found

echo "Deleting ConfigMaps..."
oc delete configmap kc-config kc-a-realm kc-b-realm kc-c-realm \
    app-a-config app-b-config app-c-config --ignore-not-found

echo "Deleting Secrets..."
oc delete secret kc-credentials app-a-secrets app-b-secrets app-c-secrets --ignore-not-found

echo ""
echo "=============================================="
echo " All demo resources removed from ${NAMESPACE}"
echo "=============================================="
