package com.example;

import io.quarkus.security.Authenticated;
import jakarta.inject.Inject;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.eclipse.microprofile.jwt.JsonWebToken;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Optional;

/**
 * Service endpoint accessible with a bearer token.
 * Returns user info and optionally chains to the next downstream service.
 */
@Path("/api/hello")
@Authenticated
public class HelloResource {

    @Inject
    JsonWebToken accessToken;

    @Inject
    TokenExchangeService tokenExchangeService;

    @ConfigProperty(name = "app.name")
    String appName;

    @ConfigProperty(name = "app.target-service-url")
    Optional<String> targetServiceUrl;

    @GET
    @Produces(MediaType.APPLICATION_JSON)
    public Map<String, Object> hello() {
        String user = accessToken.getClaim("preferred_username");
        if (user == null) {
            user = accessToken.getSubject();
        }
        String email = accessToken.getClaim("email");
        String fullName = accessToken.getClaim("name");
        var roles = accessToken.getGroups();

        Map<String, Object> response = new LinkedHashMap<>();
        response.put("service", appName);
        response.put("message", "Hello " + (user != null ? user : "unknown") + "!");
        response.put("name", fullName != null ? fullName : "N/A");
        response.put("email", email != null ? email : "N/A");
        response.put("roles", roles != null ? String.join(", ", roles) : "none");
        response.put("tokenIssuer", accessToken.getIssuer());

        // Include organization claim if present (KC 26 Organizations feature)
        Object orgClaim = accessToken.getClaim("organization");
        if (orgClaim != null) {
            response.put("organization", orgClaim);
        }

        // Chain to downstream service if configured
        if (targetServiceUrl.isPresent() && !targetServiceUrl.get().isBlank()) {
            try {
                String downstreamResponse = tokenExchangeService.callDownstreamService();
                response.put("downstreamResponse", downstreamResponse);
            } catch (Exception e) {
                response.put("downstreamError", e.getMessage());
            }
        }

        return response;
    }
}
