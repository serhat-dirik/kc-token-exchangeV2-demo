package com.example;

import io.quarkus.oidc.OidcSession;
import jakarta.enterprise.inject.Instance;
import jakarta.inject.Inject;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.core.Context;
import jakarta.ws.rs.core.Response;
import jakarta.ws.rs.core.UriInfo;
import org.eclipse.microprofile.config.inject.ConfigProperty;

import java.net.URI;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;

/**
 * Handles logout by terminating both the Quarkus OIDC session (local cookie)
 * and the Keycloak SSO session (via OIDC RP-Initiated Logout redirect).
 *
 * Without the KC redirect, the KC SSO cookie remains valid and the next
 * login attempt auto-authenticates without prompting for credentials.
 */
@Path("/logout")
public class LogoutResource {

    @Inject
    Instance<OidcSession> oidcSession;

    @ConfigProperty(name = "quarkus.oidc.auth-server-url")
    String oidcAuthServerUrl;

    @GET
    public Response logout(@Context UriInfo uriInfo) {
        String idToken = null;

        // Invalidate the Quarkus-side session and capture the ID token for KC logout
        if (oidcSession.isResolvable()) {
            OidcSession session = oidcSession.get();
            idToken = session.getIdToken().getRawToken();
            session.logout().await().indefinitely();
        }

        // Build absolute post-logout redirect URI (KC requires absolute URLs)
        String postLogoutUri = uriInfo.getBaseUri().resolve("/").toString();

        // Redirect to KC end-session endpoint to terminate the SSO session
        String endSessionUrl = oidcAuthServerUrl + "/protocol/openid-connect/logout";

        StringBuilder logoutUrl = new StringBuilder(endSessionUrl);
        logoutUrl.append("?post_logout_redirect_uri=")
                .append(URLEncoder.encode(postLogoutUri, StandardCharsets.UTF_8));
        if (idToken != null) {
            logoutUrl.append("&id_token_hint=").append(idToken);
        }

        return Response.seeOther(URI.create(logoutUrl.toString())).build();
    }
}
