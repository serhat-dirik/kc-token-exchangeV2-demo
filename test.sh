#!/bin/bash
# =============================================================================
# End-to-end test for KC Token Exchange V2 Demo with Organizations
#
# Supports two modes and optional OpenShift target:
#   ./test.sh                             # Default: provisioning mode (local)
#   ./test.sh --mode provisioning         # Explicit provisioning mode (local)
#   ./test.sh --mode spi                  # SPI mode (local, JIT user creation)
#   ./test.sh --openshift                 # Run against OpenShift (reads Route URLs)
#   ./test.sh --mode spi --openshift      # SPI mode on OpenShift
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
OPENSHIFT=false
DEBUG="${DEBUG:-false}"   # also settable via env: DEBUG=1 ./test.sh
while [[ $# -gt 0 ]]; do
  case $1 in
    --mode)
      MODE="$2"
      shift 2
      ;;
    --openshift)
      OPENSHIFT=true
      shift
      ;;
    --debug|-d)
      DEBUG=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--mode provisioning|spi] [--openshift] [--debug|-d]"
      exit 1
      ;;
  esac
done
# Normalize DEBUG to a strict true/false
case "$DEBUG" in 1|true|yes|on) DEBUG=true ;; *) DEBUG=false ;; esac

if [[ "$MODE" != "provisioning" && "$MODE" != "spi" ]]; then
  echo "ERROR: Invalid mode '$MODE'. Use 'provisioning' or 'spi'."
  exit 1
fi

# ---- Endpoint URLs (configurable via env vars or --openshift) ----
# Defaults target local development; --openshift reads Route URLs from the cluster.
if [[ "$OPENSHIFT" == "true" ]]; then
  OC_NS="${OC_NAMESPACE:-$(oc project -q 2>/dev/null)}"
  echo "Resolving OpenShift Route URLs (namespace: ${OC_NS})..."
  KC_A_URL="${KC_A_URL:-https://$(oc get route kc-a -n "$OC_NS" -o jsonpath='{.spec.host}' 2>/dev/null)}"
  KC_B_URL="${KC_B_URL:-https://$(oc get route kc-b -n "$OC_NS" -o jsonpath='{.spec.host}' 2>/dev/null)}"
  KC_C_URL="${KC_C_URL:-https://$(oc get route kc-c -n "$OC_NS" -o jsonpath='{.spec.host}' 2>/dev/null)}"
  APP_A_URL="${APP_A_URL:-https://$(oc get route app-a -n "$OC_NS" -o jsonpath='{.spec.host}' 2>/dev/null)}"
  APP_B_URL="${APP_B_URL:-http://app-b:8080}"
  APP_C_URL="${APP_C_URL:-http://app-c:8080}"
else
  KC_A_URL="${KC_A_URL:-http://localhost:8180}"
  KC_B_URL="${KC_B_URL:-http://localhost:8280}"
  KC_C_URL="${KC_C_URL:-http://localhost:8380}"
  APP_A_URL="${APP_A_URL:-http://localhost:8081}"
  APP_B_URL="${APP_B_URL:-http://localhost:8082}"
  APP_C_URL="${APP_C_URL:-http://localhost:8083}"
fi

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
DBG='\033[0;35m'    # magenta — debug narration & decoded tokens
BLUE='\033[1;34m'   # bold blue — debug TEST header
REQ='\033[1;36m'    # bold cyan — REQUEST label
RESP='\033[1;32m'   # bold green — RESPONSE label
NC='\033[0m'

PASS=0
FAIL=0

pass() { echo -e "  ${GREEN}✅ PASS${NC}: $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}❌ FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "${YELLOW}$1${NC}"; }
mode_info() { echo -e "${CYAN}$1${NC}"; }

# ---- Debug helpers (active only with --debug / DEBUG=1) ----
# IMPORTANT: these write to STDERR. Several callers run inside $(...) command
# substitution (e.g. ste_exchange, internal_status); anything sent to STDOUT
# there would corrupt the captured token/status. Always >&2, always return 0.
debug() { [ "$DEBUG" = true ] && echo -e "${DBG}   ⋮ $*${NC}" >&2; return 0; }
# debug_body BODY — pretty-print a JSON body to STDERR (indented 8 spaces).
# Long string values (JWTs, assertions) are truncated to "<first 24>…(<N> chars)"
# so token blobs collapse while structure + short claims stay readable.
# Falls back to a raw echo if the body isn't valid JSON. Always stderr, returns 0.
debug_body() {
  [ "$DEBUG" = true ] || return 0
  echo "$1" | python3 -c "
import sys, json
def trunc(v):
    if isinstance(v, str) and len(v) > 48:
        return v[:24] + '…(' + str(len(v)) + ' chars)'
    if isinstance(v, dict):
        return {k: trunc(x) for k, x in v.items()}
    if isinstance(v, list):
        return [trunc(x) for x in v]
    return v
raw = sys.stdin.read()
try:
    data = json.loads(raw)
except Exception:
    print(raw, end='')
    sys.exit(2)
print(json.dumps(trunc(data), indent=2, ensure_ascii=False))
" 2>/dev/null | sed 's/^/        /' >&2 \
    || echo "        $1" >&2
  return 0
}
# debug_jwt LABEL TOKEN — decode the JWT payload and show the claims that matter
debug_jwt() {
  [ "$DEBUG" = true ] || return 0
  echo -e "${DBG}   ⋮ $1${NC}" >&2
  echo "$2" | python3 -c "
import sys, json, base64
t = sys.stdin.read().strip()
if not t or t.count('.') < 1:
    print('        (no token)'); sys.exit()
try:
    p = t.split('.')[1]; p += '=' * (-len(p) % 4)
    c = json.loads(base64.urlsafe_b64decode(p))
except Exception as e:
    print('        (undecodable:', e, ')'); sys.exit()
ra = (c.get('realm_access') or {}).get('roles')
for k, v in [('preferred_username', c.get('preferred_username')),
             ('aud', c.get('aud')), ('azp', c.get('azp')),
             ('scope', c.get('scope')), ('realm_access.roles', ra)]:
    print(f'        {k:20}: {v}')
" >&2
  return 0
}
# debug_test NAME — blue header announcing which test/section is starting
debug_test() { [ "$DEBUG" = true ] && echo -e "${BLUE}▶ TEST: $*${NC}" >&2; return 0; }
# debug_req_post URL [data-pair ...] — print the ACTUAL copy-pasteable curl POST,
# with real values (the full token IS shown on purpose — that's the point of --debug).
debug_req_post() {
  [ "$DEBUG" = true ] || return 0
  local url="$1"; shift
  echo -e "${REQ}   ── REQUEST ──────────────────────────────────${NC}" >&2
  local cmd="curl -s -X POST '${url}'" d
  for d in "$@"; do cmd="${cmd} --data-urlencode '${d}'"; done
  echo -e "${CYAN}   ${cmd}${NC}" >&2
  return 0
}
# debug_req_get URL [AUTH_HEADER] — print the actual copy-pasteable curl GET.
debug_req_get() {
  [ "$DEBUG" = true ] || return 0
  local url="$1" auth="${2:-}"
  echo -e "${REQ}   ── REQUEST ──────────────────────────────────${NC}" >&2
  if [ -n "$auth" ]; then
    echo -e "${CYAN}   curl -s '${url}' -H '${auth}'${NC}" >&2
  else
    echo -e "${CYAN}   curl -s '${url}'${NC}" >&2
  fi
  return 0
}
# debug_resp BODY — green RESPONSE label, then the pretty/truncated body (debug_body).
debug_resp() {
  [ "$DEBUG" = true ] || return 0
  echo -e "${RESP}   ── RESPONSE ─────────────────────────────────${NC}" >&2
  debug_body "$1"
  return 0
}

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
if [ "$DEBUG" = true ]; then echo -e " Debug: ${DBG}ON${NC} — showing requests, responses & decoded tokens"; fi
echo "═══════════════════════════════════════════════"
echo ""

# ---------------------------------------------------------------------------
info "=== Infrastructure Health Checks ==="
debug_test "Infrastructure Health Checks"
# ---------------------------------------------------------------------------

for kc_entry in "KC-A:${KC_A_URL}:realm-a" "KC-B:${KC_B_URL}:realm-b" "KC-C:${KC_C_URL}:realm-c"; do
  kc_label="${kc_entry%%:*}"
  kc_rest="${kc_entry#*:}"
  kc_url="${kc_rest%:*}"
  kc_realm="${kc_rest##*:}"
  debug_req_get "${kc_url}/realms/${kc_realm}"
  if curl -sf -o /dev/null "${kc_url}/realms/${kc_realm}"; then
    pass "${kc_label} (${kc_realm}) is up"
  else
    fail "${kc_label} (${kc_realm}) is down"
  fi
done

debug_req_get "${APP_A_URL}/"
if curl -sf -o /dev/null "${APP_A_URL}/"; then
  pass "App-A is up"
else
  fail "App-A is down"
fi

if [[ "$OPENSHIFT" == "true" ]]; then
  info "  (App-B/App-C have no external Route — reachability verified via service chain tests)"
else
  for app_entry in "App-B:${APP_B_URL}" "App-C:${APP_C_URL}"; do
    app_label="${app_entry%%:*}"
    app_url="${app_entry#*:}"
    debug_req_get "${app_url}/api/hello"
    code=$(curl -s -o /dev/null -w "%{http_code}" "${app_url}/api/hello")
    if [ "$code" = "401" ]; then
      pass "${app_label} is up (401 = needs auth)"
    else
      fail "${app_label} returned unexpected HTTP $code"
    fi
  done
fi

# ===========================================================================
# MODE-SPECIFIC: Provisioning pre-existence checks
# ===========================================================================
if [ "$MODE" = "provisioning" ]; then
  info ""
  mode_info "=== [PROVISIONING] Pre-Provisioned User Verification ==="
  debug_test "[PROVISIONING] Pre-Provisioned User Verification"

  debug "Admin API: getting master-realm admin token for KC-B to inspect realm-b users"
  ADMIN_TOKEN_B=$(get_admin_token "${KC_B_URL}") || true
  if [ -n "$ADMIN_TOKEN_B" ]; then
    # Check alice exists in realm-b before any JWT Grant
    debug "Admin API: GET realm-b users?username=kc-a-idp.alice (expect pre-existing — provisioned ahead of any JWT grant)"
    ALICE_B_EXISTS=$(curl -sf "${KC_B_URL}/admin/realms/realm-b/users?username=kc-a-idp.alice&exact=true" \
      -H "Authorization: Bearer $ADMIN_TOKEN_B" \
      | python3 -c "import sys,json; users=json.load(sys.stdin); print('yes' if users else 'no')" 2>/dev/null)
    debug "lookup result: kc-a-idp.alice in realm-b → ${ALICE_B_EXISTS}"
    [ "$ALICE_B_EXISTS" = "yes" ] && pass "User 'kc-a-idp.alice' pre-exists in realm-b" || fail "User 'kc-a-idp.alice' NOT found in realm-b (should be pre-provisioned)"

    # Check bob exists in realm-b
    debug "Admin API: GET realm-b users?username=kc-a-idp.bob (expect pre-existing)"
    BOB_B_EXISTS=$(curl -sf "${KC_B_URL}/admin/realms/realm-b/users?username=kc-a-idp.bob&exact=true" \
      -H "Authorization: Bearer $ADMIN_TOKEN_B" \
      | python3 -c "import sys,json; users=json.load(sys.stdin); print('yes' if users else 'no')" 2>/dev/null)
    debug "lookup result: kc-a-idp.bob in realm-b → ${BOB_B_EXISTS}"
    [ "$BOB_B_EXISTS" = "yes" ] && pass "User 'kc-a-idp.bob' pre-exists in realm-b" || fail "User 'kc-a-idp.bob' NOT found in realm-b (should be pre-provisioned)"
  else
    fail "Could not get admin token for KC-B"
  fi

  debug "Admin API: getting master-realm admin token for KC-C to inspect realm-c users"
  ADMIN_TOKEN_C=$(get_admin_token "${KC_C_URL}") || true
  if [ -n "$ADMIN_TOKEN_C" ]; then
    # Check alice exists in realm-c
    debug "Admin API: GET realm-c users?username=kc-b-idp.kc-a-idp.alice (expect pre-existing — chained namespace, two hops deep)"
    ALICE_C_EXISTS=$(curl -sf "${KC_C_URL}/admin/realms/realm-c/users?username=kc-b-idp.kc-a-idp.alice&exact=true" \
      -H "Authorization: Bearer $ADMIN_TOKEN_C" \
      | python3 -c "import sys,json; users=json.load(sys.stdin); print('yes' if users else 'no')" 2>/dev/null)
    debug "lookup result: kc-b-idp.kc-a-idp.alice in realm-c → ${ALICE_C_EXISTS}"
    [ "$ALICE_C_EXISTS" = "yes" ] && pass "User 'kc-b-idp.kc-a-idp.alice' pre-exists in realm-c" || fail "User 'kc-b-idp.kc-a-idp.alice' NOT found in realm-c (should be pre-provisioned)"
  else
    fail "Could not get admin token for KC-C"
  fi
fi

# ---------------------------------------------------------------------------
info ""
info "=== Token Tests (alice) ==="
debug_test "Token Tests (alice)"
# ---------------------------------------------------------------------------

# Get KC-A token for alice
debug "Requesting KC-A token for alice (password grant, client_id=app-a-client, scope=openid) — this is the initial login token"
TOKEN_A=$(curl -sf -X POST "${KC_A_URL}/realms/realm-a/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&client_id=app-a-client&client_secret=app-a-secret&username=alice&password=alice&scope=openid" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null) || true

if [ -n "$TOKEN_A" ]; then
  pass "KC-A token obtained for alice"
  debug_jwt "KC-A access token — alice (login token)" "$TOKEN_A"
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
aud_ok = aud == '${KC_B_URL}/realms/realm-b'
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
debug_test "JWT Authorization Grant: KC-A → KC-B (alice)"
# ---------------------------------------------------------------------------

TOKEN_B=""
if [ -n "$TOKEN_A" ]; then
  debug "RFC 7523 JWT Authorization Grant — presenting the KC-A token to KC-B as a signed assertion to mint a realm-b token (cross-domain identity propagation, hop 1)"
  debug_req_post "${KC_B_URL}/realms/realm-b/protocol/openid-connect/token" \
    "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
    "assertion=${TOKEN_A}" \
    "client_id=app-a-m2m-client" "client_secret=app-a-m2m-secret" \
    "scope=openid organization"
  RESULT_B=$(curl -s -X POST "${KC_B_URL}/realms/realm-b/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=${TOKEN_A}&client_id=app-a-m2m-client&client_secret=app-a-m2m-secret&scope=openid%20organization")

  TOKEN_B=$(echo "$RESULT_B" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null) || true

  if [ -n "$TOKEN_B" ]; then
    pass "JWT Grant KC-A → KC-B succeeded"
    debug_resp "$RESULT_B"
    debug_jwt "KC-B access token — alice (after JWT grant hop 1)" "$TOKEN_B"

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

    [ "$ISS_B" = "${KC_B_URL}/realms/realm-b" ] && pass "KC-B token issuer correct" || fail "KC-B token issuer: $ISS_B"
    [ "$USERNAME_B" = "kc-a-idp.alice" ] && pass "KC-B token preferred_username = kc-a-idp.alice (namespaced)" || fail "KC-B token username: $USERNAME_B (expected kc-a-idp.alice)"
    [ "$ORG_NAME_B" = "kc-a-external-users" ] && pass "KC-B token organization = kc-a-external-users" || fail "KC-B org claim: '$ORG_NAME_B' (expected 'kc-a-external-users')"
  else
    debug "JWT grant failed:"
    debug_resp "$RESULT_B"
    ERROR_B=$(echo "$RESULT_B" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error_description','unknown'))" 2>/dev/null)
    fail "JWT Grant KC-A → KC-B failed: $ERROR_B"
  fi
fi

# ---------------------------------------------------------------------------
info ""
info "=== JWT Authorization Grant: KC-B → KC-C (alice) ==="
debug_test "JWT Authorization Grant: KC-B → KC-C (alice)"
# ---------------------------------------------------------------------------

TOKEN_C=""
if [ -n "$TOKEN_B" ]; then
  debug "RFC 7523 JWT Authorization Grant — now presenting the realm-b token to KC-C to mint a realm-c token (hop 2; the namespace deepens to kc-b-idp.kc-a-idp.*)"
  debug_req_post "${KC_C_URL}/realms/realm-c/protocol/openid-connect/token" \
    "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
    "assertion=${TOKEN_B}" \
    "client_id=app-b-m2m-client" "client_secret=app-b-m2m-secret" \
    "scope=openid organization"
  RESULT_C=$(curl -s -X POST "${KC_C_URL}/realms/realm-c/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=${TOKEN_B}&client_id=app-b-m2m-client&client_secret=app-b-m2m-secret&scope=openid%20organization")

  TOKEN_C=$(echo "$RESULT_C" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null) || true

  if [ -n "$TOKEN_C" ]; then
    pass "JWT Grant KC-B → KC-C succeeded"
    debug_resp "$RESULT_C"
    debug_jwt "KC-C access token — alice (after JWT grant hop 2)" "$TOKEN_C"

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

    [ "$ISS_C" = "${KC_C_URL}/realms/realm-c" ] && pass "KC-C token issuer correct" || fail "KC-C token issuer: $ISS_C"
    [ "$USERNAME_C" = "kc-b-idp.kc-a-idp.alice" ] && pass "KC-C token preferred_username = kc-b-idp.kc-a-idp.alice (chained namespace)" || fail "KC-C token username: $USERNAME_C (expected kc-b-idp.kc-a-idp.alice)"
    [ "$ORG_NAME_C" = "kc-b-external-users" ] && pass "KC-C token organization = kc-b-external-users" || fail "KC-C org claim: '$ORG_NAME_C' (expected 'kc-b-external-users')"
  else
    debug "JWT grant failed:"
    debug_resp "$RESULT_C"
    ERROR_C=$(echo "$RESULT_C" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error_description','unknown'))" 2>/dev/null)
    fail "JWT Grant KC-B → KC-C failed: $ERROR_C"
  fi
fi

# ---------------------------------------------------------------------------
info ""
info "=== Service Chain: App-B → App-C (alice) ==="
debug_test "Service Chain: App-B → App-C (alice)"
# ---------------------------------------------------------------------------

# Get FRESH tokens for the chain test. KC marks JWT Grant assertions as single-use
# (jti tracking), so TOKEN_A and TOKEN_B from earlier tests are consumed.
debug "KC tracks each assertion's jti as single-use → the earlier TOKEN_A/TOKEN_B are spent, so re-mint a fresh KC-A login token and a fresh KC-B token for the live service-chain call"
CHAIN_TOKEN_A=$(curl -sf -X POST "${KC_A_URL}/realms/realm-a/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&client_id=app-a-client&client_secret=app-a-secret&username=alice&password=alice&scope=openid" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null) || true
debug_jwt "fresh KC-A access token — alice (chain login token)" "$CHAIN_TOKEN_A"

CHAIN_TOKEN_B=""
if [ -n "$CHAIN_TOKEN_A" ]; then
  debug "JWT grant the fresh KC-A token up to KC-B to get the bearer App-B expects"
  debug_req_post "${KC_B_URL}/realms/realm-b/protocol/openid-connect/token" \
    "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
    "assertion=${CHAIN_TOKEN_A}" \
    "client_id=app-a-m2m-client" "client_secret=app-a-m2m-secret" \
    "scope=openid organization"
  CHAIN_TOKEN_B=$(curl -s -X POST "${KC_B_URL}/realms/realm-b/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=${CHAIN_TOKEN_A}&client_id=app-a-m2m-client&client_secret=app-a-m2m-secret&scope=openid%20organization" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null) || true
  debug_jwt "fresh KC-B access token — alice (chain bearer for App-B)" "$CHAIN_TOKEN_B"
fi

if [ -n "$CHAIN_TOKEN_B" ]; then
  if [[ "$OPENSHIFT" == "true" ]]; then
    # App-B has no external Route; call via oc exec from inside the cluster
    APP_B_POD=$(oc get pods -l app=app-b -n "$OC_NS" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    CHAIN_RESPONSE=$(oc exec "$APP_B_POD" -n "$OC_NS" -- curl -sf "http://localhost:8080/api/hello" \
      -H "Authorization: Bearer ${CHAIN_TOKEN_B}" \
      -H "Accept: application/json" 2>/dev/null) || true
  else
    debug_req_get "${APP_B_URL}/api/hello" "Authorization: Bearer ${CHAIN_TOKEN_B}"
    CHAIN_RESPONSE=$(curl -sf "${APP_B_URL}/api/hello" \
      -H "Authorization: Bearer ${CHAIN_TOKEN_B}" \
      -H "Accept: application/json" 2>/dev/null) || true
  fi

  if [ -n "$CHAIN_RESPONSE" ]; then
    debug "App-B chained response (downstreamResponse holds App-C's reply):"
    debug_resp "$CHAIN_RESPONSE"
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
debug_test "Token Tests (bob)"
# ---------------------------------------------------------------------------

debug "Requesting KC-A token for bob (password grant, scope=openid) — bob has the 'user'/'admin' roles but, unlike alice, no reports-reader entitlement (tested later in STE)"
TOKEN_A_BOB=$(curl -sf -X POST "${KC_A_URL}/realms/realm-a/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&client_id=app-a-client&client_secret=app-a-secret&username=bob&password=bob&scope=openid" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null) || true

if [ -n "$TOKEN_A_BOB" ]; then
  pass "KC-A token obtained for bob"
  debug_jwt "KC-A access token — bob" "$TOKEN_A_BOB"
else
  fail "Could not get KC-A token for bob"
fi

TOKEN_B_BOB=""
if [ -n "$TOKEN_A_BOB" ]; then
  debug "RFC 7523 JWT Authorization Grant KC-A → KC-B for bob — same cross-domain hop as alice, expect namespaced username kc-a-idp.bob"
  debug_req_post "${KC_B_URL}/realms/realm-b/protocol/openid-connect/token" \
    "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
    "assertion=${TOKEN_A_BOB}" \
    "client_id=app-a-m2m-client" "client_secret=app-a-m2m-secret" \
    "scope=openid organization"
  RESULT_B_BOB=$(curl -s -X POST "${KC_B_URL}/realms/realm-b/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=${TOKEN_A_BOB}&client_id=app-a-m2m-client&client_secret=app-a-m2m-secret&scope=openid%20organization")

  TOKEN_B_BOB=$(echo "$RESULT_B_BOB" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null) || true

  if [ -n "$TOKEN_B_BOB" ]; then
    pass "JWT Grant KC-A → KC-B succeeded (bob)"
    debug_resp "$RESULT_B_BOB"
    debug_jwt "KC-B access token — bob (after JWT grant hop 1)" "$TOKEN_B_BOB"

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
    debug "JWT grant failed:"
    debug_resp "$RESULT_B_BOB"
    ERROR_BOB=$(echo "$RESULT_B_BOB" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error_description','unknown'))" 2>/dev/null)
    fail "JWT Grant KC-A → KC-B failed for bob: $ERROR_BOB"
  fi
fi

if [ -n "$TOKEN_B_BOB" ]; then
  if [[ "$OPENSHIFT" == "true" ]]; then
    APP_B_POD="${APP_B_POD:-$(oc get pods -l app=app-b -n "$OC_NS" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)}"
    CHAIN_BOB=$(oc exec "$APP_B_POD" -n "$OC_NS" -- curl -sf "http://localhost:8080/api/hello" \
      -H "Authorization: Bearer ${TOKEN_B_BOB}" \
      -H "Accept: application/json" 2>/dev/null) || true
  else
    debug_req_get "${APP_B_URL}/api/hello" "Authorization: Bearer ${TOKEN_B_BOB}"
    CHAIN_BOB=$(curl -sf "${APP_B_URL}/api/hello" \
      -H "Authorization: Bearer ${TOKEN_B_BOB}" \
      -H "Accept: application/json" 2>/dev/null) || true
  fi
  debug "App-B chained response for bob:"
  debug_resp "$CHAIN_BOB"

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
if curl -sf ${APP_A_URL}/ | grep -q "Login"; then
  pass "Welcome page shows Login button"
else
  fail "Welcome page missing Login button"
fi

# Secured endpoint redirects to KC
REDIRECT_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-redirs 0 ${APP_A_URL}/secured 2>&1)
if [ "$REDIRECT_CODE" = "302" ]; then
  pass "Secured endpoint redirects to KC login (302)"
else
  fail "Secured endpoint returned $REDIRECT_CODE (expected 302)"
fi

# ---------------------------------------------------------------------------
info ""
info "=== Within-Realm Standard Token Exchange (RFC 8693) — App-A ==="
debug_test "Within-Realm Standard Token Exchange (RFC 8693)"
# ---------------------------------------------------------------------------
# Exchanges alice/bob tokens within realm-a for the internal resource audience
# (app-a-internal), then enforces /api/internal access:
#   alice original  → 403 (wrong audience)
#   alice exchanged → 200 (correct aud + reports-reader role)
#   bob   exchanged → 403 (correct aud but no reports-reader role)

# Helper: within-realm Standard Token Exchange against KC-A
ste_exchange() {
  local subject_token="$1"
  debug_req_post "${KC_A_URL}/realms/realm-a/protocol/openid-connect/token" \
    "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
    "subject_token=${subject_token}" \
    "subject_token_type=urn:ietf:params:oauth:token-type:access_token" \
    "client_id=app-a-client" "client_secret=app-a-secret" \
    "audience=app-a-internal" \
    "scope=openid internal-aud"
  local resp
  resp=$(curl -s -X POST "${KC_A_URL}/realms/realm-a/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
    --data-urlencode "subject_token=${subject_token}" \
    --data-urlencode "subject_token_type=urn:ietf:params:oauth:token-type:access_token" \
    --data-urlencode "client_id=app-a-client" \
    --data-urlencode "client_secret=app-a-secret" \
    --data-urlencode "audience=app-a-internal" \
    --data-urlencode "scope=openid internal-aud")
  debug_resp "$resp"
  echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null
}

# Fresh alice token (earlier TOKEN_A may be consumed by JWT Grant single-use)
STE_ALICE=$(curl -sf -X POST "${KC_A_URL}/realms/realm-a/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&client_id=app-a-client&client_secret=app-a-secret&username=alice&password=alice&scope=openid" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null) || true

STE_ALICE_EX=""
if [ -n "$STE_ALICE" ]; then
  debug_jwt "TOKEN BEFORE STE — alice login token (the subject_token)" "$STE_ALICE"
  STE_ALICE_EX=$(ste_exchange "$STE_ALICE")
  debug_jwt "TOKEN AFTER STE — alice exchanged token" "$STE_ALICE_EX"
  if [ -n "$STE_ALICE_EX" ]; then
    pass "Standard Token Exchange succeeded for alice"
    STE_AUD=$(echo "$STE_ALICE_EX" | python3 -c "
import sys,json,base64
t = sys.stdin.read().strip(); p = t.split('.')[1]; p += '=' * (4 - len(p) % 4)
c = json.loads(base64.b64decode(p)); aud = c.get('aud')
auds = aud if isinstance(aud, list) else [aud]
print('yes' if 'app-a-internal' in auds else 'no')
" 2>/dev/null)
    [ "$STE_AUD" = "yes" ] && pass "Exchanged token audience = app-a-internal" || fail "Exchanged token audience missing app-a-internal"
  else
    fail "Standard Token Exchange failed for alice"
  fi
fi

# bob token + exchange
STE_BOB=$(curl -sf -X POST "${KC_A_URL}/realms/realm-a/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&client_id=app-a-client&client_secret=app-a-secret&username=bob&password=bob&scope=openid" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null) || true
STE_BOB_EX=""
if [ -n "$STE_BOB" ]; then
  debug_jwt "TOKEN BEFORE STE — bob login token (the subject_token)" "$STE_BOB"
  STE_BOB_EX=$(ste_exchange "$STE_BOB")
  debug_jwt "TOKEN AFTER STE — bob exchanged token" "$STE_BOB_EX"
fi

# Enforcement matrix against App-A /api/internal
internal_status() {
  local token="$1"
  if [ "$DEBUG" = true ]; then
    local resp code body
    resp=$(curl -s -w $'\n%{http_code}' "${APP_A_URL}/api/internal" \
      -H "Authorization: Bearer ${token}" 2>/dev/null)
    code=$(printf '%s\n' "$resp" | tail -n1)
    body=$(printf '%s\n' "$resp" | sed '$d')
    debug_req_get "${APP_A_URL}/api/internal" "Authorization: Bearer ${token}"
    debug_resp "$body"
    printf '%s' "$code"
  else
    curl -s -o /dev/null -w "%{http_code}" "${APP_A_URL}/api/internal" \
      -H "Authorization: Bearer ${token}" 2>/dev/null
  fi
}

if [ -n "$STE_ALICE" ]; then
  CODE=$(internal_status "$STE_ALICE")
  [ "$CODE" = "403" ] && pass "/api/internal: alice ORIGINAL token → 403 (wrong audience)" || fail "/api/internal: alice ORIGINAL returned $CODE (expected 403)"
fi
if [ -n "$STE_ALICE_EX" ]; then
  CODE=$(internal_status "$STE_ALICE_EX")
  [ "$CODE" = "200" ] && pass "/api/internal: alice EXCHANGED token → 200 (accepted)" || fail "/api/internal: alice EXCHANGED returned $CODE (expected 200)"
fi
if [ -n "$STE_BOB_EX" ]; then
  CODE=$(internal_status "$STE_BOB_EX")
  [ "$CODE" = "403" ] && pass "/api/internal: bob EXCHANGED token → 403 (not entitled — no reports-reader)" || fail "/api/internal: bob EXCHANGED returned $CODE (expected 403)"
fi

# ===========================================================================
# MODE-SPECIFIC: SPI JIT Creation Tests
# ===========================================================================
if [ "$MODE" = "spi" ]; then
  info ""
  mode_info "=== [SPI] JIT User Creation Tests ==="
  debug_test "[SPI] JIT User Creation Tests"
  mode_info "Creating fresh user 'charlie' in KC-A, testing JIT provisioning..."

  # Step 1: Create user 'charlie' in KC-A via admin API
  ADMIN_TOKEN_A=$(get_admin_token "${KC_A_URL}") || true
  if [ -z "$ADMIN_TOKEN_A" ]; then
    fail "Could not get admin token for KC-A"
  else
    # Create charlie in realm-a (idempotent: skip if exists)
    CHARLIE_EXISTS=$(curl -sf "${KC_A_URL}/admin/realms/realm-a/users?username=charlie&exact=true" \
      -H "Authorization: Bearer $ADMIN_TOKEN_A" \
      | python3 -c "import sys,json; users=json.load(sys.stdin); print('yes' if users else 'no')" 2>/dev/null)

    debug "Admin API: GET realm-a users?username=charlie (idempotency check before creating the fresh source user) → ${CHARLIE_EXISTS}"
    if [ "$CHARLIE_EXISTS" = "yes" ]; then
      info "  (charlie already exists in realm-a, reusing)"
    else
      debug "Admin API: POST realm-a/users — creating fresh source user 'charlie' in KC-A (this user does NOT yet exist downstream; the JWT grant will JIT-provision it)"
      HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
        "${KC_A_URL}/admin/realms/realm-a/users" \
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
    CHARLIE_ID=$(curl -sf "${KC_A_URL}/admin/realms/realm-a/users?username=charlie&exact=true" \
      -H "Authorization: Bearer $ADMIN_TOKEN_A" \
      | python3 -c "import sys,json; users=json.load(sys.stdin); print(users[0]['id'] if users else '')" 2>/dev/null)

    if [ -n "$CHARLIE_ID" ]; then
      # Get role IDs for 'user' and 'admin'
      ROLES_JSON=$(curl -sf "${KC_A_URL}/admin/realms/realm-a/roles" \
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
          "${KC_A_URL}/admin/realms/realm-a/users/$CHARLIE_ID/role-mappings/realm" \
          -H "Authorization: Bearer $ADMIN_TOKEN_A" \
          -H "Content-Type: application/json" \
          -d "[$USER_ROLE, $ADMIN_ROLE]" 2>/dev/null || true
      fi
    fi

    # Step 2: Verify charlie does NOT exist in realm-b yet (JIT hasn't fired)
    debug "Admin API: getting admin token for KC-B for the BEFORE search (proving JIT hasn't fired yet)"
    ADMIN_TOKEN_B=$(get_admin_token "${KC_B_URL}") || true
    if [ -n "$ADMIN_TOKEN_B" ]; then
      debug "Admin API: GET realm-b users?username=kc-a-idp.charlie — BEFORE the JWT grant, expect NONE (JIT pending)"
      CHARLIE_B_BEFORE=$(curl -sf "${KC_B_URL}/admin/realms/realm-b/users?username=kc-a-idp.charlie&exact=true" \
        -H "Authorization: Bearer $ADMIN_TOKEN_B" \
        | python3 -c "import sys,json; users=json.load(sys.stdin); print('yes' if users else 'no')" 2>/dev/null)
      debug "BEFORE search result: kc-a-idp.charlie in realm-b → ${CHARLIE_B_BEFORE} (expect 'no')"
      [ "$CHARLIE_B_BEFORE" = "no" ] && pass "User 'kc-a-idp.charlie' does NOT exist in realm-b before JWT Grant (JIT pending)" || info "  (charlie already exists in realm-b from a previous test run)"
    fi

    # Step 3: Get KC-A token for charlie
    debug "Requesting KC-A token for charlie (password grant, scope=openid) — the source login token whose assertion will trigger JIT downstream"
    TOKEN_A_CHARLIE=$(curl -sf -X POST "${KC_A_URL}/realms/realm-a/protocol/openid-connect/token" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "grant_type=password&client_id=app-a-client&client_secret=app-a-secret&username=charlie&password=charlie&scope=openid" \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null) || true

    if [ -n "$TOKEN_A_CHARLIE" ]; then
      pass "KC-A token obtained for charlie"
      debug_jwt "KC-A access token — charlie (JIT source login token)" "$TOKEN_A_CHARLIE"
    else
      fail "Could not get KC-A token for charlie"
    fi

    # Step 4: JWT Grant A→B for charlie (triggers JIT creation in KC-B)
    TOKEN_B_CHARLIE=""
    if [ -n "$TOKEN_A_CHARLIE" ]; then
      debug "RFC 7523 JWT grant KC-A → KC-B for charlie — KC-B has no such user, so the broker SPI JIT-creates kc-a-idp.charlie on the fly and adds it to the kc-a-external-users org"
      debug_req_post "${KC_B_URL}/realms/realm-b/protocol/openid-connect/token" \
        "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
        "assertion=${TOKEN_A_CHARLIE}" \
        "client_id=app-a-m2m-client" "client_secret=app-a-m2m-secret" \
        "scope=openid organization"
      RESULT_B_CHARLIE=$(curl -s -X POST "${KC_B_URL}/realms/realm-b/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=${TOKEN_A_CHARLIE}&client_id=app-a-m2m-client&client_secret=app-a-m2m-secret&scope=openid%20organization")

      TOKEN_B_CHARLIE=$(echo "$RESULT_B_CHARLIE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null) || true

      if [ -n "$TOKEN_B_CHARLIE" ]; then
        pass "JWT Grant KC-A → KC-B succeeded for charlie (JIT creation)"
        debug_resp "$RESULT_B_CHARLIE"
        debug_jwt "KC-B access token — charlie (after JIT JWT grant hop 1)" "$TOKEN_B_CHARLIE"

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
        debug "JIT JWT grant failed:"
        debug_resp "$RESULT_B_CHARLIE"
        ERROR_CHARLIE=$(echo "$RESULT_B_CHARLIE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error_description','unknown'))" 2>/dev/null)
        fail "JWT Grant KC-A → KC-B failed for charlie (JIT): $ERROR_CHARLIE"
      fi
    fi

    # Step 5: Verify JIT-created user via KC-B admin API
    info ""
    mode_info "=== [SPI] JIT User Admin Verification ==="

    # Refresh admin token (may have expired)
    debug "Admin API: refreshing KC-B admin token for the AFTER search (the JWT grant should now have JIT-created the user)"
    ADMIN_TOKEN_B=$(get_admin_token "${KC_B_URL}") || true
    if [ -n "$ADMIN_TOKEN_B" ]; then
      # Check user exists with correct attributes
      debug "Admin API: GET realm-b users?username=kc-a-idp.charlie — AFTER the JWT grant, expect the JIT-created user with origin=kc-a, email + firstName carried over"
      CHARLIE_B_DATA=$(curl -sf "${KC_B_URL}/admin/realms/realm-b/users?username=kc-a-idp.charlie&exact=true" \
        -H "Authorization: Bearer $ADMIN_TOKEN_B") || true
      debug "AFTER search result (admin user record):"
      debug_resp "$CHARLIE_B_DATA"

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
      ORG_DATA=$(curl -sf "${KC_B_URL}/admin/realms/realm-b/organizations?search=kc-a-external-users" \
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
        ORG_MEMBERS=$(curl -sf "${KC_B_URL}/admin/realms/realm-b/organizations/$ORG_ID/members" \
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

    debug "Re-minting a fresh charlie KC-A token (single-use jti → can't reuse the earlier assertion) and grant A→B a SECOND time; JIT must find the existing user instead of creating a duplicate"
    TOKEN_A_CHARLIE2=$(curl -sf -X POST "${KC_A_URL}/realms/realm-a/protocol/openid-connect/token" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "grant_type=password&client_id=app-a-client&client_secret=app-a-secret&username=charlie&password=charlie&scope=openid" \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null) || true

    if [ -n "$TOKEN_A_CHARLIE2" ]; then
      debug_req_post "${KC_B_URL}/realms/realm-b/protocol/openid-connect/token" \
        "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
        "assertion=${TOKEN_A_CHARLIE2}" \
        "client_id=app-a-m2m-client" "client_secret=app-a-m2m-secret" \
        "scope=openid organization"
      RESULT_B_CHARLIE2=$(curl -s -X POST "${KC_B_URL}/realms/realm-b/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=${TOKEN_A_CHARLIE2}&client_id=app-a-m2m-client&client_secret=app-a-m2m-secret&scope=openid%20organization")

      TOKEN_B_CHARLIE2=$(echo "$RESULT_B_CHARLIE2" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null) || true

      if [ -n "$TOKEN_B_CHARLIE2" ]; then
        pass "JWT Grant idempotent — second charlie JWT Grant succeeded (no duplicate user)"
        debug_jwt "KC-B access token — charlie (second grant, same user reused)" "$TOKEN_B_CHARLIE2"
      else
        debug "second JWT grant failed:"
        debug_resp "$RESULT_B_CHARLIE2"
        ERROR_CHARLIE2=$(echo "$RESULT_B_CHARLIE2" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error_description','unknown'))" 2>/dev/null)
        fail "Second JWT Grant for charlie failed (idempotency): $ERROR_CHARLIE2"
      fi
    fi

    # Step 8: Full chain test A→B→C for charlie
    info ""
    mode_info "=== [SPI] JIT Full Chain Test (charlie: A → B → C) ==="

    debug "Re-minting fresh charlie tokens (single-use jti) to run the full two-hop chain: KC-A → KC-B (already JIT) → KC-C (JIT-creates kc-b-idp.kc-a-idp.charlie)"
    TOKEN_A_CHARLIE3=$(curl -sf -X POST "${KC_A_URL}/realms/realm-a/protocol/openid-connect/token" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "grant_type=password&client_id=app-a-client&client_secret=app-a-secret&username=charlie&password=charlie&scope=openid" \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null) || true
    debug_jwt "KC-A access token — charlie (full-chain login token)" "$TOKEN_A_CHARLIE3"

    TOKEN_B_CHARLIE3=""
    if [ -n "$TOKEN_A_CHARLIE3" ]; then
      debug "hop 1: JWT grant KC-A → KC-B for charlie"
      debug_req_post "${KC_B_URL}/realms/realm-b/protocol/openid-connect/token" \
        "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
        "assertion=${TOKEN_A_CHARLIE3}" \
        "client_id=app-a-m2m-client" "client_secret=app-a-m2m-secret" \
        "scope=openid organization"
      TOKEN_B_CHARLIE3=$(curl -s -X POST "${KC_B_URL}/realms/realm-b/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=${TOKEN_A_CHARLIE3}&client_id=app-a-m2m-client&client_secret=app-a-m2m-secret&scope=openid%20organization" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null) || true
      debug_jwt "KC-B access token — charlie (full-chain hop 1)" "$TOKEN_B_CHARLIE3"
    fi

    TOKEN_C_CHARLIE=""
    if [ -n "$TOKEN_B_CHARLIE3" ]; then
      debug "hop 2: JWT grant KC-B → KC-C for charlie — triggers JIT in realm-c, chained namespace kc-b-idp.kc-a-idp.charlie"
      debug_req_post "${KC_C_URL}/realms/realm-c/protocol/openid-connect/token" \
        "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
        "assertion=${TOKEN_B_CHARLIE3}" \
        "client_id=app-b-m2m-client" "client_secret=app-b-m2m-secret" \
        "scope=openid organization"
      RESULT_C_CHARLIE=$(curl -s -X POST "${KC_C_URL}/realms/realm-c/protocol/openid-connect/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=${TOKEN_B_CHARLIE3}&client_id=app-b-m2m-client&client_secret=app-b-m2m-secret&scope=openid%20organization")

      TOKEN_C_CHARLIE=$(echo "$RESULT_C_CHARLIE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token',''))" 2>/dev/null) || true

      if [ -n "$TOKEN_C_CHARLIE" ]; then
        pass "JWT Grant full chain A→B→C succeeded for charlie (JIT at both hops)"
        debug_resp "$RESULT_C_CHARLIE"
        debug_jwt "KC-C access token — charlie (after JIT JWT grant hop 2)" "$TOKEN_C_CHARLIE"

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
        debug "full-chain hop 2 failed:"
        debug_resp "$RESULT_C_CHARLIE"
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
