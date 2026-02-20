package com.example.spi;

import org.keycloak.Config;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.protocol.oidc.grants.OAuth2GrantType;
import org.keycloak.protocol.oidc.grants.OAuth2GrantTypeFactory;

/**
 * Factory that registers our JIT-enabled JWT Authorization Grant provider.
 *
 * <p>Uses the <strong>same</strong> grant_type ID as the built-in
 * {@code JWTAuthorizationGrantTypeFactory}:
 * {@code urn:ietf:params:oauth:grant-type:jwt-bearer}.
 *
 * <p>By returning a higher {@link #order()} value (1 vs. the default 0),
 * Keycloak's provider loading mechanism selects this factory over the
 * built-in one when multiple factories declare the same provider ID.
 *
 * <p>This means no configuration change is needed in Keycloak — simply
 * placing the SPI JAR in {@code /opt/keycloak/providers/} replaces the
 * built-in JWT Authorization Grant with our JIT-enhanced version.
 */
public class JitJwtAuthorizationGrantTypeFactory implements OAuth2GrantTypeFactory {

    public static final String GRANT_TYPE = "urn:ietf:params:oauth:grant-type:jwt-bearer";

    @Override
    public OAuth2GrantType create(KeycloakSession session) {
        return new JitJwtAuthorizationGrantType(session);
    }

    @Override
    public String getId() {
        return GRANT_TYPE;
    }

    /**
     * Must return the same shortcut as the built-in JWTAuthorizationGrantTypeFactory ("ag").
     * Keycloak uses this as a prefix when building jti tracking IDs for single-use assertion
     * enforcement. Returning a different value (or the full grant type URI) corrupts the
     * token ID format and causes "Incorrect token id... Expected length of 6" errors.
     */
    @Override
    public String getShortcut() {
        return "ag";
    }

    /**
     * Higher priority than the built-in JWTAuthorizationGrantTypeFactory (which returns 0).
     */
    @Override
    public int order() {
        return 1;
    }

    @Override
    public void init(Config.Scope config) {
        // No configuration needed
    }

    @Override
    public void postInit(KeycloakSessionFactory factory) {
        // No post-init needed
    }

    @Override
    public void close() {
        // No resources to clean up
    }
}
