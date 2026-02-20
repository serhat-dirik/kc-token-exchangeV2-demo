#!/bin/bash
# =============================================================================
# End-to-end test for KC Token Exchange V2 Demo with Organizations
#
# Supports two modes:
#   ./test.sh                      # Default: provisioning mode
#   ./test.sh --mode provisioning  # Explicit provisioning mode
#   ./test.sh --mode spi           # SPI mode (JIT user creation)
#
# Tests the full JWT Authorization Grant chain:
#   KC-A → KC-B → KC-C (token exchange)
#   App-A → App-B → App-C (service chaining)
#
# Also verifies:
#   - Username namespacing (kc-a-idp.alice, kc-b-idp.kc-a-idp.alice)
#   - Organization claims in tokens (kc-a-external-users, kc-b-external-users)
#
# Mode-specific tests:
#   provisioning: Verifies users were pre-provisioned before JWT Grant
#   spi:          Creates a fresh user (charlie), tests JIT creation, org membership
#
# Prerequisites: All 3 KC instances and all 3 Quarkus apps must be running.
# =============================================================================

set -e

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

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0

pass() { echo -e "  ${GREEN}✅ PASS${NC}: $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}❌ FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "${YELLOW}$1${NC}"; }
mode_info() { echo -e "${CYAN}$1${NC}"; }

# Helper: get admin token for a KC instance
get_admin_token() {
  local kc_url="$1"
  curl -sf -X POST "${kc_url}/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=password&client_id=admin-cli&username=admin&password=admin" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null
}

echo ""
echo "═══════════════════════════════════════════════"
echo -e " KC Token Exchange V2 Demo — Test Suite"
echo -e " Mode: ${CYAN}${MODE}${NC}"
echo "═══════════════════════════════════════════════"
echo ""

# ---------------------------------------------------------------------------
info "=== Infrastructure Health Checks ==="
# ---------------------------------------------------------------------------

for port in 8180 8280 8380; do
  realm="realm-$(echo $port | sed 's/8180/a/;s/8280/b/;s/8380/c/')"
  if curl -sf -o /dev/null "http://localhost:$port/realms/$realm"; then
    pass "KC on port $port ($realm) is up"
  else
    fail "KC on port $port ($realm) is down"
  fi
done

if curl -sf -o /dev/null http://localhost:8081/; then
  pass "App-A (8081) is up"
else
  fail "App-A (8081) is down"
fi

for port in 8082 8083; do
  code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$port/api/hello")
  if [ "$code" = "401" ]; then
    pass "App on port $port is up (401 = needs auth)"
  else
    fail "App on port $port returned unexpected HTTP $code"
  fi
done

# ===========================================================================
# MODE-SPECIFIC: Provisioning pre-existence checks
# ===========================================================================
if [ "$MODE" = "provisioning" ]; then
  info ""
  mode_info "=== [PROVISIONING] Pre-Provisioned User Verification ==="

  ADMIN_TOKEN_B=$(get_admin_token "http://localhost:8280") || true
  if [ -n "$ADMIN_TOKEN_B" ]; then
    # Check alice exists in realm-b before any JWT Grant
    ALICE_B_EXISTS=$(curl -sf "http://localhost:8280/admin/realms/realm-b/users?username=kc-a-idp.alice&exact=true" \
      -H "Authorization: Bearer $ADMIN_TOKEN_B" \
      | python3 -c "import sys,json; users=json.load(sys.stdin); print('yes' if users else 'no')" 2>/dev/null)
    [ "$ALICE_B_EXISTS" = "yes" ] && pass "User 'kc-a-idp.alice' pre-exists in realm-b" || fail "User 'kc-a-idp.alice' NOT found in realm-b (should be pre-provisioned)"

    # Check bob exists in realm-b
    BOB_B_EXISTS=$(curl -sf "http://localhost:8280/admin/realms/realm-b/users?username=kc-a-idp.bob&exact=true" \
      -H "Authorization: Bearer $ADMIN_TOKEN_B" \
      | python3 -c "import sys,json; users=json.load(sys.stdin); print('yes' if users else 'no')" 2>/dev/null)
    [ "$BOB_B_EXISTS" = "yes" ] && pass "User 'kc-a-idp.bob' pre-exists in realm-b" || fail "User 'kc-a-idp.bob' NOT found in realm-b (should be pre-provisioned)"
  else
    fail "Could not get admin token for KC-B"
  fi

  ADMIN_TOKEN_C=$(get_admin_token "http://localhost:8380") || true
  if [ -n "$ADMIN_TOKEN_C" ]; then
    # Check alice exists in realm-c
    ALICE_C_EXISTS=$(curl -sf "http://localhost:8380/admin/realms/realm-c/users?username=kc-b-idp.kc-a-idp.alice&exact=true" \
      -H "Authorization: Bearer $ADMIN_TOKEN_C" \
      | python3 -c "import sys,json; users=json.load(sys.stdin); print('yes' if users else 'no')" 2>/dev/null)
    [ "$ALICE_C_EXISTS" = "yes" ] && pass "User 'kc-b-idp.kc-a-idp.alice' pre-exists in realm-c" || fail "User 'kc-b-idp.kc-a-idp.alice' NOT found in realm-c (should be pre-provisioned)"
  else
    fail "Could not get admin token for KC-C"
  fi
fi

# ---------------------------------------------------------------------------
info ""
info "=== Token Tests (alice) ==="
# ---------------------------------------------------------------------------

# Get KC-A token for alice
TOKEN_A=$(curl -sf -X POST "http://localhost:8180/realms/realm-a/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&client_id=app-a-client&client_secret=app-a-secret&username=alice&password=alice&scope=openid" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null) || true

if [ -n "$TOKEN_A" ]; then
  pass "KC-A token obtained for alice"
else
  fail "Could not get KC-A token for alice"
fi

# Verify token claims
if [ -n "$TOKEN_A" ]; then
  CLAIMS=$(echo "$TOKEN_A" | python3 -c "
import sys,json,base64
token = sys.stdin.read().strip()
payload = token.split('.')[1]
payload += '=' * (4 - len(payload) % 4)
claims = json.loads(base64.b64decode(payload))
aud = claims.get('aud')
roles = claims.get('realm_access', {}).get('roles', [])
username = claims.get('preferred_username', '')
email = claims.get('email', '')
# Audience should be exactly the downstream KC issuer
aud_ok = aud == 'http://localhost:8280/realms/realm-b'
roles_ok = 'user' in roles and 'admin' in roles
print(f'{aud_ok}|{roles_ok}|{username}|{email}|{aud}|{roles}')
" 2>/dev/null)

  AUD_OK=$(echo "$CLAIMS" | cut -d'|' -f1)
  ROLES_OK=$(echo "$CLAIMS" | cut -d'|' -f2)
  USERNAME=$(echo "$CLAIMS" | cut -d'|' -f3)
  EMAIL=$(echo "$CLAIMS" | cut -d'|' -f4)

  [ "$AUD_OK" = "True" ] && pass "Token audience = realm-b issuer URL (single aud)" || fail "Token audience mismatch: $(echo "$CLAIMS" | cut -d'|' -f5)"
  [ "$ROLES_OK" = "True" ] && pass "Token contains realm roles (user, admin)" || fail "Token roles missing: $(echo "$CLAIMS" | cut -d'|' -f6)"
  [ "$USERNAME" = "alice" ] && pass "Token preferred_username = alice" || fail "Token username: $USERNAME"
  [ "$EMAIL" = "alice@example.com" ] && pass "Token email = alice@example.com" || fail "Token email: $EMAIL"
fi

# ---------------------------------------------------------------------------
info ""
info "=== JWT Authorization Grant: KC-A → KC-B (alice) ==="
# ---------------------------------------------------------------------------

TOKEN_B=""
if [ -n "$TOKEN_A" ]; then
  RESULT_B=$(curl -s -X POST "http://localhost:8280/realms/realm-b/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=${TOKEN_A}&client_id=app-a-m2m-client&client_secret=app-a-m2m-secret&scope=openid%20organization")

  TOKEN_B=$(echo "$RESULT_B" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null) || true

  if [ -n "$TOKEN_B" ]; then
    pass "JWT Grant KC-A → KC-B succeeded"

    # Verify KC-B token claims
    B_CLAIMS=$(echo "$TOKEN_B" | python3 -c "
import sys,json,base64
token = sys.stdin.read().strip()
payload = token.split('.')[1]
payload += '=' * (4 - len(payload) % 4)
claims = json.loads(base64.b64decode(payload))
iss = claims.get('iss','')
username = claims.get('preferred_username','')
org = claims.get('organization', {})
# KC 26 org claim can be a list of names or a dict of {id: {name: ...}}
org_name = ''
if isinstance(org, list) and org:
    org_name = org[0]
elif isinstance(org, dict) and org:
    first_org = list(org.values())[0]
    org_name = first_org.get('name', list(org.keys())[0]) if isinstance(first_org, dict) else str(first_org)
print(f'{iss}|{username}|{org_name}')
" 2>/dev/null)

    ISS_B=$(echo "$B_CLAIMS" | cut -d'|' -f1)
    USERNAME_B=$(echo "$B_CLAIMS" | cut -d'|' -f2)
    ORG_NAME_B=$(echo "$B_CLAIMS" | cut -d'|' -f3)

    [ "$ISS_B" = "http://localhost:8280/realms/realm-b" ] && pass "KC-B token issuer correct" || fail "KC-B token issuer: $ISS_B"
    [ "$USERNAME_B" = "kc-a-idp.alice" ] && pass "KC-B token preferred_username = kc-a-idp.alice (namespaced)" || fail "KC-B token username: $USERNAME_B (expected kc-a-idp.alice)"
    [ "$ORG_NAME_B" = "kc-a-external-users" ] && pass "KC-B token organization = kc-a-external-users" || fail "KC-B org claim: '$ORG_NAME_B' (expected 'kc-a-external-users')"
  else
    ERROR_B=$(echo "$RESULT_B" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error_description','unknown'))" 2>/dev/null)
    fail "JWT Grant KC-A → KC-B failed: $ERROR_B"
  fi
fi

# ---------------------------------------------------------------------------
info ""
info "=== JWT Authorization Grant: KC-B → KC-C (alice) ==="
# ---------------------------------------------------------------------------

TOKEN_C=""
if [ -n "$TOKEN_B" ]; then
  RESULT_C=$(curl -s -X POST "http://localhost:8380/realms/realm-c/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=${TOKEN_B}&client_id=app-b-m2m-client&client_secret=app-b-m2m-secret&scope=openid%20organization")

  TOKEN_C=$(echo "$RESULT_C" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null) || true

  if [ -n "$TOKEN_C" ]; then
    pass "JWT Grant KC-B → KC-C succeeded"

    # Verify KC-C token claims
    C_CLAIMS=$(echo "$TOKEN_C" | python3 -c "
import sys,json,base64
token = sys.stdin.read().strip()
payload = token.split('.')[1]
payload += '=' * (4 - len(payload) % 4)
claims = json.loads(base64.b64decode(payload))
iss = claims.get('iss','')
username = claims.get('preferred_username','')
org = claims.get('organization', {})
org_name = ''
if isinstance(org, list) and org:
    org_name = org[0]
elif isinstance(org, dict) and org:
    first_org = list(org.values())[0]
    org_name = first_org.get('name', list(org.keys())[0]) if isinstance(first_org, dict) else str(first_org)
print(f'{iss}|{username}|{org_name}')
" 2>/dev/null)

    ISS_C=$(echo "$C_CLAIMS" | cut -d'|' -f1)
    USERNAME_C=$(echo "$C_CLAIMS" | cut -d'|' -f2)
    ORG_NAME_C=$(echo "$C_CLAIMS" | cut -d'|' -f3)

    [ "$ISS_C" = "http://localhost:8380/realms/realm-c" ] && pass "KC-C token issuer correct" || fail "KC-C token issuer: $ISS_C"
    [ "$USERNAME_C" = "kc-b-idp.kc-a-idp.alice" ] && pass "KC-C token preferred_username = kc-b-idp.kc-a-idp.alice (chained namespace)" || fail "KC-C token username: $USERNAME_C (expected kc-b-idp.kc-a-idp.alice)"
    [ "$ORG_NAME_C" = "kc-b-external-users" ] && pass "KC-C token organization = kc-b-external-users" || fail "KC-C org claim: '$ORG_NAME_C' (expected 'kc-b-external-users')"
  else
    ERROR_C=$(echo "$RESULT_C" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error_description','unknown'))" 2>/dev/null)
    fail "JWT Grant KC-B → KC-C failed: $ERROR_C"
  fi
fi

# ---------------------------------------------------------------------------
info ""
info "=== Service Chain: App-B → App-C (alice) ==="
# ---------------------------------------------------------------------------

# Get FRESH tokens for the chain test. KC marks JWT Grant assertions as single-use
# (jti tracking), so TOKEN_A and TOKEN_B from earlier tests are consumed.
CHAIN_TOKEN_A=$(curl -sf -X POST "http://localhost:8180/realms/realm-a/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&client_id=app-a-client&client_secret=app-a-secret&username=alice&password=alice&scope=openid" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null) || true

CHAIN_TOKEN_B=""
if [ -n "$CHAIN_TOKEN_A" ]; then
  CHAIN_TOKEN_B=$(curl -s -X POST "http://localhost:8280/realms/realm-b/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=${CHAIN_TOKEN_A}&client_id=app-a-m2m-client&client_secret=app-a-m2m-secret&scope=openid%20organization" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null) || true
fi

if [ -n "$CHAIN_TOKEN_B" ]; then
  CHAIN_RESPONSE=$(curl -sf "http://localhost:8082/api/hello" \
    -H "Authorization: Bearer ${CHAIN_TOKEN_B}" \
    -H "Accept: application/json" 2>/dev/null) || true

  if [ -n "$CHAIN_RESPONSE" ]; then
    # Parse chain results (avoid subshell to keep PASS/FAIL counting correct)
    CHAIN_RESULTS=$(echo "$CHAIN_RESPONSE" | python3 -c "
import sys,json
d = json.load(sys.stdin)
service = d.get('service','')
downstream = d.get('downstreamResponse','')
r = []
r.append('PASS_B' if service and 'App-B' in service else 'FAIL_B')
r.append('PASS_C' if downstream and 'App-C' in downstream else 'FAIL_C')
r.append('PASS_USER' if downstream and 'kc-a-idp.alice' in downstream else 'FAIL_USER')
print('|'.join(r))
" 2>/dev/null)

    IFS='|' read -r R_B R_C R_USER <<< "$CHAIN_RESULTS"

    if [ "$R_B" = "PASS_B" ]; then
      pass "App-B responded with service info"
    else
      fail "App-B response missing service info"
    fi
    if [ "$R_C" = "PASS_C" ]; then
      pass "App-C downstream response present (full chain)"
    else
      fail "App-C downstream response missing"
    fi
    if [ "$R_USER" = "PASS_USER" ]; then
      pass "Identity preserved across chain (kc-a-idp.alice)"
    else
      fail "Identity not preserved in downstream (expected kc-a-idp.alice)"
    fi
  else
    fail "App-B returned no response"
  fi
else
  fail "Could not get fresh TOKEN_B for chain test"
fi

# ---------------------------------------------------------------------------
info ""
info "=== Token Tests (bob) ==="
# ---------------------------------------------------------------------------

TOKEN_A_BOB=$(curl -sf -X POST "http://localhost:8180/realms/realm-a/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&client_id=app-a-client&client_secret=app-a-secret&username=bob&password=bob&scope=openid" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null) || true

if [ -n "$TOKEN_A_BOB" ]; then
  pass "KC-A token obtained for bob"
else
  fail "Could not get KC-A token for bob"
fi

TOKEN_B_BOB=""
if [ -n "$TOKEN_A_BOB" ]; then
  RESULT_B_BOB=$(curl -s -X POST "http://localhost:8280/realms/realm-b/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=${TOKEN_A_BOB}&client_id=app-a-m2m-client&client_secret=app-a-m2m-secret&scope=openid%20organization")

  TOKEN_B_BOB=$(echo "$RESULT_B_BOB" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null) || true

  if [ -n "$TOKEN_B_BOB" ]; then
    pass "JWT Grant KC-A → KC-B succeeded (bob)"

    # Verify namespaced username for bob
    USERNAME_B_BOB=$(echo "$TOKEN_B_BOB" | python3 -c "
import sys,json,base64
token = sys.stdin.read().strip()
payload = token.split('.')[1]
payload += '=' * (4 - len(payload) % 4)
print(json.loads(base64.b64decode(payload)).get('preferred_username',''))
" 2>/dev/null)
    [ "$USERNAME_B_BOB" = "kc-a-idp.bob" ] && pass "KC-B token preferred_username = kc-a-idp.bob (namespaced)" || fail "KC-B bob username: $USERNAME_B_BOB (expected kc-a-idp.bob)"
  else
    ERROR_BOB=$(echo "$RESULT_B_BOB" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error_description','unknown'))" 2>/dev/null)
    fail "JWT Grant KC-A → KC-B failed for bob: $ERROR_BOB"
  fi
fi

if [ -n "$TOKEN_B_BOB" ]; then
  CHAIN_BOB=$(curl -sf "http://localhost:8082/api/hello" \
    -H "Authorization: Bearer ${TOKEN_B_BOB}" \
    -H "Accept: application/json" 2>/dev/null) || true

  if echo "$CHAIN_BOB" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if 'kc-a-idp.bob' in d.get('downstreamResponse','') else 1)" 2>/dev/null; then
    pass "Full chain works for bob (App-B → App-C, identity: kc-a-idp.bob)"
  else
    fail "Chain incomplete for bob"
  fi
fi

# ---------------------------------------------------------------------------
info ""
info "=== UI Tests ==="
# ---------------------------------------------------------------------------

# Welcome page
if curl -sf http://localhost:8081/ | grep -q "Login"; then
  pass "Welcome page shows Login button"
else
  fail "Welcome page missing Login button"
fi

# Secured endpoint redirects to KC
REDIRECT_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-redirs 0 http://localhost:8081/secured 2>&1)
if [ "$REDIRECT_CODE" = "302" ]; then
  pass "Secured endpoint redirects to KC login (302)"
else
  fail "Secured endpoint returned $REDIRECT_CODE (expected 302)"
fi

# ===========================================================================
# MODE-SPECIFIC: SPI JIT Creation Tests
# ===========================================================================
if [ "$MODE" = "spi" ]; then
  info ""
  mode_info "=== [SPI] JIT User Creation Tests ==="
  mode_info "Creating fresh user 'charlie' in KC-A, testing JIT provisioning..."

  # Step 1: Create user 'charlie' in KC-A via admin API
  ADMIN_TOKEN_A=$(get_admin_token "http://localhost:8180") || true
  if [ -z "$ADMIN_TOKEN_A" ]; then
    fail "Could not get admin token for KC-A"
  else
    # Create charlie in realm-a (idempotent: skip if exists)
    CHARLIE_EXISTS=$(curl -sf "http://localhost:8180/admin/realms/realm-a/users?username=charlie&exact=true" \
      -H "Authorization: Bearer $ADMIN_TOKEN_A" \
      | python3 -c "import sys,json; users=json.load(sys.stdin); print('yes' if users else 'no')" 2>/dev/null)

    if [ "$CHARLIE_EXISTS" = "yes" ]; then
      info "  (charlie already exists in realm-a, reusing)"
    else
      HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        "http://localhost:8180/admin/realms/realm-a/users" \
        -H "Authorization: Bearer $ADMIN_TOKEN_A" \
        -H "Content-Type: application/json" \
        -d '{
          "username": "charlie",
          "email": "charlie@example.com",
          "firstName": "Charlie",
          "lastName": "Test",
          "enabled": true,
          "emailVerified": true,
          "credentials": [{"type": "password", "value": "charlie", "temporary": false}]
        }')

      if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "409" ]; then
        info "  Created user 'charlie' in realm-a"
      else
        fail "Failed to create charlie in realm-a (HTTP $HTTP_CODE)"
      fi
    fi

    # Assign roles to charlie (same as alice/bob)
    CHARLIE_ID=$(curl -sf "http://localhost:8180/admin/realms/realm-a/users?username=charlie&exact=true" \
      -H "Authorization: Bearer $ADMIN_TOKEN_A" \
      | python3 -c "import sys,json; users=json.load(sys.stdin); print(users[0]['id'] if users else '')" 2>/dev/null)

    if [ -n "$CHARLIE_ID" ]; then
      # Get role IDs for 'user' and 'admin'
      ROLES_JSON=$(curl -sf "http://localhost:8180/admin/realms/realm-a/roles" \
        -H "Authorization: Bearer $ADMIN_TOKEN_A")
      USER_ROLE=$(echo "$ROLES_JSON" | python3 -c "
import sys,json
roles = json.load(sys.stdin)
for r in roles:
    if r['name'] == 'user':
        print(json.dumps({'id': r['id'], 'name': r['name']}))
        break
" 2>/dev/null)
      ADMIN_ROLE=$(echo "$ROLES_JSON" | python3 -c "
import sys,json
roles = json.load(sys.stdin)
for r in roles:
    if r['name'] == 'admin':
        print(json.dumps({'id': r['id'], 'name': r['name']}))
        break
" 2>/dev/null)

      if [ -n "$USER_ROLE" ] && [ -n "$ADMIN_ROLE" ]; then
        curl -sf -o /dev/null -X POST \
          "http://localhost:8180/admin/realms/realm-a/users/$CHARLIE_ID/role-mappings/realm" \
          -H "Authorization: Bearer $ADMIN_TOKEN_A" \
          -H "Content-Type: application/json" \
          -d "[$USER_ROLE, $ADMIN_ROLE]" 2>/dev/null || true
      fi
    fi

    # Step 2: Verify charlie does NOT exist in realm-b yet (JIT hasn't fired)
    ADMIN_TOKEN_B=$(get_admin_token "http://localhost:8280") || true
    if [ -n "$ADMIN_TOKEN_B" ]; then
      CHARLIE_B_BEFORE=$(curl -sf "http://localhost:8280/admin/realms/realm-b/users?username=kc-a-idp.charlie&exact=true" \
        -H "Authorization: Bearer $ADMIN_TOKEN_B" \
        | python3 -c "import sys,json; users=json.load(sys.stdin); print('yes' if users else 'no')" 2>/dev/null)
      [ "$CHARLIE_B_BEFORE" = "no" ] && pass "User 'kc-a-idp.charlie' does NOT exist in realm-b before JWT Grant (JIT pending)" || info "  (charlie already exists in realm-b from a previous test run)"
    fi

    # Step 3: Get KC-A token for charlie
    TOKEN_A_CHARLIE=$(curl -sf -X POST "http://localhost:8180/realms/realm-a/protocol/openid-connect/token" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "grant_type=password&client_id=app-a-client&client_secret=app-a-secret&username=charlie&password=charlie&scope=openid" \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null) || true

    if [ -n "$TOKEN_A_CHARLIE" ]; then
      pass "KC-A token obtained for charlie"
    else
      fail "Could not get KC-A token for charlie"
    fi

    # Step 4: JWT Grant A→B for charlie (triggers JIT creation in KC-B)
    TOKEN_B_CHARLIE=""
    if [ -n "$TOKEN_A_CHARLIE" ]; then
      RESULT_B_CHARLIE=$(curl -s -X POST "http://localhost:8280/realms/realm-b/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=${TOKEN_A_CHARLIE}&client_id=app-a-m2m-client&client_secret=app-a-m2m-secret&scope=openid%20organization")

      TOKEN_B_CHARLIE=$(echo "$RESULT_B_CHARLIE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null) || true

      if [ -n "$TOKEN_B_CHARLIE" ]; then
        pass "JWT Grant KC-A → KC-B succeeded for charlie (JIT creation)"

        # Verify token claims
        CHARLIE_B_CLAIMS=$(echo "$TOKEN_B_CHARLIE" | python3 -c "
import sys,json,base64
token = sys.stdin.read().strip()
payload = token.split('.')[1]
payload += '=' * (4 - len(payload) % 4)
claims = json.loads(base64.b64decode(payload))
username = claims.get('preferred_username','')
org = claims.get('organization', {})
org_name = ''
if isinstance(org, list) and org:
    org_name = org[0]
elif isinstance(org, dict) and org:
    first_org = list(org.values())[0]
    org_name = first_org.get('name', list(org.keys())[0]) if isinstance(first_org, dict) else str(first_org)
print(f'{username}|{org_name}')
" 2>/dev/null)

        CHARLIE_USERNAME_B=$(echo "$CHARLIE_B_CLAIMS" | cut -d'|' -f1)
        CHARLIE_ORG_B=$(echo "$CHARLIE_B_CLAIMS" | cut -d'|' -f2)

        [ "$CHARLIE_USERNAME_B" = "kc-a-idp.charlie" ] && pass "KC-B token preferred_username = kc-a-idp.charlie (JIT namespaced)" || fail "KC-B charlie username: $CHARLIE_USERNAME_B (expected kc-a-idp.charlie)"
        [ "$CHARLIE_ORG_B" = "kc-a-external-users" ] && pass "KC-B token organization = kc-a-external-users (JIT org membership)" || fail "KC-B charlie org: '$CHARLIE_ORG_B' (expected 'kc-a-external-users')"
      else
        ERROR_CHARLIE=$(echo "$RESULT_B_CHARLIE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error_description','unknown'))" 2>/dev/null)
        fail "JWT Grant KC-A → KC-B failed for charlie (JIT): $ERROR_CHARLIE"
      fi
    fi

    # Step 5: Verify JIT-created user via KC-B admin API
    info ""
    mode_info "=== [SPI] JIT User Admin Verification ==="

    # Refresh admin token (may have expired)
    ADMIN_TOKEN_B=$(get_admin_token "http://localhost:8280") || true
    if [ -n "$ADMIN_TOKEN_B" ]; then
      # Check user exists with correct attributes
      CHARLIE_B_DATA=$(curl -sf "http://localhost:8280/admin/realms/realm-b/users?username=kc-a-idp.charlie&exact=true" \
        -H "Authorization: Bearer $ADMIN_TOKEN_B") || true

      CHARLIE_B_VERIFY=$(echo "$CHARLIE_B_DATA" | python3 -c "
import sys,json
users = json.load(sys.stdin)
if not users:
    print('not_found||||')
else:
    u = users[0]
    username = u.get('username', '')
    email = u.get('email', '')
    origin = u.get('attributes', {}).get('origin', [''])[0] if u.get('attributes') else ''
    first_name = u.get('firstName', '')
    print(f'{username}|{email}|{origin}|{first_name}')
" 2>/dev/null)

      CHARLIE_B_USERNAME=$(echo "$CHARLIE_B_VERIFY" | cut -d'|' -f1)
      CHARLIE_B_EMAIL=$(echo "$CHARLIE_B_VERIFY" | cut -d'|' -f2)
      CHARLIE_B_ORIGIN=$(echo "$CHARLIE_B_VERIFY" | cut -d'|' -f3)
      CHARLIE_B_FNAME=$(echo "$CHARLIE_B_VERIFY" | cut -d'|' -f4)

      [ "$CHARLIE_B_USERNAME" = "kc-a-idp.charlie" ] && pass "JIT user 'kc-a-idp.charlie' exists in realm-b admin API" || fail "JIT user not found in realm-b admin API (got: '$CHARLIE_B_USERNAME')"
      [ "$CHARLIE_B_ORIGIN" = "kc-a" ] && pass "JIT user has origin attribute = 'kc-a'" || fail "JIT user origin attribute: '$CHARLIE_B_ORIGIN' (expected 'kc-a')"
      [ "$CHARLIE_B_EMAIL" = "charlie@example.com" ] && pass "JIT user email = charlie@example.com" || fail "JIT user email: '$CHARLIE_B_EMAIL' (expected 'charlie@example.com')"
      [ "$CHARLIE_B_FNAME" = "Charlie" ] && pass "JIT user firstName = Charlie" || fail "JIT user firstName: '$CHARLIE_B_FNAME' (expected 'Charlie')"

      # Step 6: Verify org membership via admin API
      info ""
      mode_info "=== [SPI] JIT Organization Membership Verification ==="

      # Find the org ID for kc-a-external-users
      ORG_DATA=$(curl -sf "http://localhost:8280/admin/realms/realm-b/organizations?search=kc-a-external-users" \
        -H "Authorization: Bearer $ADMIN_TOKEN_B") || true

      ORG_ID=$(echo "$ORG_DATA" | python3 -c "
import sys,json
orgs = json.load(sys.stdin)
for o in orgs:
    if o.get('name') == 'kc-a-external-users':
        print(o['id'])
        break
" 2>/dev/null)

      if [ -n "$ORG_ID" ]; then
        # Check if charlie is a member
        ORG_MEMBERS=$(curl -sf "http://localhost:8280/admin/realms/realm-b/organizations/$ORG_ID/members" \
          -H "Authorization: Bearer $ADMIN_TOKEN_B") || true

        CHARLIE_IN_ORG=$(echo "$ORG_MEMBERS" | python3 -c "
import sys,json
members = json.load(sys.stdin)
for m in members:
    if m.get('username') == 'kc-a-idp.charlie':
        print('yes')
        break
else:
    print('no')
" 2>/dev/null)

        [ "$CHARLIE_IN_ORG" = "yes" ] && pass "JIT user 'kc-a-idp.charlie' is member of 'kc-a-external-users' org" || fail "JIT user NOT in 'kc-a-external-users' org"
      else
        fail "Organization 'kc-a-external-users' not found in realm-b"
      fi
    else
      fail "Could not get admin token for KC-B (admin verification)"
    fi

    # Step 7: JIT idempotency test — JWT Grant again for charlie
    info ""
    mode_info "=== [SPI] JIT Idempotency Test ==="

    TOKEN_A_CHARLIE2=$(curl -sf -X POST "http://localhost:8180/realms/realm-a/protocol/openid-connect/token" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "grant_type=password&client_id=app-a-client&client_secret=app-a-secret&username=charlie&password=charlie&scope=openid" \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null) || true

    if [ -n "$TOKEN_A_CHARLIE2" ]; then
      RESULT_B_CHARLIE2=$(curl -s -X POST "http://localhost:8280/realms/realm-b/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=${TOKEN_A_CHARLIE2}&client_id=app-a-m2m-client&client_secret=app-a-m2m-secret&scope=openid%20organization")

      TOKEN_B_CHARLIE2=$(echo "$RESULT_B_CHARLIE2" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null) || true

      if [ -n "$TOKEN_B_CHARLIE2" ]; then
        pass "JWT Grant idempotent — second charlie JWT Grant succeeded (no duplicate user)"
      else
        ERROR_CHARLIE2=$(echo "$RESULT_B_CHARLIE2" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error_description','unknown'))" 2>/dev/null)
        fail "Second JWT Grant for charlie failed (idempotency): $ERROR_CHARLIE2"
      fi
    fi

    # Step 8: Full chain test A→B→C for charlie
    info ""
    mode_info "=== [SPI] JIT Full Chain Test (charlie: A → B → C) ==="

    TOKEN_A_CHARLIE3=$(curl -sf -X POST "http://localhost:8180/realms/realm-a/protocol/openid-connect/token" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "grant_type=password&client_id=app-a-client&client_secret=app-a-secret&username=charlie&password=charlie&scope=openid" \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null) || true

    TOKEN_B_CHARLIE3=""
    if [ -n "$TOKEN_A_CHARLIE3" ]; then
      TOKEN_B_CHARLIE3=$(curl -s -X POST "http://localhost:8280/realms/realm-b/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=${TOKEN_A_CHARLIE3}&client_id=app-a-m2m-client&client_secret=app-a-m2m-secret&scope=openid%20organization" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null) || true
    fi

    TOKEN_C_CHARLIE=""
    if [ -n "$TOKEN_B_CHARLIE3" ]; then
      RESULT_C_CHARLIE=$(curl -s -X POST "http://localhost:8380/realms/realm-c/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=${TOKEN_B_CHARLIE3}&client_id=app-b-m2m-client&client_secret=app-b-m2m-secret&scope=openid%20organization")

      TOKEN_C_CHARLIE=$(echo "$RESULT_C_CHARLIE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null) || true

      if [ -n "$TOKEN_C_CHARLIE" ]; then
        pass "JWT Grant full chain A→B→C succeeded for charlie (JIT at both hops)"

        # Verify KC-C token claims for charlie
        CHARLIE_C_CLAIMS=$(echo "$TOKEN_C_CHARLIE" | python3 -c "
import sys,json,base64
token = sys.stdin.read().strip()
payload = token.split('.')[1]
payload += '=' * (4 - len(payload) % 4)
claims = json.loads(base64.b64decode(payload))
username = claims.get('preferred_username','')
org = claims.get('organization', {})
org_name = ''
if isinstance(org, list) and org:
    org_name = org[0]
elif isinstance(org, dict) and org:
    first_org = list(org.values())[0]
    org_name = first_org.get('name', list(org.keys())[0]) if isinstance(first_org, dict) else str(first_org)
print(f'{username}|{org_name}')
" 2>/dev/null)

        CHARLIE_USERNAME_C=$(echo "$CHARLIE_C_CLAIMS" | cut -d'|' -f1)
        CHARLIE_ORG_C=$(echo "$CHARLIE_C_CLAIMS" | cut -d'|' -f2)

        [ "$CHARLIE_USERNAME_C" = "kc-b-idp.kc-a-idp.charlie" ] && pass "KC-C token preferred_username = kc-b-idp.kc-a-idp.charlie (chained JIT)" || fail "KC-C charlie username: $CHARLIE_USERNAME_C (expected kc-b-idp.kc-a-idp.charlie)"
        [ "$CHARLIE_ORG_C" = "kc-b-external-users" ] && pass "KC-C token organization = kc-b-external-users (JIT org in realm-c)" || fail "KC-C charlie org: '$CHARLIE_ORG_C' (expected 'kc-b-external-users')"
      else
        ERROR_C_CHARLIE=$(echo "$RESULT_C_CHARLIE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error_description','unknown'))" 2>/dev/null)
        fail "JWT Grant KC-B → KC-C failed for charlie: $ERROR_C_CHARLIE"
      fi
    else
      fail "Could not get TOKEN_B for charlie full chain test"
    fi
  fi
fi

# ---------------------------------------------------------------------------
info ""
echo "═══════════════════════════════════════════════"
echo -e " Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}  (mode: ${MODE})"
echo "═══════════════════════════════════════════════"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
