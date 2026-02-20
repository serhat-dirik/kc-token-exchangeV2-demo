#!/bin/bash
# =============================================================================
# Minimal provisioning for SPI mode:
#   - Creates Organizations in KC-B and KC-C
#   - Links IDPs to Organizations
#   - Promotes 'organization' client scope to default on M2M clients
#
# Does NOT create users or federated identity links — the custom JIT SPI
# handles user creation automatically during JWT Authorization Grant.
#
# Used by: ./start-keycloaks.sh --mode spi
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/provision-common.sh"

KC_B="http://localhost:8280"
KC_C="http://localhost:8380"

ADMIN_USER="admin"
ADMIN_PASS="admin"

echo "==============================================" >&2
echo " Minimal Provisioning (SPI Mode)" >&2
echo " Organizations, IDP links, scope promotion" >&2
echo " Users will be created JIT by the custom SPI" >&2
echo "==============================================" >&2
echo "" >&2

# ---- Step 1: Get admin tokens ----
log_info "Getting admin tokens..."
TOKEN_B=$(get_admin_token "$KC_B") || { log_error "Cannot get admin token for KC-B"; exit 1; }
TOKEN_C=$(get_admin_token "$KC_C") || { log_error "Cannot get admin token for KC-C"; exit 1; }
log_info "Admin tokens acquired."
echo "" >&2

# ---- Step 2: Create Organizations ----
log_info "Creating organizations..."
echo "" >&2

# Realm-B: Organization for users from KC-A
log_org "Setting up organization in realm-b..."
ORG_B_ID=$(create_organization "$KC_B" "realm-b" "kc-a-external-users" \
    "Users federated from KC-A (realm-a) via kc-a-idp identity provider" "$TOKEN_B")

if [ -n "$ORG_B_ID" ]; then
    link_idp_to_organization "$KC_B" "realm-b" "$ORG_B_ID" "kc-a-idp" "$TOKEN_B"
fi
echo "" >&2

# Realm-C: Organization for users from KC-B
log_org "Setting up organization in realm-c..."
ORG_C_ID=$(create_organization "$KC_C" "realm-c" "kc-b-external-users" \
    "Users federated from KC-B (realm-b) via kc-b-idp identity provider" "$TOKEN_C")

if [ -n "$ORG_C_ID" ]; then
    link_idp_to_organization "$KC_C" "realm-c" "$ORG_C_ID" "kc-b-idp" "$TOKEN_C"
fi
echo "" >&2

# ---- Step 3: Register 'origin' attribute in user profile ----
# KC 26 declarative user profiles require custom attributes to be registered
# before they appear in admin API responses. The JIT SPI sets this attribute.
log_info "Registering 'origin' attribute in user profiles..."
add_user_profile_attribute "$KC_B" "realm-b" "origin" "$TOKEN_B"
add_user_profile_attribute "$KC_C" "realm-c" "origin" "$TOKEN_C"
echo "" >&2

# ---- Step 4: Promote 'organization' client scope to default on M2M clients ----
log_info "Promoting 'organization' scope to default on M2M clients..."
promote_scope_to_default "$KC_B" "realm-b" "app-a-m2m-client" "organization" "$TOKEN_B"
promote_scope_to_default "$KC_C" "realm-c" "app-b-m2m-client" "organization" "$TOKEN_C"
echo "" >&2

echo "==============================================" >&2
log_info "Minimal provisioning complete!"
echo "" >&2
echo "  Realm-B: Org 'kc-a-external-users' (linked to kc-a-idp)" >&2
echo "  Realm-C: Org 'kc-b-external-users' (linked to kc-b-idp)" >&2
echo "" >&2
echo "  No users pre-created — the JIT SPI will create them on first JWT Grant." >&2
echo "==============================================" >&2
