package com.example;

import io.quarkus.security.Authenticated;
import jakarta.inject.Inject;
import jakarta.json.JsonArray;
import jakarta.json.JsonObject;
import jakarta.json.JsonString;
import jakarta.json.JsonValue;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;
import org.eclipse.microprofile.jwt.JsonWebToken;

import java.util.LinkedHashSet;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;

/**
 * Internal resource protected by a manual claims check (NOT the OIDC audience
 * enforcer — {@code quarkus.oidc.token.audience} is intentionally left unset so
 * the framework accepts any audience and we enforce it ourselves here).
 *
 * Accepts the bearer token IFF:
 *   - its {@code aud} claim contains "app-a-internal", AND
 *   - its {@code realm_access.roles} contains "reports-reader".
 * Otherwise returns 403 with a clear reason.
 *
 * Expected matrix:
 *   alice ORIGINAL  → 403 (wrong audience)
 *   alice EXCHANGED → 200 (correct audience + reports-reader role)
 *   bob   ORIGINAL  → 403 (wrong audience)
 *   bob   EXCHANGED → 403 (correct audience but not entitled — no reports-reader)
 *
 * ───────────────────────────────────────────────────────────────────────────
 * DEMO CHOICE — and what you'd do in PRODUCTION
 * ───────────────────────────────────────────────────────────────────────────
 * The audience + role checks are performed HERE, in application code, ON PURPOSE:
 * it lets this endpoint return a precise, human-readable reason ("wrong audience"
 * vs. "not entitled") that the UI renders in the before/after panel. That is a
 * teaching device for a legible demo — NOT a recommended production pattern.
 *
 * Embedding authorization SPECIFICATIONS in developer code is an anti-pattern: the
 * rule — which audience, which role/permission opens this resource — should be
 * authored and owned by the SECURITY TEAM, not hardcoded by the app. Keep the app a
 * thin Policy Enforcement Point (PEP); let the rules live in a Policy Decision Point
 * (PDP). Ways to delegate this to Keycloak / the platform, lightest first:
 *
 *   1. Let the OIDC layer enforce the audience (no code) — set in application.properties:
 *        quarkus.oidc.token.audience=app-a-internal
 *      Quarkus then rejects any token whose aud doesn't match.
 *      https://quarkus.io/guides/security-oidc-bearer-token-authentication
 *
 *   2. Make the role gate declarative instead of an imperative if:
 *        @RolesAllowed("reports-reader")
 *      https://quarkus.io/guides/security-authorize-web-endpoints-reference
 *
 *   3. Fully externalize policy so SECURITY owns it in the Keycloak console and the
 *      app ships ZERO authorization logic (config only). Model resources, scopes and
 *      policies in Keycloak Authorization Services, enforce with the Quarkus policy
 *      enforcer (quarkus-keycloak-authorization):
 *        quarkus.keycloak.policy-enforcer.enable=true
 *      https://quarkus.io/guides/security-keycloak-authorization
 *      https://www.keycloak.org/docs/latest/authorization_services/
 *
 * Token exchange and authorization are complementary, not substitutes: STE shrinks
 * the TOKEN (least privilege at the credential); the PDP decides what that token MAY
 * DO. Production-correct = downscoped token + externalized policy decision.
 */
@Path("/api/internal")
@Authenticated
public class InternalResource {

    static final String REQUIRED_AUDIENCE = "app-a-internal";
    static final String REQUIRED_ROLE = "reports-reader";

    @Inject
    JsonWebToken accessToken;

    @GET
    @Produces(MediaType.APPLICATION_JSON)
    public Response internal() {
        Set<String> audiences = accessToken.getAudience();
        // Read realm roles directly from the Keycloak realm_access.roles claim.
        // (JsonWebToken.getGroups() reads the "groups" claim, which is empty here;
        // Quarkus maps realm_access.roles into SecurityIdentity, not into getGroups().)
        Set<String> roles = realmRoles();

        // DEMO PEP: these two checks are hardcoded here only to produce the legible
        // 403 reasons shown in the UI. In production, delegate this decision to Keycloak
        // (see the class javadoc: quarkus.oidc.token.audience + @RolesAllowed, or the
        // Keycloak Authorization Services policy enforcer) — don't author policy in app code.
        boolean audOk = audiences != null && audiences.contains(REQUIRED_AUDIENCE);
        boolean roleOk = roles != null && roles.contains(REQUIRED_ROLE);

        String username = accessToken.getClaim("preferred_username");
        if (username == null) {
            username = accessToken.getSubject();
        }
        String scope = accessToken.getClaim("scope");

        if (!audOk) {
            return forbidden("Wrong audience: token aud=" + audiences
                    + " does not contain '" + REQUIRED_AUDIENCE
                    + "'. This endpoint requires a token from Standard Token Exchange (RFC 8693).",
                    username, audiences, roles, scope);
        }
        if (!roleOk) {
            return forbidden("Not entitled: token is correctly scoped for '" + REQUIRED_AUDIENCE
                    + "' but is missing the required realm role '" + REQUIRED_ROLE + "'.",
                    username, audiences, roles, scope);
        }

        Map<String, Object> body = new LinkedHashMap<>();
        body.put("accepted", true);
        body.put("message", "Access granted to internal report for " + username + ".");
        body.put("preferred_username", username);
        body.put("aud", audiences);
        body.put("roles", roles);
        body.put("scope", scope);
        return Response.ok(body).build();
    }

    /**
     * Extracts the realm roles from the Keycloak {@code realm_access.roles} claim.
     */
    private Set<String> realmRoles() {
        Set<String> roles = new LinkedHashSet<>();
        Object realmAccess = accessToken.getClaim("realm_access");
        if (realmAccess instanceof JsonObject obj) {
            JsonValue rolesValue = obj.get("roles");
            if (rolesValue instanceof JsonArray arr) {
                for (JsonValue v : arr) {
                    if (v instanceof JsonString s) {
                        roles.add(s.getString());
                    }
                }
            }
        }
        return roles;
    }

    private Response forbidden(String reason, String username, Set<String> aud,
                               Set<String> roles, String scope) {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("accepted", false);
        body.put("reason", reason);
        body.put("preferred_username", username);
        body.put("aud", aud);
        body.put("roles", roles);
        body.put("scope", scope);
        return Response.status(Response.Status.FORBIDDEN).entity(body).build();
    }
}
