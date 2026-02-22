# Keycloak Token Exchange V2 Demo

## The Problem

Microservices often span **multiple security domains** — each with its own Keycloak (or other Identity Provider / IdP). When Service A (secured by KC-A) needs to call Service B (secured by KC-B), it can't just forward its KC-A token — KC-B won't accept it. The service needs a way to **exchange** its token from one domain for a valid token in the other.

## What is Token Exchange?

**Token Exchange** lets a service swap a token issued by one authorization server for a token issued by another. Think of it like exchanging currency at a border crossing — your euros are valid at home, but you need dollars for the next country.

- **Internal Token Exchange** ([RFC 8693](https://datatracker.ietf.org/doc/html/rfc8693)): Swapping tokens between clients within the *same* Keycloak realm. Useful, but not the focus here.
- **External Token Exchange** ([RFC 7523 JWT Authorization Grant](https://datatracker.ietf.org/doc/html/rfc7523)): Swapping a JWT (JSON Web Token) from an *external* IdP for a local one. This is what this demo is about — **cross-realm, cross-Keycloak federation**.

## What Changed in V2?

Keycloak 25+ introduced **Token Exchange V2**, a standards-based rewrite:

- **V1** (legacy): A custom Keycloak-specific implementation that supported both internal and external token exchange. It worked — including external-to-internal flows — but relied on Keycloak-proprietary permission models and fine-grained authorization policies, which introduced security concerns and tight coupling to Keycloak internals.
- **V2** (current): Replaces the proprietary approach with the **RFC 7523 JWT Authorization Grant** standard. The downstream KC simply trusts the upstream KC as an IdP, validates the JWT signature via JWKS (JSON Web Key Set — the public key endpoint), and issues a local token. Standards-compliant, simpler to configure, and works across completely independent Keycloak instances without Keycloak-specific permission wiring.

## Why User Links?

When KC-B receives a JWT from KC-A, it needs to know *which local user* this external identity maps to. Keycloak uses **federated identity links** for this — a record that says "external user `alice` from IDP `kc-a-idp` is the same person as local user `kc-a-idp.alice`". Without this link, KC-B responds with "User not found".

This creates a **user lifecycle challenge**: how do these links get created?

## Where Do Organizations Fit In?

**Keycloak Organizations** (introduced in KC 24) provide a way to group users by their origin. In a multi-domain federation scenario, KC-B ends up with users from multiple external IdPs — some from KC-A, some from KC-C, perhaps some local. Without organizations, these users are just a flat list with no indication of where they came from.

In this demo, each downstream Keycloak has an **organization linked to each trusted IdP** (e.g., KC-B has an "KC-A" organization). When an external user is provisioned, they're automatically added to the matching organization. This means:

- **Access control by origin**: you can write policies like "only KC-A users can access this resource"
- **Organization claims in tokens**: the `organization` claim in the issued token tells downstream services which domain the user originally belongs to
- **Audit and visibility**: admins can see at a glance which users came from which external IdP

## Two Approaches in This Demo

1. **Pre-Provisioning** (default) — A script creates users, federated links, and org memberships in KC-B/KC-C *before* any token exchange happens. Simple, no custom code, good for development and stable user bases.

2. **JIT (Just-In-Time) via Custom SPI (Service Provider Interface)** — A Keycloak SPI plugin that intercepts the JWT Grant flow and creates users + links *on the fly* when they don't exist yet. Zero-touch user lifecycle — ideal for dynamic environments where you don't know all users upfront. The SPI extends Keycloak's built-in JWT Grant handler, so it's a drop-in enhancement, not a replacement.

**Both approaches produce identical results**: namespaced usernames, organization membership claims, and federated identity links.

---

## Architecture

```
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

### Flow
1. User logs into **App-A** via **KC-A** (OIDC Authorization Code flow)
2. User clicks "Call Downstream Service"
3. App-A takes its KC-A access token and performs **RFC 7523 JWT Authorization Grant** against **KC-B**
4. KC-B validates the assertion (trusting KC-A as an IDP), resolves the user via federated identity link
5. KC-B issues a local token with the user's **organization membership** claim
6. App-A calls **App-B** `/api/hello` with the KC-B token
7. App-B repeats the same pattern: JWT Grant against **KC-C**, then calls **App-C**
8. App-C is the terminal service - returns its response
9. Responses cascade back up the chain

## Approach Details

### Approach 1: Pre-Provisioning (Default)

`provision-users.sh` creates users, federated identity links, and organization memberships via admin API **before** any JWT Grant happens. No custom Keycloak code needed.

### Approach 2: JIT via Custom SPI

The `kc-jit-jwt-grant-spi` plugin intercepts JWT Grant requests and automatically creates users + links on first access:

1. Creates user with namespaced username (`kc-a-idp.alice`)
2. Sets `origin` attribute (e.g., `kc-a` from IDP alias `kc-a-idp`)
3. Maps email, firstName, lastName from JWT claims
4. Creates the federated identity link
5. Adds user to the organization linked to the IDP

## Prerequisites

- Java 21+
- Podman (or Docker) with podman-compose
- Maven (included via wrapper)
- `oc` CLI (for OpenShift deployment)

## Quick Start

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

### Version Management

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

### Manual Testing

1. Open http://localhost:8081
2. Click **Login** - Redirected to KC-A login page
3. Login as `alice` / `alice` (or `bob` / `bob`)
4. See welcome page with user info (name, email, roles)
5. Click **Call Downstream Service** - See the chained response with organization info

**Admin console**: http://localhost:8180 (8280, 8380) - `admin/admin`

## Test Users (Realm-A)

| Username | Password | Roles        |
|----------|----------|-------------|
| alice    | alice    | user, admin |
| bob      | bob      | user        |

In SPI mode, the tests also create a `charlie` user dynamically to verify JIT provisioning.

## Project Structure

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

## SPI Implementation Details

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

## Organizations and Username Namespacing

### The Problem

In a production scenario, KC-B and KC-C are operated by **different organizations**:

1. **Cross-domain access**: KC-B cannot access KC-A's admin API to import users
2. **Dynamic users**: KC-A adds/removes users over time
3. **Username conflicts**: Both orgs might have a user "bob"
4. **Diverse email domains**: The upstream org might be a social platform where users have @gmail.com, @yahoo.com, etc.

### The Solution

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

## Configuration

All application configuration is in `app/src/main/resources/application.properties`.

Key properties per profile:
- `app.target-service-url` - URL of the downstream service to call
- `app.target-kc-token-url` - Downstream KC's token endpoint for JWT Grant
- `app.target-kc-client-id` - Client ID at the downstream KC
- `app.target-kc-client-secret` - Client secret at the downstream KC

## Token Exchange Flow (RFC 7523)

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

### Audience (`aud`) Claim Configuration

RFC 7523 requires the assertion's `aud` claim to identify the receiving authorization server.
Each upstream client includes an **audience protocol mapper** (`oidc-audience-mapper`)
that adds the downstream KC's issuer URL to the access token's `aud` claim:

| Upstream Client | Audience Added | Purpose |
|----------------|----------------|---------|
| `app-a-client` (realm-a) | `http://localhost:8280/realms/realm-b` | KC-A token accepted by KC-B |
| `app-a-m2m-client` (realm-b) | `http://localhost:8380/realms/realm-c` | KC-B token accepted by KC-C |

## Keycloak Features Enabled

Each KC instance runs with:
```bash
--features=token-exchange-standard:v2,jwt-authorization-grant:v1,organization
```

- **token-exchange-standard:v2** - RFC 8693 Standard Token Exchange (internal-to-internal, supported)
- **jwt-authorization-grant:v1** - RFC 7523 JWT Authorization Grant (external-to-internal federation, preview)
- **organization** - KC 26 Organizations for multi-tenancy and IDP-based user grouping

## Test Suite

The test suite supports both modes:

```bash
# Local testing
./test.sh                      # Provisioning mode (default)
./test.sh --mode provisioning  # Explicit provisioning mode
./test.sh --mode spi           # SPI mode with JIT tests

# OpenShift testing (uses Route URLs instead of localhost)
./test.sh --openshift                # Provisioning mode on OpenShift
./test.sh --mode spi --openshift     # SPI mode on OpenShift
```

**Core tests** (both modes, ~28 tests):
- Infrastructure health checks (3 KCs + 3 apps)
- KC-A token claims (audience, roles, username, email)
- JWT Grant chain: KC-A → KC-B → KC-C (token claims, namespaced usernames, org claims)
- Service chain: App-A → App-B → App-C (identity preservation)
- Bob tests (JWT Grant + full chain)
- UI tests (welcome page, OIDC redirect)

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

## OpenShift Deployment

Deploy the full demo (3 Keycloak + 3 Quarkus apps) to OpenShift. Builds run on the cluster from this GitHub repo using OpenShift BuildConfigs with Containerfiles.

### Prerequisites

- `oc` CLI logged into an OpenShift 4.x cluster
- Sufficient quota for 6 pods + 3 build pods

### Deploy

```bash
# Provisioning mode (default)
./deploy-openshift.sh

# SPI mode (JIT user creation)
./deploy-openshift.sh --mode spi

# Custom namespace
./deploy-openshift.sh --namespace my-demo --mode spi
```

The script:
1. Reads version info from `.env` (Keycloak, Java versions)
2. Creates ImageStreams and BuildConfigs (substituting version placeholders), triggers builds from GitHub
3. Creates Routes and discovers their hostnames
4. Patches realm JSONs to replace localhost URLs with Route/Service URLs
5. Creates ConfigMaps (non-sensitive config) and Secrets (credentials)
6. Deploys all 6 components with proper env var overrides
7. Runs a provisioning Job once Keycloak instances are ready

All deployments include **topology annotations** (`app.openshift.io/vcs-uri`, `app.openshift.io/connects-to`) for the OpenShift Developer Console topology view, with direct links to Dev Spaces from each deployment.

### Configuration

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

### Cleanup

```bash
./undeploy-openshift.sh
# or with namespace:
./undeploy-openshift.sh --namespace my-demo
```

### Project Structure (OpenShift files)

```
openshift/
├── imagestreams.yaml           # ImageStreams for built images
├── buildconfigs.yaml           # BuildConfigs (Docker strategy from GitHub)
├── kc-config.yaml              # Shared KC ConfigMap
├── kc-secret.yaml              # KC admin credentials
├── app-secrets.yaml            # App OIDC client secrets
├── kc-{a,b,c}-deployment.yaml  # KC Deployments
├── app-{a,b,c}-deployment.yaml # App Deployments
├── services.yaml               # All 6 ClusterIP Services
├── routes.yaml                 # Routes for KC-A, KC-B, KC-C, App-A
└── provision-job-template.yaml # Provisioning Job (processed at deploy time)

Containerfile.app               # Multi-stage Quarkus app build
Containerfile.kc-spi            # KC image with SPI JAR (SPI mode)
Containerfile.provision         # Provisioning Job image
deploy-openshift.sh             # Deploy orchestration script
undeploy-openshift.sh           # Cleanup script
```

## Dev Spaces

The project includes a `devfile.yaml` for **OpenShift Dev Spaces** — a cloud-based IDE workspace pre-configured with all required tools.

### Opening a Workspace

- **From Topology view**: Click the Dev Spaces icon on any deployment in the OpenShift Developer Console
- **From Dev Spaces dashboard**: Paste the Git repository URL

### What's Included

The workspace uses the Red Hat **Universal Developer Image (UDI)**, which provides:
- Java 8/11/17/21 (via sdkman, defaulting to 21), Maven, `oc`, `kubectl`, `python3`, `curl`, `jq`, `podman`

### Available Commands (Command Palette)

| # | Command | Description |
|---|---------|-------------|
| 01 | Build App | `./mvnw package -pl app -DskipTests` |
| 02 | Build SPI | `./mvnw package -pl spi -DskipTests` |
| 03 | Build All Modules | `./mvnw package -DskipTests` |
| 04 | Run App-A | Quarkus dev mode, port 8081 |
| 05 | Run App-B | Quarkus dev mode, port 8082 |
| 06 | Run App-C | Quarkus dev mode, port 8083 |
| 07 | Test (Provisioning) | `./test.sh --mode provisioning` |
| 08 | Test (SPI) | `./test.sh --mode spi` |
| 09 | Test (OpenShift) | `./test.sh --openshift` |
| 10 | Deploy (Provisioning) | `./deploy-openshift.sh --mode provisioning` |
| 11 | Deploy (SPI) | `./deploy-openshift.sh --mode spi` |
| 12 | Provision Users | `./provision-users.sh` |
| 13 | Provision Minimal | `./provision-minimal.sh` |

## Local Cleanup

```bash
./stop-keycloaks.sh
```

### Recreating Keycloak Containers

Keycloak only imports realm JSON files on **first startup** (when the data directory is empty). If you modify a realm JSON and want to re-import, you must fully remove the containers first:

```bash
./stop-keycloaks.sh
podman rm -f kc-a kc-b kc-c
./start-keycloaks.sh              # or: ./start-keycloaks.sh --mode spi
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
| Organization claim missing from token | `organization` scope not a default client scope | Run provisioning script or manually promote `organization` to default scope on the M2M client |
| "Organizations not enabled" error | Feature flag missing or `organizationsEnabled` not set | Ensure `KC_FEATURES` includes `organization` and realm JSON has `"organizationsEnabled": true` |
| SPI JAR build fails | Java/Maven not configured | Ensure Java 21+ is available: `java -version`. Use SDKMAN: `sdk install java 21-tem` |
