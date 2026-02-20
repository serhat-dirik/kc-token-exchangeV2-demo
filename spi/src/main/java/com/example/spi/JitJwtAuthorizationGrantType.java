package com.example.spi;

import org.jboss.logging.Logger;
import org.keycloak.models.FederatedIdentityModel;
import org.keycloak.models.IdentityProviderModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.RealmModel;
import org.keycloak.models.RoleModel;
import org.keycloak.models.UserModel;
import org.keycloak.organization.OrganizationProvider;
import org.keycloak.protocol.oidc.grants.JWTAuthorizationGrantType;
import org.keycloak.protocol.oidc.grants.OAuth2GrantType;
import org.keycloak.representations.JsonWebToken;
import org.keycloak.util.JsonSerialization;

import jakarta.ws.rs.core.Response;
import java.util.Base64;
import java.util.List;

/**
 * Extends the built-in {@link JWTAuthorizationGrantType} to add JIT (Just-In-Time)
 * user provisioning during JWT Authorization Grant (RFC 7523).
 *
 * <p>When a JWT Grant request arrives for a user who does NOT yet exist in the
 * target realm (no federated identity link), this provider:
 * <ol>
 *   <li>Creates the user with a namespaced username: {@code {idp_alias}.{preferred_username}}</li>
 *   <li>Sets the {@code origin} attribute (e.g., "kc-a" from alias "kc-a-idp")</li>
 *   <li>Maps email, firstName, lastName from JWT claims</li>
 *   <li>Creates the federated identity link</li>
 *   <li>Adds the user to the organization linked to the IDP</li>
 * </ol>
 * <p>Then proceeds with the normal JWT Grant flow (via {@code super.process()}).
 */
public class JitJwtAuthorizationGrantType extends JWTAuthorizationGrantType {

    private static final Logger LOG = Logger.getLogger(JitJwtAuthorizationGrantType.class);

    /**
     * Session injected from the factory's {@code create()} method.
     * We keep our own reference because the parent's {@code session} field is set later
     * via {@code setContext()}, which may not have run yet when {@code process()} starts.
     */
    private final KeycloakSession kcSession;

    public JitJwtAuthorizationGrantType(KeycloakSession session) {
        this.kcSession = session;
    }

    /**
     * Tracks JIT-provisioned user info so we can re-apply the origin attribute
     * after super.process() completes (the built-in flow may refresh/overwrite the entity).
     */
    private String jitProvisionedUsername;
    private String jitProvisionedOrigin;

    @Override
    public Response process(OAuth2GrantType.Context context) {
        // Run JIT provisioning before the standard JWT Grant flow.
        // If the user already exists, this is a no-op.
        jitProvisionedUsername = null;
        jitProvisionedOrigin = null;
        try {
            ensureUserProvisioned(context);
        } catch (Exception e) {
            LOG.warnf("JIT provisioning check failed, proceeding with normal flow: %s", e.getMessage());
            LOG.debug("JIT provisioning error details", e);
        }

        Response response = super.process(context);

        // Re-apply origin attribute after super.process() in case the built-in flow
        // refreshed/overwrote the user entity during authentication session creation.
        if (jitProvisionedUsername != null && jitProvisionedOrigin != null) {
            try {
                RealmModel realm = kcSession.getContext().getRealm();
                UserModel user = kcSession.users().getUserByUsername(realm, jitProvisionedUsername);
                if (user != null) {
                    user.setAttribute("origin", List.of(jitProvisionedOrigin));
                    LOG.infof("Re-applied origin attribute '%s' for user '%s' after JWT Grant processing",
                            jitProvisionedOrigin, jitProvisionedUsername);
                }
            } catch (Exception e) {
                LOG.warnf("Failed to re-apply origin attribute: %s", e.getMessage());
            }
        }

        return response;
    }

    /**
     * Checks if the user from the JWT assertion exists in the target realm.
     * If not, creates the user JIT with all necessary attributes, links, and org membership.
     */
    private void ensureUserProvisioned(OAuth2GrantType.Context context) {
        // Extract assertion from the form parameters
        var formParams = context.getFormParams();
        String assertion = formParams != null ? formParams.getFirst("assertion") : null;
        if (assertion == null || assertion.isBlank()) {
            return; // Let the parent handle the missing assertion error
        }

        RealmModel realm = kcSession.getContext().getRealm();
        if (realm == null) {
            LOG.warn("JIT: Realm is null, cannot provision");
            return;
        }

        // Get the client to find the configured IDP alias
        var client = kcSession.getContext().getClient();
        if (client == null) {
            LOG.warn("JIT: Client is null, cannot provision");
            return;
        }

        String idpAlias = client.getAttribute("oauth2.jwt.authorization.grant.idp");
        if (idpAlias == null || idpAlias.isBlank()) {
            LOG.debug("No IDP alias configured on client for JWT Grant — skipping JIT");
            return;
        }

        IdentityProviderModel idp = realm.getIdentityProviderByAlias(idpAlias);
        if (idp == null) {
            LOG.debugf("IDP '%s' not found in realm '%s'", idpAlias, realm.getName());
            return;
        }

        // Decode the JWT payload to extract user claims.
        // We only do base64 decoding here — full signature validation is done by the parent.
        JsonWebToken jwt = decodeJwtPayload(assertion);
        if (jwt == null) {
            return;
        }

        String upstreamSub = jwt.getSubject();
        if (upstreamSub == null || upstreamSub.isBlank()) {
            return;
        }

        String upstreamUsername = getStringClaim(jwt, "preferred_username");
        String upstreamEmail = getStringClaim(jwt, "email");
        String upstreamFirstName = getStringClaim(jwt, "given_name");
        String upstreamLastName = getStringClaim(jwt, "family_name");

        // Check if user already exists by federated identity link
        FederatedIdentityModel fedIdentityLookup = new FederatedIdentityModel(
                idpAlias, upstreamSub,
                upstreamUsername != null ? upstreamUsername : upstreamSub);

        UserModel existingUser = kcSession.users().getUserByFederatedIdentity(realm, fedIdentityLookup);

        if (existingUser != null) {
            LOG.debugf("User already exists for IDP '%s' sub '%s': %s",
                    idpAlias, upstreamSub, existingUser.getUsername());
            return;
        }

        // ---- JIT Provisioning ----
        LOG.infof("JIT provisioning user for IDP '%s', upstream sub=%s, username=%s",
                idpAlias, upstreamSub, upstreamUsername);

        // 1. Create namespaced username: {idp_alias}.{upstream_username}
        String effectiveUsername = upstreamUsername != null ? upstreamUsername : upstreamSub;
        String namespacedUsername = idpAlias + "." + effectiveUsername;

        // 2. Create user
        UserModel newUser = kcSession.users().addUser(realm, namespacedUsername);
        newUser.setEnabled(true);
        newUser.setEmailVerified(true);
        if (upstreamEmail != null) newUser.setEmail(upstreamEmail);
        if (upstreamFirstName != null) newUser.setFirstName(upstreamFirstName);
        if (upstreamLastName != null) newUser.setLastName(upstreamLastName);

        // 3. Set origin attribute (strip "-idp" suffix: "kc-a-idp" → "kc-a")
        //    Use setAttribute(List) instead of setSingleAttribute — the latter may not
        //    persist correctly within a grant type provider transaction in KC 26.
        String origin = extractOrigin(idpAlias);
        newUser.setAttribute("origin", List.of(origin));
        LOG.infof("Set origin attribute to '%s' for user '%s'", origin, namespacedUsername);

        // Track for post-process re-application (super.process() may refresh user entity)
        this.jitProvisionedUsername = namespacedUsername;
        this.jitProvisionedOrigin = origin;

        // 4. Grant default realm roles
        RoleModel defaultRole = realm.getDefaultRole();
        if (defaultRole != null) {
            defaultRole.getCompositesStream().forEach(newUser::grantRole);
        }

        // 5. Create federated identity link
        FederatedIdentityModel fedIdentity = new FederatedIdentityModel(
                idpAlias, upstreamSub, effectiveUsername);
        kcSession.users().addFederatedIdentity(realm, newUser, fedIdentity);

        LOG.infof("Created user '%s' in realm '%s' (origin: %s)",
                namespacedUsername, realm.getName(), origin);

        // 6. Add to organization linked to this IDP
        addToOrganization(realm, newUser, idpAlias);

        LOG.infof("JIT provisioning complete for '%s'", namespacedUsername);
    }

    /**
     * Adds the user to the organization that is linked to the given IDP.
     * Organizations are pre-created via provision-minimal.sh.
     */
    private void addToOrganization(RealmModel realm, UserModel user, String idpAlias) {
        try {
            OrganizationProvider orgProvider = kcSession.getProvider(OrganizationProvider.class);
            if (orgProvider == null) {
                LOG.warn("OrganizationProvider not available — cannot add user to org");
                return;
            }

            // Find the org by convention name: e.g., "kc-a-external-users" for IDP "kc-a-idp"
            String expectedOrgName = extractOrigin(idpAlias) + "-external-users";
            LOG.infof("Looking for organization '%s' to add user '%s'", expectedOrgName, user.getUsername());

            // Use the organizations stream to find by name
            var allOrgs = orgProvider.getAllStream(expectedOrgName, null, null, null);
            var matchingOrg = allOrgs
                    .filter(o -> expectedOrgName.equals(o.getName()))
                    .findFirst()
                    .orElse(null);

            if (matchingOrg != null) {
                // Check if already a member (idempotency)
                // getByMember() returns Stream<OrganizationModel>, not a single object
                boolean alreadyMember = orgProvider.getByMember(user).findAny().isPresent();
                if (alreadyMember) {
                    LOG.debugf("User '%s' already in an organization", user.getUsername());
                    return;
                }

                orgProvider.addManagedMember(matchingOrg, user);
                LOG.infof("Added user '%s' to organization '%s'",
                        user.getUsername(), matchingOrg.getName());
            } else {
                LOG.warnf("Organization '%s' not found for IDP '%s' — user created without org membership",
                        expectedOrgName, idpAlias);
            }
        } catch (Exception e) {
            LOG.errorf("Failed to add user '%s' to organization: %s",
                    user.getUsername(), e.getMessage());
            LOG.debug("Organization membership error details", e);
            // Non-fatal: user is still created and linked, just missing org membership
        }
    }

    /**
     * Extracts origin from IDP alias.
     * Convention: "kc-a-idp" → "kc-a", "kc-b-idp" → "kc-b"
     */
    private String extractOrigin(String idpAlias) {
        if (idpAlias.endsWith("-idp")) {
            return idpAlias.substring(0, idpAlias.length() - 4);
        }
        return idpAlias;
    }

    /**
     * Decodes a JWT payload without validation (just base64-decode the middle part).
     * Full signature validation is performed by the parent class.
     */
    private JsonWebToken decodeJwtPayload(String token) {
        try {
            String[] parts = token.split("\\.");
            if (parts.length < 2) return null;
            String payload = parts[1];
            byte[] decoded = Base64.getUrlDecoder().decode(payload);
            return JsonSerialization.readValue(decoded, JsonWebToken.class);
        } catch (Exception e) {
            LOG.warnf("Failed to decode assertion JWT payload: %s", e.getMessage());
            return null;
        }
    }

    /**
     * Safely extracts a String claim from the JWT's other claims map.
     */
    private String getStringClaim(JsonWebToken jwt, String claimName) {
        Object value = jwt.getOtherClaims().get(claimName);
        return value instanceof String ? (String) value : null;
    }
}
