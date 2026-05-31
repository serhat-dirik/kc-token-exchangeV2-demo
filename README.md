# Keycloak Token Exchange V2 Demo

A working demo of **two complementary token-exchange patterns**:

- **Cross-realm federation** using the RFC 7523 JWT Authorization Grant — App-A → App-B → App-C across three independent Keycloaks — with Keycloak Organizations for multi-tenant user grouping and two approaches to user lifecycle management.
- **Within-realm Standard Token Exchange** (RFC 8693, "STE v2") — App-A re-audiences a user's token for one of its own internal services, demonstrating how exchange **downscopes** (and can never escalate) privilege.

## Table of Contents

- [What This Demo Does](#what-this-demo-does)
- [Within-Realm Standard Token Exchange (RFC 8693)](#within-realm-standard-token-exchange-rfc-8693)
- [Background & Concepts](#background--concepts)
- [Prerequisites](#prerequisites)
- [Quick Start — Local](#quick-start--local)
- [Quick Start — OpenShift](#quick-start--openshift)
- [Quick Start — Dev Spaces](#quick-start--dev-spaces)
- [Version Management](#version-management)
- [Test Suite](#test-suite)
- [SPI Implementation Details](#spi-implementation-details)
- [Configuration & Project Structure](#configuration--project-structure)
- [Cleanup](#cleanup)
- [Troubleshooting](#troubleshooting)

---

## What This Demo Does

This demo covers **two token-exchange patterns** that solve different problems:

### 1. Cross-realm federation (RFC 7523 JWT Authorization Grant)

Microservices often span **multiple security domains** — each with its own Keycloak. When Service A (secured by KC-A) needs to call Service B (secured by KC-B), it can't just forward its KC-A token — KC-B won't accept it. The service needs a way to **exchange** its token from one domain for a valid token in the other.

This is demonstrated by the **App-A → App-B → App-C** chain (button 1 in the App-A UI), with **two approaches** to the user-lifecycle question that federation raises:

1. **Pre-Provisioning** (default) — A script creates users, federated links, and org memberships in KC-B/KC-C *before* any token exchange happens. Simple, no custom code, good for development and stable user bases.

2. **JIT (Just-In-Time) via Custom SPI** — A Keycloak SPI plugin that intercepts the JWT Grant flow and creates users + links *on the fly* when they don't exist yet. Zero-touch user lifecycle — ideal for dynamic environments where you don't know all users upfront.

**Both approaches produce identical results**: namespaced usernames, organization membership claims, and federated identity links.

### 2. Within-realm Standard Token Exchange (RFC 8693, "STE v2")

Even inside a *single* realm, a token minted for one audience should not automatically be accepted by another service. App-A demonstrates this with two more buttons that call its own internal endpoint (`/api/internal`, secured by the bearer-only `app-a-internal` resource): forwarding the original login token **fails** with a wrong-audience 403, while performing a within-realm Standard Token Exchange to re-audience the token **succeeds** — *if* the user is also entitled. See [Within-Realm Standard Token Exchange (RFC 8693)](#within-realm-standard-token-exchange-rfc-8693) below.

### Architecture

```
                          +-----------------------------+
   STE v2 (RFC 8693)      |   App-A internal endpoint   |
   within realm-a         |   /api/internal             |
   re-audience token  +-->|   aud = app-a-internal      |
   to app-a-internal  |   |   + role reports-reader     |
                      |   +-----------------------------+
                      |
+---------------+    JWT Grant     +---------------+    JWT Grant     +---------------+
|    App-A      | ---------------> |    App-B      | ---------------> |    App-C      |
|   (UI+Svc)    |  KC-A token ->   |   (Service)   |  KC-B token ->   |  (Terminal)   |
|   Port 8081   |  KC-B token      |   Port 8082   |  KC-C token      |   Port 8083   |
+-------+-------+                  +-------+-------+                  +-------+-------+
        | OIDC                             | Bearer                           | Bearer
        v                                  v                                  v
+---------------+                  +---------------+                  +---------------+
|    KC-A       |                  |    KC-B       |                  |    KC-C       |
|   realm-a     |                  |   realm-b     |                  |   realm-c     |
|   Port 8180   |                  |   Port 8280   |                  |   Port 8380   |
|               |                  |   Org: KC-A   |                  |   Org: KC-B   |
|   Users:      |                  |   External    |                  |   External    |
|   alice, bob  |                  |   Users       |                  |   Users       |
+---------------+                  +---------------+                  +---------------+
                                   Trusts KC-A                        Trusts KC-B
                                   as external IDP                    as external IDP
```

The **horizontal** chain (App-A → App-B → App-C) is the cross-realm RFC 7523 federation flow.
The **top box** is the within-realm Standard Token Exchange (RFC 8693): App-A exchanges the
user's own realm-a token for one whose audience is `app-a-internal`, then calls its internal
endpoint — all inside realm-a, without ever leaving KC-A.

### Flow (cross-realm, RFC 7523)

1. User logs into **App-A** via **KC-A** (OIDC Authorization Code flow)
2. User clicks "Call Downstream Service"
3. App-A takes its KC-A access token and performs **RFC 7523 JWT Authorization Grant** against **KC-B**
4. KC-B validates the assertion (trusting KC-A as an IDP), resolves the user via federated identity link
5. KC-B issues a local token with the user's **organization membership** claim
6. App-A calls **App-B** `/api/hello` with the KC-B token
7. App-B repeats the same pattern: JWT Grant against **KC-C**, then calls **App-C**
8. App-C is the terminal service - returns its response
9. Responses cascade back up the chain

---

## Within-Realm Standard Token Exchange (RFC 8693)

The cross-realm flow above is about identity crossing *security domains*. This second flow
stays **inside realm-a** and answers a different question: should a token minted for one
audience be accepted by a *different* service in the same realm? It also makes the security
property of token exchange concrete — **exchange downscopes/re-audiences a token; it can
never escalate privilege.**

App-A's UI exposes **three buttons**:

| # | Button | What happens | Outcome |
|---|--------|--------------|---------|
| 1 | **Call downstream across realms (RFC 7523)** | The existing App-A → App-B → App-C chain (unchanged). | Cascaded response |
| 2 | **Call internal service — forward token as-is** | App-A forwards the user's **original login token** to `/api/internal`. | **403** — wrong audience: the login token's `aud` is the realm-b URL, not `app-a-internal` |
| 3 | **Call internal service — with STE (RFC 8693)** | App-A performs a **within-realm Standard Token Exchange** to mint a token whose `aud` is `app-a-internal`, then calls `/api/internal` with it. | **200** for an entitled user; the UI shows a before/after panel (original `aud`/roles vs exchanged `aud`/roles, and the 403 → 200 outcome) |

Under the hood, buttons 2 and 3 are driven by a single orchestration endpoint, `/api/ste`,
which performs *both* the forward-as-is call and the exchange-then-call, returning
`{before, original, after, exchanged}`. The protected resource server is `/api/internal`.

### The entitlement dimension — "which users" (the teaching point)

`/api/internal` enforces **two** independent conditions: (a) the token's `aud` must contain
`app-a-internal`, **and** (b) the caller must hold the realm role **`reports-reader`**.
In realm-a, **alice has `reports-reader`; bob does not.** Log in as each to show the matrix live:

| User | Token | `aud` includes `app-a-internal`? | Has `reports-reader`? | Result |
|------|-------|----------------------------------|------------------------|--------|
| alice | ORIGINAL | No | yes | **403** (wrong audience) |
| alice | EXCHANGED | yes | yes | **200** |
| bob | ORIGINAL | No | no | **403** (wrong audience) |
| bob | EXCHANGED | yes | **no** | **403** (re-audienced, but **not entitled**) |

The key insight: exchanging **bob's** token successfully re-audiences it to `app-a-internal`,
yet he **still** gets 403 — because the `reports-reader` role gate applies to the exchanged
token just as it did to the original. **Standard Token Exchange downscopes / re-audiences a
token but can never grant a privilege the user never had.**

### Configuration

- **`app-a-client`** (the App-A web client, realm-a) has the attribute
  `standard.token.exchange.enabled=true`, allowing it to perform STE. (`keycloak/realms/realm-a.json`)
- **`app-a-internal`** is a new **bearer-only** client (secret `app-a-internal-secret`) that
  acts as the exchange **target audience / resource server**. (`keycloak/realms/realm-a.json`)
- **Realm role `reports-reader`** is the entitlement gate enforced by `/api/internal`
  (granted to alice, not bob).
- App-A's Quarkus OIDC `application-type` is **`hybrid`** (interactive browser login for the
  UI, *and* bearer-token acceptance on `/api/*`) so the STE orchestration and `test.sh` can
  call the endpoints. (`app/src/main/resources/application.properties`)

### The audience-availability gotcha

A client can only mint an audience that is **"available"** to it. We make `app-a-internal`
available to `app-a-client` via an **optional** client scope named **`internal-aud`**, which
contains an `oidc-audience-mapper` (`included.client.audience=app-a-internal`). The exchange
request asks for `scope=openid internal-aud`, so the audience is added only during the exchange.

This scope is **created by the provisioning scripts via the admin API** — function
`setup_internal_audience_scope` in `provision-common.sh`, called from both `provision-users.sh`
and `provision-minimal.sh` — and is **deliberately *not* defined in the realm import JSON.**
Why: as the [Troubleshooting](#troubleshooting) table notes, defining `clientScopes` in the
realm import JSON overwrites Keycloak's defaults and breaks tokens. And because the scope is
*optional*, the normal **login** token keeps its single audience (the realm-b URL), so the
cross-realm RFC 7523 flow is completely unaffected — the `app-a-internal` audience appears
*only* when explicitly requested during the exchange.

---

<details>
<summary><strong>Background & Concepts</strong> — Token Exchange, V2 changes, User Links, Organizations</summary>

### What is Token Exchange?

**Token Exchange** lets a service swap a token issued by one authorization server for a token issued by another. Think of it like exchanging currency at a border crossing — your euros are valid at home, but you need dollars for the next country.

- **Internal Token Exchange** ([RFC 8693](https://datatracker.ietf.org/doc/html/rfc8693)): Swapping tokens between clients within the *same* Keycloak realm. Useful, but not the focus here.
- **External Token Exchange** ([RFC 7523 JWT Authorization Grant](https://datatracker.ietf.org/doc/html/rfc7523)): Swapping a JWT (JSON Web Token) from an *external* IdP for a local one. This is what this demo is about — **cross-realm, cross-Keycloak federation**.

### What Changed in V2?

Keycloak 25+ introduced **Token Exchange V2**, a standards-based rewrite:

- **V1** (legacy): A custom Keycloak-specific implementation that supported both internal and external token exchange. It worked — including external-to-internal flows — but relied on Keycloak-proprietary permission models and fine-grained authorization policies, which introduced security concerns and tight coupling to Keycloak internals.
- **V2** (current): Replaces the proprietary approach with the **RFC 7523 JWT Authorization Grant** standard. The downstream KC simply trusts the upstream KC as an IdP, validates the JWT signature via JWKS (JSON Web Key Set — the public key endpoint), and issues a local token. Standards-compliant, simpler to configure, and works across completely independent Keycloak instances without Keycloak-specific permission wiring.

### Why User Links?

When KC-B receives a JWT from KC-A, it needs to know *which local user* this external identity maps to. Keycloak uses **federated identity links** for this — a record that says "external user `alice` from IDP `kc-a-idp` is the same person as local user `kc-a-idp.alice`". Without this link, KC-B responds with "User not found".

This creates a **user lifecycle challenge**: how do these links get created?

### Where Do Organizations Fit In?

**Keycloak Organizations** (introduced in KC 24) provide a way to group users by their origin. In a multi-domain federation scenario, KC-B ends up with users from multiple external IdPs — some from KC-A, some from KC-C, perhaps some local. Without organizations, these users are just a flat list with no indication of where they came from.

In this demo, each downstream Keycloak has an **organization linked to each trusted IdP** (e.g., KC-B has an "KC-A" organization). When an external user is provisioned, they're automatically added to the matching organization. This means:

- **Access control by origin**: you can write policies like "only KC-A users can access this resource"
- **Organization claims in tokens**: the `organization` claim in the issued token tells downstream services which domain the user originally belongs to
- **Audit and visibility**: admins can see at a glance which users came from which external IdP

### Organizations and Username Namespacing

In a production scenario, KC-B and KC-C are operated by **different organizations**:

1. **Cross-domain access**: KC-B cannot access KC-A's admin API to import users
2. **Dynamic users**: KC-A adds/removes users over time
3. **Username conflicts**: Both orgs might have a user "bob"
4. **Diverse email domains**: The upstream org might be a social platform where users have @gmail.com, @yahoo.com, etc.

**Username namespacing** via the IDP username mapper template `${ALIAS}.${CLAIM.preferred_username}`:
- KC-A user `bob` becomes `kc-a-idp.bob` in realm-b
- KC-B user `kc-a-idp.bob` becomes `kc-b-idp.kc-a-idp.bob` in realm-c
- Local KC-B user `bob` remains `bob` - no conflict

**Organization membership** defined by origin IDP, not email domain:
- Realm-B: Organization "kc-a-external-users" linked to `kc-a-idp`
- Realm-C: Organization "kc-b-external-users" linked to `kc-b-idp`

**Organization claims in tokens**:
```json
{
  "organization": {
    "<org-id>": {
      "name": "kc-a-external-users"
    }
  }
}
```

### Token Exchange Flow (RFC 7523)

The JWT Authorization Grant request:

```http
POST /realms/realm-b/protocol/openid-connect/token
Content-Type: application/x-www-form-urlencoded

grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer
&assertion={access_token_from_KC-A}
&client_id=app-a-m2m-client
&client_secret=app-a-m2m-secret
&scope=openid organization
```

KC-B validates the assertion against the configured IDP (kc-a-idp) using KC-A's JWKS endpoint,
resolves the user via the **federated identity link** (by `sub` UUID, not by username), and
issues a local access token with organization membership claims.

#### Audience (`aud`) Claim Configuration

RFC 7523 requires the assertion's `aud` claim to identify the receiving authorization server.
Each upstream client includes an **audience protocol mapper** (`oidc-audience-mapper`)
that adds the downstream KC's issuer URL to the access token's `aud` claim:

| Upstream Client | Audience Added | Purpose |
|----------------|----------------|---------|
| `app-a-client` (realm-a) | `http://localhost:8280/realms/realm-b` | KC-A token accepted by KC-B |
| `app-a-m2m-client` (realm-b) | `http://localhost:8380/realms/realm-c` | KC-B token accepted by KC-C |

### Keycloak Features Enabled

Each KC instance runs with:
```bash
--features=token-exchange-standard:v2,jwt-authorization-grant:v1,organization
```

- **token-exchange-standard:v2** - RFC 8693 Standard Token Exchange (internal-to-internal, supported)
- **jwt-authorization-grant:v1** - RFC 7523 JWT Authorization Grant (external-to-internal federation, preview)
- **organization** - KC 26 Organizations for multi-tenancy and IDP-based user grouping

</details>

---

## Prerequisites

- Java 21+
- Podman (or Docker) with podman-compose
- Maven (included via wrapper)
- `oc` CLI (for OpenShift deployment)

## Quick Start — Local

### Pre-Provisioning Mode (Default)

```bash
# 1. Start Keycloaks with full user provisioning
./start-keycloaks.sh

# 2. Run apps in 3 separate terminals
./run-app-a.sh   # UI + Service, port 8081
./run-app-b.sh   # Service, port 8082
./run-app-c.sh   # Terminal Service, port 8083

# 3. Test
./test.sh
```

### SPI Mode (JIT User Creation)

```bash
# 1. Build the SPI JAR
./mvnw package -pl spi -DskipTests

# 2. Start Keycloaks with SPI mounted (minimal provisioning: orgs only)
./start-keycloaks.sh --mode spi

# 3. Run apps in 3 separate terminals (same commands)
./run-app-a.sh   # UI + Service, port 8081
./run-app-b.sh   # Service, port 8082
./run-app-c.sh   # Terminal Service, port 8083

# 4. Test (includes JIT-specific tests)
./test.sh --mode spi
```

### Manual Testing

1. Open http://localhost:8081
2. Click **Login** - Redirected to KC-A login page
3. Login as `alice` / `alice` (or `bob` / `bob`)
4. See welcome page with user info (name, email, roles)
5. Click **Call downstream across realms (RFC 7523)** - See the chained response with organization info
6. Click **Call internal service — forward token as-is** - See the **403** (wrong audience)
7. Click **Call internal service — with STE (RFC 8693)** - See the before/after panel and the 403 → 200 outcome. Log in as **alice** (200 after exchange) vs **bob** (still 403 — has the audience but not the `reports-reader` role) to see that exchange cannot escalate privilege. See [Within-Realm Standard Token Exchange](#within-realm-standard-token-exchange-rfc-8693).

**Admin console**: http://localhost:8180 (8280, 8380) - `admin/admin`

### Test Users (Realm-A)

| Username | Password | Roles                        |
|----------|----------|------------------------------|
| alice    | alice    | user, admin, reports-reader  |
| bob      | bob      | user                         |

> `reports-reader` is the entitlement gate for the within-realm STE demo: alice has it (exchange → 200), bob does not (exchange → still 403). See [Within-Realm Standard Token Exchange](#within-realm-standard-token-exchange-rfc-8693).

In SPI mode, the tests also create a `charlie` user dynamically to verify JIT provisioning.

## Quick Start — OpenShift

Deploy the full demo (3 Keycloak + 3 Quarkus apps) to OpenShift. Builds run on the cluster from this GitHub repo using OpenShift BuildConfigs with Containerfiles.If you don't have access to OpenShift or not available in your environment, you can use the [Red Hat Developer Sandbox](https://developers.redhat.com/developer-sandbox).

**Prerequisites**: `oc` CLI logged into an OpenShift 4.x cluster with sufficient quota for 6 pods + 3 build pods.

```bash
# Provisioning mode (default)
./deploy-openshift.sh

# SPI mode (JIT user creation)
./deploy-openshift.sh --mode spi

# Custom namespace
./deploy-openshift.sh --namespace my-demo --mode spi
```

The script reads version info from `.env`, creates ImageStreams and BuildConfigs, discovers Route hostnames, patches realm JSONs, deploys all 6 components, and runs a provisioning Job.

All deployments include **topology annotations** (`app.openshift.io/vcs-uri`, `app.openshift.io/connects-to`) for the OpenShift Developer Console topology view, with direct links to Dev Spaces from each deployment.

```bash
# Test against OpenShift
./test.sh --openshift
./test.sh --mode spi --openshift

# Cleanup
./undeploy-openshift.sh
```

## Quick Start — Dev Spaces

The project includes a `devfile.yaml` for **OpenShift Dev Spaces** — a cloud-based IDE workspace pre-configured with all required tools.

**Open a workspace**: Click the Dev Spaces icon on any deployment in the OpenShift Developer Console Topology view, or paste the Git repository URL into the Dev Spaces dashboard.If you don't have access to Dev Spaces or not available in your environment, you can use the [Red Hat Developer Sandbox](https://developers.redhat.com/developer-sandbox).

The workspace uses the Red Hat **Universal Developer Image (UDI)**, which provides Java (multiple versions), Maven, `oc`, `kubectl`, `python3`, `curl`, `jq`, and `git`.

### Build

Build all modules (app + SPI) from the workspace terminal:

```bash
./mvnw package -DskipTests           # Build everything
./mvnw package -pl app -DskipTests   # Build only the Quarkus app
./mvnw package -pl spi -DskipTests   # Build only the SPI module
```

### Deploy to OpenShift

From the workspace terminal, deploy the full demo (3 Keycloak + 3 Quarkus apps) to the current OpenShift namespace:

```bash
./deploy-openshift.sh --mode provisioning   # Pre-provisioned users
./deploy-openshift.sh --mode spi            # JIT user creation via SPI

# Test
./test.sh --mode provisioning --openshift
./test.sh --mode spi --openshift

# Cleanup
./undeploy-openshift.sh
```

### Command Palette Tasks

All of the above are also available as numbered tasks in the command palette (`F1` → "Run Task"):

| # | Command | Description |
|---|---------|-------------|
| 01 | Build Apps | `./mvnw package -DskipTests` |
| 02 | Deploy to OpenShift — Provisioning | Full deploy with pre-provisioned users |
| 03 | Deploy to OpenShift — SPI Mode | Full deploy with JIT user creation |
| 04 | Test — Provisioning (OpenShift) | `./test.sh --mode provisioning --openshift` |
| 05 | Test — SPI (OpenShift) | `./test.sh --mode spi --openshift` |
| 06 | Clean OpenShift Namespace | `./undeploy-openshift.sh` |

> **Note:** Local commands (`start-keycloaks.sh`, `run-app-*.sh`) are for local development with podman-compose and won't work inside Dev Spaces.

## Version Management

All dependency versions are centralized in the `.env` file:

```bash
KEYCLOAK_VERSION=26.5.3
QUARKUS_VERSION=3.20.3
JAVA_VERSION=21
```

These values propagate automatically to:
- `docker-compose.yml` — Keycloak container image tags
- `Containerfile.app` / `Containerfile.kc-spi` — Java builder/runtime image tags (via `ARG`)
- `deploy-openshift.sh` — OpenShift BuildConfig build args and KC deployment images
- `openshift/buildconfigs.yaml` and `openshift/kc-*-deployment.yaml` — placeholder substitution at deploy time

> **Note:** `pom.xml` properties (`<keycloak.version>`, `<quarkus.platform.version>`, `<maven.compiler.release>`) must be updated manually to match.

## Test Suite

The test suite supports both modes and both targets:

```bash
# Local testing
./test.sh                      # Provisioning mode (default)
./test.sh --mode provisioning  # Explicit provisioning mode
./test.sh --mode spi           # SPI mode with JIT tests

# OpenShift testing (uses Route URLs instead of localhost)
./test.sh --openshift                # Provisioning mode on OpenShift
./test.sh --mode spi --openshift     # SPI mode on OpenShift

# Debug mode — narrate every step (combinable with any flag above)
./test.sh --debug                    # or -d, or: DEBUG=1 ./test.sh
```

**Debug mode (`--debug` / `-d` / `DEBUG=1`)** turns the suite into a learning tool. For each
section it prints a blue `▶ TEST:` header, then per HTTP call a `── REQUEST ──` block with the
**actual copy-pasteable `curl`** (the full token is shown, so you can replay it) and a
`── RESPONSE ──` block with the pretty-printed JSON (long token blobs truncated to
`eyJ…(N chars)`). Tokens are also decoded inline so you can watch claims change — e.g. the STE
`aud` flip `realm-b → app-a-internal`, or the chain namespace deepen `alice → kc-a-idp.alice →
kc-b-idp.kc-a-idp.alice`. All debug output goes to **stderr** (so captured tokens stay intact)
and is gated off by default — the normal run is unchanged. Capture with `./test.sh --debug 2>&1 | tee run.log`.

**Core tests** (both modes, ~28 tests):
- Infrastructure health checks (3 KCs + 3 apps)
- KC-A token claims (audience, roles, username, email)
- JWT Grant chain: KC-A → KC-B → KC-C (token claims, namespaced usernames, org claims)
- Service chain: App-A → App-B → App-C (identity preservation)
- Bob tests (JWT Grant + full chain)
- UI tests (welcome page, OIDC redirect)
- **Within-realm STE (RFC 8693)**: verifies the exchange yields `aud=app-a-internal` and the enforcement matrix (alice original → 403, alice exchanged → 200, bob original → 403, bob exchanged → 403). Runs both locally and with `--openshift`.

**Provisioning-specific tests** (~3 tests):
- Pre-existence verification of alice and bob in realm-b and realm-c

**SPI-specific tests** (~15 tests):
- Creates fresh user "charlie" in KC-A via admin API
- Verifies charlie does NOT exist in realm-b before JWT Grant
- JWT Grant triggers JIT creation in KC-B (namespaced username, org claim)
- Admin API verification (user attributes: origin, email, firstName)
- Organization membership verification via admin API
- Idempotency test (second JWT Grant succeeds, no duplicate)
- Full chain test: A→B→C with JIT at both hops (chained namespace `kc-b-idp.kc-a-idp.charlie`)

---

<details>
<summary><strong>SPI Implementation Details</strong> — JIT JWT Grant plugin internals</summary>

### How It Works

The custom SPI overrides Keycloak's built-in JWT Authorization Grant handler:

1. **`JitJwtAuthorizationGrantTypeFactory`** registers with the same grant type ID (`urn:ietf:params:oauth:grant-type:jwt-bearer`) but with `order() = 1` (higher priority than the built-in `0`). Keycloak's provider loader picks the higher-priority factory.

2. **`JitJwtAuthorizationGrantType`** extends the built-in `JWTAuthorizationGrantType` and overrides `process()`:
   - Extracts the JWT assertion from the request
   - Decodes the payload (Base64 only — full signature validation is done by the parent)
   - Looks up the user by federated identity link (IDP alias + upstream `sub`)
   - If user exists → proceeds to normal flow
   - If user doesn't exist → JIT provision:
     - Creates user with namespaced username: `{idp_alias}.{preferred_username}`
     - Sets `origin` attribute (strip `-idp` suffix: `kc-a-idp` → `kc-a`)
     - Maps email, firstName, lastName from JWT claims
     - Creates federated identity link
     - Adds user to organization via `OrganizationProvider`
   - Calls `super.process()` — JWT Grant now succeeds because user + link exist

### Service Loader Registration

The SPI uses Java's `ServiceLoader` mechanism:

```text
META-INF/services/org.keycloak.protocol.oidc.grants.OAuth2GrantTypeFactory
→ com.example.spi.JitJwtAuthorizationGrantTypeFactory
```

### Deployment

In `start-dev` mode, Keycloak auto-discovers JARs in `/opt/keycloak/providers/`. The `docker-compose.spi.yml` override file mounts the SPI JAR into KC-B and KC-C (they receive JWT assertions). KC-A doesn't need the SPI (it only issues tokens).

</details>

---

<details>
<summary><strong>Configuration & Project Structure</strong></summary>

### Application Configuration

All application configuration is in `app/src/main/resources/application.properties`.

Key properties per profile:
- `app.target-service-url` - URL of the downstream service to call
- `app.target-kc-token-url` - Downstream KC's token endpoint for JWT Grant
- `app.target-kc-client-id` - Client ID at the downstream KC
- `app.target-kc-client-secret` - Client secret at the downstream KC

### OpenShift Configuration

All sensitive values (client secrets, admin credentials) are in **Secrets**. Non-sensitive config (URLs, feature flags) are in **ConfigMaps**.

| Resource | Type | Contents |
|----------|------|---------|
| `kc-config` | ConfigMap | KC feature flags, proxy headers, health |
| `kc-credentials` | Secret | KC admin username/password |
| `kc-{a,b,c}-realm` | ConfigMap | Patched realm JSON for import |
| `app-{a,b,c}-config` | ConfigMap | OIDC URLs, service URLs, client IDs |
| `app-{a,b,c}-secrets` | Secret | OIDC client secrets, M2M client secrets |

### URL Routing on OpenShift

- **KC Routes** (kc-a, kc-b, kc-c): HTTPS with edge TLS — needed for browser OIDC flows, admin console, and issuer matching in JWT Grant
- **App-A Route**: HTTPS with edge TLS — user-facing web UI
- **App-B, App-C**: Internal ClusterIP Services only (pod-to-pod via `http://app-b:8080`)
- **JWKS validation**: KC pods use internal Service URLs (`http://kc-a:8080`) for JWKS fetching

### Project Structure

```
kc-token-exchangeV2-demo/
├── pom.xml                          # Parent POM (multi-module)
├── README.md
├── .env                             # Centralized version config (KC, Java, Quarkus)
├── devfile.yaml                     # OpenShift Dev Spaces workspace definition
│
├── app/                             # Quarkus application (UI + services)
│   ├── pom.xml
│   └── src/main/
│       ├── java/com/example/        # HelloResource, UiResource, etc.
│       └── resources/               # application.properties, templates/
│
├── spi/                             # Keycloak SPI module (JIT JWT Grant)
│   ├── pom.xml
│   └── src/main/
│       ├── java/com/example/spi/    # JIT provisioning logic
│       └── resources/META-INF/services/
│
├── keycloak/realms/                 # Realm import files
│   ├── realm-a.json
│   ├── realm-b.json
│   └── realm-c.json
│
├── docker-compose.yml               # Base: 3 KC instances
├── docker-compose.spi.yml           # Override: mounts SPI JAR into KC-B, KC-C
│
├── start-keycloaks.sh               # Start KCs (--mode provisioning|spi)
├── stop-keycloaks.sh                # Stop all KC instances
├── provision-common.sh              # Shared provisioning helper functions
├── provision-users.sh               # Full provisioning (users + orgs + links)
├── provision-minimal.sh             # Minimal provisioning (orgs + scope only)
│
├── run-app-a.sh                     # Start App-A (port 8081)
├── run-app-b.sh                     # Start App-B (port 8082)
├── run-app-c.sh                     # Start App-C (port 8083)
├── build.sh                         # Build all modules (--app|--spi)
├── test.sh                          # E2E tests (--mode provisioning|spi)
│
├── Containerfile.app                # Quarkus app image (multi-stage)
├── Containerfile.kc-spi             # KC + SPI JAR image (SPI mode)
├── Containerfile.provision          # Provisioning Job image
├── deploy-openshift.sh              # OpenShift deploy orchestration
├── undeploy-openshift.sh            # OpenShift cleanup
│
└── openshift/                       # OpenShift manifests
    ├── imagestreams.yaml
    ├── buildconfigs.yaml
    ├── kc-config.yaml
    ├── kc-secret.yaml
    ├── app-secrets.yaml
    ├── kc-{a,b,c}-deployment.yaml
    ├── app-{a,b,c}-deployment.yaml
    ├── services.yaml
    ├── routes.yaml
    └── provision-job-template.yaml
```

</details>

---

## Cleanup

### Local

```bash
./stop-keycloaks.sh
```

Keycloak only imports realm JSON files on **first startup** (when the data directory is empty). If you modify a realm JSON and want to re-import, you must fully remove the containers first:

```bash
./stop-keycloaks.sh
podman rm -f kc-a kc-b kc-c
./start-keycloaks.sh              # or: ./start-keycloaks.sh --mode spi
```

### OpenShift

```bash
./undeploy-openshift.sh
# or with namespace:
./undeploy-openshift.sh --namespace my-demo
```

## Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| KC containers exit immediately (code 2) | Feature flag names missing version suffix | Ensure flags are `token-exchange-standard:v2` and `jwt-authorization-grant:v1` |
| "JWT Authorization Grant is not supported for the requested client" | M2M client or IDP missing JWT Grant attributes | Verify the M2M client has `oauth2.jwt.authorization.grant.enabled: "true"` and `oauth2.jwt.authorization.grant.idp: "<alias>"` in `attributes`, and the IDP config has `jwtAuthorizationGrantEnabled: "true"` |
| User shows as UUID, email N/A, no roles | Custom `clientScopes` in realm JSON overwrites KC built-in scopes | Do **not** define `clientScopes` in the realm import JSON - let KC use its defaults |
| "Invalid token audience" | Access token `aud` claim doesn't match downstream KC | Add an `oidc-audience-mapper` on the upstream client to include the downstream KC's issuer URL |
| "Multiple audiences not allowed" | Token has both `"account"` and the custom audience | Set `"fullScopeAllowed": false` on the client so `AudienceResolveProtocolMapper` doesn't add `"account"` |
| "User not found" (provisioning mode) | JWT Grant does not do JIT provisioning | Run `./provision-users.sh` to create users, organizations, and federated identity links |
| "User not found" (SPI mode) | SPI JAR not mounted in KC container | Verify `docker-compose.spi.yml` mounts the JAR and rebuild: `./mvnw package -pl spi -DskipTests` |
| Realm changes not taking effect | KC only imports on first startup | Remove containers completely (`podman rm -f kc-a kc-b kc-c`) then recreate |
| "Token reuse detected" | JWT Grant assertion `jti` was already used - KC enforces single-use | In the app, each call refreshes the OIDC session to get a fresh access token with a new `jti`. In curl/scripts, always get a fresh token before each JWT Grant call |
| STE returns "audience not available" / exchanged token lacks `app-a-internal` | The `internal-aud` optional scope wasn't created on `app-a-client` | Run a provisioning script — `setup_internal_audience_scope` (in `provision-common.sh`) creates the scope via the admin API; do **not** add it to the realm import JSON |
| STE exchange succeeds (`aud=app-a-internal`) but `/api/internal` still returns 403 | Caller lacks the `reports-reader` realm role (e.g. bob) | Expected — exchange re-audiences but cannot escalate privilege; grant `reports-reader` to the user if access is intended |
| Organization claim missing from token | `organization` scope not a default client scope | Run provisioning script or manually promote `organization` to default scope on the M2M client |
| "Organizations not enabled" error | Feature flag missing or `organizationsEnabled` not set | Ensure `KC_FEATURES` includes `organization` and realm JSON has `"organizationsEnabled": true` |
| SPI JAR build fails | Java/Maven not configured | Ensure Java 21+ is available: `java -version`. Use SDKMAN: `sdk install java 21-tem` |
