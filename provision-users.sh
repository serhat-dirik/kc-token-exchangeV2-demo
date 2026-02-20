#!/bin/bash
# =============================================================================
# Full provisioning: users, organizations, and federated identity links
# for JWT Authorization Grant with KC 26 Organizations.
#
# This is the "pre-provisioning" approach where all users are created upfront.
# For the JIT approach (Custom SPI), use provision-minimal.sh instead.
#
# Architecture:
#   KC-A (realm-a) → external IDP, source of truth for users
#   KC-B (realm-b) → creates Org "kc-a-external-users", links kc-a-idp
#   KC-C (realm-c) → creates Org "kc-b-external-users", links kc-b-idp
#
# Username namespacing:
#   Users federated from KC-A into KC-B get username: kc-a-idp.<original>
#   Users federated from KC-B into KC-C get username: kc-b-idp.kc-a-idp.<original>
#   This prevents conflicts with local users (e.g., local "bob" vs "kc-a-idp.bob")
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/provision-common.sh"

KC_A="http://localhost:8180"
KC_B="http://localhost:8280"
KC_C="http://localhost:8380"

ADMIN_USER="admin"
ADMIN_PASS="admin"

echo "==============================================" >&2
echo " Full Provisioning: users, orgs & federated links" >&2
echo " for JWT Authorization Grant with Organizations" >&2
echo "==============================================" >&2
echo "" >&2

# ---- Step 1: Get admin tokens ----
log_info "Getting admin tokens..."
TOKEN_A=$(get_admin_token "$KC_A") || { log_error "Cannot get admin token for KC-A"; exit 1; }
TOKEN_B=$(get_admin_token "$KC_B") || { log_error "Cannot get admin token for KC-B"; exit 1; }
TOKEN_C=$(get_admin_token "$KC_C") || { log_error "Cannot get admin token for KC-C"; exit 1; }
log_info "Admin tokens acquired for all 3 KC instances."
echo "" >&2

# ---- Step 2: Get user IDs from KC-A (realm-a) ----
log_info "Reading users from KC-A (realm-a)..."

ALICE_A_ID=$(get_user_id "$KC_A" "realm-a" "alice" "$TOKEN_A")
BOB_A_ID=$(get_user_id "$KC_A" "realm-a" "bob" "$TOKEN_A")

if [ -z "$ALICE_A_ID" ]; then
    log_error "User 'alice' not found in realm-a!"
    exit 1
fi
if [ -z "$BOB_A_ID" ]; then
    log_error "User 'bob' not found in realm-a!"
    exit 1
fi

log_info "  alice (realm-a): ${ALICE_A_ID}"
log_info "  bob   (realm-a): ${BOB_A_ID}"
echo "" >&2

# ---- Step 3: Create users in KC-B (realm-b) with namespaced usernames ----
#
# Username format: ${IDP_ALIAS}.${original_username}
# This matches the IDP username mapper template: ${ALIAS}.${CLAIM.preferred_username}
# Result: "kc-a-idp.alice" and "kc-a-idp.bob" — clearly distinguishable from any
# local KC-B users like "alice" or "bob".
#
log_info "Provisioning users in KC-B (realm-b) with namespaced usernames..."

ALICE_B_ID=$(create_user "$KC_B" "realm-b" "kc-a-idp.alice" "alice@example.com" "Alice" "Smith" "$TOKEN_B" "kc-a")
BOB_B_ID=$(create_user "$KC_B" "realm-b" "kc-a-idp.bob" "bob@example.com" "Bob" "Jones" "$TOKEN_B" "kc-a")

log_info "Creating federated identity links to kc-a-idp..."
# The federated_username is the upstream username as known in realm-a
create_federated_link "$KC_B" "realm-b" "$ALICE_B_ID" "kc-a-idp" "$ALICE_A_ID" "alice" "$TOKEN_B"
create_federated_link "$KC_B" "realm-b" "$BOB_B_ID" "kc-a-idp" "$BOB_A_ID" "bob" "$TOKEN_B"
echo "" >&2

# ---- Step 4: Create users in KC-C (realm-c) with chained namespaced usernames ----
#
# Username format: ${IDP_ALIAS}.${upstream_username}
# Since the upstream (KC-B) username is already namespaced (kc-a-idp.alice),
# the KC-C username becomes: kc-b-idp.kc-a-idp.alice
# This shows full provenance: "came from kc-b-idp, where they were kc-a-idp.alice"
#
log_info "Provisioning users in KC-C (realm-c) with chained namespaced usernames..."

ALICE_C_ID=$(create_user "$KC_C" "realm-c" "kc-b-idp.kc-a-idp.alice" "alice@example.com" "Alice" "Smith" "$TOKEN_C" "kc-b")
BOB_C_ID=$(create_user "$KC_C" "realm-c" "kc-b-idp.kc-a-idp.bob" "bob@example.com" "Bob" "Jones" "$TOKEN_C" "kc-b")

log_info "Creating federated identity links to kc-b-idp..."
# The federated_username is the upstream username as known in realm-b (namespaced)
create_federated_link "$KC_C" "realm-c" "$ALICE_C_ID" "kc-b-idp" "$ALICE_B_ID" "kc-a-idp.alice" "$TOKEN_C"
create_federated_link "$KC_C" "realm-c" "$BOB_C_ID" "kc-b-idp" "$BOB_B_ID" "kc-a-idp.bob" "$TOKEN_C"
echo "" >&2

# ---- Step 5: Create Organizations and link IDPs ----
#
# Organizations group federated users by their origin IDP.
# This is IDP-based membership (NOT email-domain-based) — the org boundary
# is defined by "users who came from this IDP", not by email domain.
#
log_info "Creating organizations and linking IDPs..."
echo "" >&2

# Realm-B: Organization for users from KC-A
log_org "Setting up organization in realm-b..."
ORG_B_ID=$(create_organization "$KC_B" "realm-b" "kc-a-external-users" \
    "Users federated from KC-A (realm-a) via kc-a-idp identity provider" "$TOKEN_B")

if [ -n "$ORG_B_ID" ]; then
    link_idp_to_organization "$KC_B" "realm-b" "$ORG_B_ID" "kc-a-idp" "$TOKEN_B"
    add_org_member "$KC_B" "realm-b" "$ORG_B_ID" "$ALICE_B_ID" "kc-a-idp.alice" "$TOKEN_B"
    add_org_member "$KC_B" "realm-b" "$ORG_B_ID" "$BOB_B_ID" "kc-a-idp.bob" "$TOKEN_B"
fi
echo "" >&2

# Realm-C: Organization for users from KC-B
log_org "Setting up organization in realm-c..."
ORG_C_ID=$(create_organization "$KC_C" "realm-c" "kc-b-external-users" \
    "Users federated from KC-B (realm-b) via kc-b-idp identity provider" "$TOKEN_C")

if [ -n "$ORG_C_ID" ]; then
    link_idp_to_organization "$KC_C" "realm-c" "$ORG_C_ID" "kc-b-idp" "$TOKEN_C"
    add_org_member "$KC_C" "realm-c" "$ORG_C_ID" "$ALICE_C_ID" "kc-b-idp.kc-a-idp.alice" "$TOKEN_C"
    add_org_member "$KC_C" "realm-c" "$ORG_C_ID" "$BOB_C_ID" "kc-b-idp.kc-a-idp.bob" "$TOKEN_C"
fi
echo "" >&2

# ---- Step 6: Register 'origin' attribute in user profile ----
log_info "Registering 'origin' attribute in user profiles..."
add_user_profile_attribute "$KC_B" "realm-b" "origin" "$TOKEN_B"
add_user_profile_attribute "$KC_C" "realm-c" "origin" "$TOKEN_C"
echo "" >&2

# ---- Step 7: Promote 'organization' client scope to default on M2M clients ----
log_info "Promoting 'organization' scope to default on M2M clients..."
promote_scope_to_default "$KC_B" "realm-b" "app-a-m2m-client" "organization" "$TOKEN_B"
promote_scope_to_default "$KC_C" "realm-c" "app-b-m2m-client" "organization" "$TOKEN_C"
echo "" >&2

echo "==============================================" >&2
log_info "Full provisioning complete!"
echo "" >&2
echo "  Realm-A: alice, bob (source users)" >&2
echo "  Realm-B: kc-a-idp.alice, kc-a-idp.bob" >&2
echo "           Org: kc-a-external-users (linked to kc-a-idp)" >&2
echo "  Realm-C: kc-b-idp.kc-a-idp.alice, kc-b-idp.kc-a-idp.bob" >&2
echo "           Org: kc-b-external-users (linked to kc-b-idp)" >&2
echo "" >&2
echo "  JWT Authorization Grant chain with Organizations is ready." >&2
echo "==============================================" >&2
