#!/bin/bash
# =============================================================================
# Shared provisioning helper functions for Keycloak admin operations.
#
# Sourced by:
#   - provision-users.sh  (full provisioning: users + orgs + links)
#   - provision-minimal.sh (minimal: orgs + IDP links + scope only)
#
# All functions are idempotent and safe to run multiple times.
# =============================================================================

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $1" >&2; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_org()   { echo -e "${CYAN}[ORG]${NC}   $1" >&2; }

# Get admin access token for a KC instance
get_admin_token() {
    local kc_url="$1"
    curl -sf -X POST "${kc_url}/realms/master/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=password&client_id=admin-cli&username=${ADMIN_USER:-admin}&password=${ADMIN_PASS:-admin}" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null
}

# Get user ID by username from a realm
get_user_id() {
    local kc_url="$1"
    local realm="$2"
    local username="$3"
    local token="$4"
    curl -sf "${kc_url}/admin/realms/${realm}/users?username=${username}&exact=true" \
        -H "Authorization: Bearer ${token}" \
        | python3 -c "import sys,json; users=json.load(sys.stdin); print(users[0]['id'] if users else '')" 2>/dev/null
}

# Create user in a realm (idempotent - skips if exists)
# Supports optional origin attribute for tracking which IDP the user came from
create_user() {
    local kc_url="$1"
    local realm="$2"
    local username="$3"
    local email="$4"
    local first_name="$5"
    local last_name="$6"
    local token="$7"
    local origin="$8"  # optional: origin attribute value (e.g., "kc-a")

    # Check if user already exists
    local existing_id
    existing_id=$(get_user_id "$kc_url" "$realm" "$username" "$token")
    if [ -n "$existing_id" ]; then
        log_warn "  User '${username}' already exists in ${realm} (id: ${existing_id})"
        echo "$existing_id"
        return 0
    fi

    # Build user JSON with optional origin attribute
    local user_json
    if [ -n "$origin" ]; then
        user_json="{
            \"username\": \"${username}\",
            \"email\": \"${email}\",
            \"firstName\": \"${first_name}\",
            \"lastName\": \"${last_name}\",
            \"enabled\": true,
            \"emailVerified\": true,
            \"attributes\": {
                \"origin\": [\"${origin}\"]
            }
        }"
    else
        user_json="{
            \"username\": \"${username}\",
            \"email\": \"${email}\",
            \"firstName\": \"${first_name}\",
            \"lastName\": \"${last_name}\",
            \"enabled\": true,
            \"emailVerified\": true
        }"
    fi

    # Create the user
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${kc_url}/admin/realms/${realm}/users" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "$user_json")

    if [ "$http_code" = "201" ] || [ "$http_code" = "409" ]; then
        local new_id
        new_id=$(get_user_id "$kc_url" "$realm" "$username" "$token")
        log_info "  Created user '${username}' in ${realm} (id: ${new_id})"
        echo "$new_id"
        return 0
    else
        log_error "  Failed to create user '${username}' in ${realm} (HTTP ${http_code})"
        return 1
    fi
}

# Create federated identity link (idempotent - skips if exists)
create_federated_link() {
    local kc_url="$1"
    local realm="$2"
    local user_id="$3"
    local idp_alias="$4"
    local federated_user_id="$5"
    local federated_username="$6"
    local token="$7"

    # Check if link already exists
    local existing_links
    existing_links=$(curl -sf "${kc_url}/admin/realms/${realm}/users/${user_id}/federated-identity" \
        -H "Authorization: Bearer ${token}")
    if echo "$existing_links" | python3 -c "import sys,json; links=json.load(sys.stdin); exit(0 if any(l['identityProvider']=='${idp_alias}' for l in links) else 1)" 2>/dev/null; then
        log_warn "  Federated link to '${idp_alias}' already exists for user in ${realm}"
        return 0
    fi

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        "${kc_url}/admin/realms/${realm}/users/${user_id}/federated-identity/${idp_alias}" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "{
            \"identityProvider\": \"${idp_alias}\",
            \"userId\": \"${federated_user_id}\",
            \"userName\": \"${federated_username}\"
        }")

    if [ "$http_code" = "204" ] || [ "$http_code" = "409" ]; then
        log_info "  Linked user to IDP '${idp_alias}' in ${realm} (upstream id: ${federated_user_id})"
        return 0
    else
        log_error "  Failed to create federated link in ${realm} (HTTP ${http_code})"
        return 1
    fi
}

# Create an Organization (idempotent - skips if exists)
create_organization() {
    local kc_url="$1"
    local realm="$2"
    local org_name="$3"
    local org_description="$4"
    local token="$5"

    # Check if org already exists
    local existing
    existing=$(curl -sf "${kc_url}/admin/realms/${realm}/organizations?search=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${org_name}'))")" \
        -H "Authorization: Bearer ${token}" \
        | python3 -c "
import sys,json
orgs = json.load(sys.stdin)
for o in orgs:
    if o.get('name') == '${org_name}':
        print(o['id'])
        break
" 2>/dev/null)

    if [ -n "$existing" ]; then
        log_warn "  Organization '${org_name}' already exists in ${realm} (id: ${existing})"
        echo "$existing"
        return 0
    fi

    # Create the org — extract ID from Location header
    local response_headers
    response_headers=$(curl -s -D - -o /dev/null -X POST \
        "${kc_url}/admin/realms/${realm}/organizations" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"${org_name}\",
            \"description\": \"${org_description}\",
            \"enabled\": true
        }")

    local org_id
    org_id=$(echo "$response_headers" | grep -i "^location:" | sed 's|.*/||' | tr -d '\r\n')
    if [ -n "$org_id" ]; then
        log_org "  Created organization '${org_name}' in ${realm} (id: ${org_id})"
        echo "$org_id"
        return 0
    else
        log_error "  Failed to create organization '${org_name}' in ${realm}"
        log_error "  Response: $(echo "$response_headers" | head -5)"
        return 1
    fi
}

# Link an IDP to an Organization
link_idp_to_organization() {
    local kc_url="$1"
    local realm="$2"
    local org_id="$3"
    local idp_alias="$4"
    local token="$5"

    # Check if already linked
    local existing_idps
    existing_idps=$(curl -sf "${kc_url}/admin/realms/${realm}/organizations/${org_id}/identity-providers" \
        -H "Authorization: Bearer ${token}" 2>/dev/null || echo "[]")
    if echo "$existing_idps" | python3 -c "import sys,json; idps=json.load(sys.stdin); exit(0 if any(i.get('alias')=='${idp_alias}' for i in idps) else 1)" 2>/dev/null; then
        log_warn "  IDP '${idp_alias}' already linked to organization in ${realm}"
        return 0
    fi

    # KC 26 org API expects the IDP alias as a plain string body
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        "${kc_url}/admin/realms/${realm}/organizations/${org_id}/identity-providers" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "\"${idp_alias}\"")

    if [ "$http_code" = "204" ] || [ "$http_code" = "201" ] || [ "$http_code" = "409" ]; then
        log_org "  Linked IDP '${idp_alias}' to organization in ${realm}"
        return 0
    else
        log_error "  Failed to link IDP '${idp_alias}' to organization (HTTP ${http_code})"
        return 1
    fi
}

# Add a user as a member of an Organization
add_org_member() {
    local kc_url="$1"
    local realm="$2"
    local org_id="$3"
    local user_id="$4"
    local username="$5"
    local token="$6"

    # Check if already a member
    local existing_members
    existing_members=$(curl -sf "${kc_url}/admin/realms/${realm}/organizations/${org_id}/members" \
        -H "Authorization: Bearer ${token}" 2>/dev/null || echo "[]")
    if echo "$existing_members" | python3 -c "import sys,json; members=json.load(sys.stdin); exit(0 if any(m.get('id')=='${user_id}' for m in members) else 1)" 2>/dev/null; then
        log_warn "  User '${username}' already a member of organization in ${realm}"
        return 0
    fi

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        "${kc_url}/admin/realms/${realm}/organizations/${org_id}/members" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "\"${user_id}\"")

    if [ "$http_code" = "204" ] || [ "$http_code" = "201" ] || [ "$http_code" = "409" ]; then
        log_org "  Added '${username}' as member of organization in ${realm}"
        return 0
    else
        log_error "  Failed to add '${username}' to organization (HTTP ${http_code})"
        return 1
    fi
}

# Add a custom attribute to the realm's User Profile (idempotent).
# KC 26 declarative user profiles require attributes to be registered
# before they appear in admin API responses.
add_user_profile_attribute() {
    local kc_url="$1"
    local realm="$2"
    local attr_name="$3"
    local token="$4"

    # Get current user profile config
    local profile_json
    profile_json=$(curl -sf "${kc_url}/admin/realms/${realm}/users/profile" \
        -H "Authorization: Bearer ${token}") || return 1

    # Check if attribute already exists
    local exists
    exists=$(echo "$profile_json" | python3 -c "
import sys,json
data = json.load(sys.stdin)
for attr in data.get('attributes', []):
    if attr.get('name') == '${attr_name}':
        print('yes')
        break
else:
    print('no')
" 2>/dev/null)

    if [ "$exists" = "yes" ]; then
        log_warn "  User profile attribute '${attr_name}' already exists in ${realm}"
        return 0
    fi

    # Add the attribute to the profile config
    local updated_json
    updated_json=$(echo "$profile_json" | python3 -c "
import sys,json
data = json.load(sys.stdin)
data.setdefault('attributes', []).append({
    'name': '${attr_name}',
    'displayName': '${attr_name}',
    'permissions': {
        'view': ['admin', 'user'],
        'edit': ['admin']
    },
    'multivalued': False
})
print(json.dumps(data))
" 2>/dev/null)

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
        "${kc_url}/admin/realms/${realm}/users/profile" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "$updated_json")

    if [ "$http_code" = "200" ] || [ "$http_code" = "204" ]; then
        log_info "  Added '${attr_name}' to user profile in ${realm}"
        return 0
    else
        log_warn "  Could not add '${attr_name}' to user profile in ${realm} (HTTP ${http_code})"
        return 0
    fi
}

# Promote a client scope to default for a specific client
promote_scope_to_default() {
    local kc_url="$1"
    local realm="$2"
    local client_id_name="$3"  # clientId string, e.g., "app-a-m2m-client"
    local scope_name="$4"      # scope name, e.g., "organization"
    local token="$5"

    # Get scope ID
    local scope_id
    scope_id=$(curl -sf "${kc_url}/admin/realms/${realm}/client-scopes" \
        -H "Authorization: Bearer ${token}" \
        | python3 -c "
import sys,json
scopes = json.load(sys.stdin)
for s in scopes:
    if s.get('name') == '${scope_name}':
        print(s['id'])
        break
" 2>/dev/null)

    if [ -z "$scope_id" ]; then
        log_warn "  Client scope '${scope_name}' not found in ${realm} — it may not be auto-created yet"
        return 0
    fi

    # Get client internal ID
    local client_internal_id
    client_internal_id=$(curl -sf "${kc_url}/admin/realms/${realm}/clients?clientId=${client_id_name}" \
        -H "Authorization: Bearer ${token}" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])" 2>/dev/null)

    if [ -z "$client_internal_id" ]; then
        log_error "  Client '${client_id_name}' not found in ${realm}"
        return 1
    fi

    # Promote to default client scope
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
        "${kc_url}/admin/realms/${realm}/clients/${client_internal_id}/default-client-scopes/${scope_id}" \
        -H "Authorization: Bearer ${token}")

    if [ "$http_code" = "204" ] || [ "$http_code" = "200" ]; then
        log_org "  Promoted '${scope_name}' to default scope on '${client_id_name}' in ${realm}"
        return 0
    else
        log_warn "  Could not promote '${scope_name}' scope (HTTP ${http_code}) — may already be default"
        return 0
    fi
}
