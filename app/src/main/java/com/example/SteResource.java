package com.example;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.quarkus.security.Authenticated;
import jakarta.inject.Inject;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import org.eclipse.microprofile.config.inject.ConfigProperty;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Optional;
import java.util.logging.Level;
import java.util.logging.Logger;

/**
 * Orchestrates the within-realm Standard Token Exchange (RFC 8693) demo for App-A.
 *
 * For the authenticated caller it:
 *   1. Calls /api/internal with the ORIGINAL token (forward-as-is — expected 403,
 *      wrong audience).
 *   2. Performs the within-realm Standard Token Exchange to obtain a token whose
 *      audience is app-a-internal.
 *   3. Calls /api/internal again with the EXCHANGED token (expected 200 if the
 *      user has reports-reader, else 403 not entitled).
 *
 * Returns JSON:
 *   {
 *     "original":  { "status": <int>, "claims|reason": ... },
 *     "exchanged": { "status": <int>, "claims|reason": ... },
 *     "before":    <original token claims (aud/roles/...)>,
 *     "after":     <exchanged token claims (aud/roles/...)>
 *   }
 *
 * Works in BOTH web-app session mode and bearer mode (mirrors TokenExchangeService),
 * so it is testable with a plain Bearer token.
 */
@Path("/api/ste")
@Authenticated
public class SteResource {

    private static final Logger LOG = Logger.getLogger(SteResource.class.getName());
    private static final ObjectMapper MAPPER = new ObjectMapper();

    @Inject
    TokenExchangeService tokenExchangeService;

    @ConfigProperty(name = "app.internal-url")
    Optional<String> internalUrl;

    @GET
    @Produces(MediaType.APPLICATION_JSON)
    public Map<String, Object> ste() {
        Map<String, Object> result = new LinkedHashMap<>();

        if (internalUrl.isEmpty() || internalUrl.get().isBlank()) {
            result.put("error", "app.internal-url is not configured.");
            return result;
        }

        String originalToken = tokenExchangeService.getCurrentAccessToken();
        if (originalToken == null || originalToken.isBlank()) {
            result.put("error", "No access token available for the current caller.");
            return result;
        }

        // ---- Step 1: forward-as-is (ORIGINAL token) ----
        result.put("before", decodeClaims(originalToken));
        result.put("original", callInternal(originalToken));

        // ---- Step 2 + 3: Standard Token Exchange, then call with EXCHANGED token ----
        String exchangedToken;
        try {
            exchangedToken = tokenExchangeService.exchangeWithinRealm();
        } catch (Exception e) {
            LOG.log(Level.SEVERE, "Standard Token Exchange failed", e);
            Map<String, Object> exchanged = new LinkedHashMap<>();
            exchanged.put("status", 0);
            exchanged.put("reason", "Token exchange failed: " + e.getMessage());
            result.put("exchanged", exchanged);
            result.put("after", Map.of());
            return result;
        }

        result.put("after", decodeClaims(exchangedToken));
        result.put("exchanged", callInternal(exchangedToken));

        return result;
    }

    /**
     * Calls /api/internal with the given bearer token and captures status + body.
     */
    private Map<String, Object> callInternal(String bearerToken) {
        Map<String, Object> outcome = new LinkedHashMap<>();
        try {
            HttpRequest request = HttpRequest.newBuilder()
                    .uri(URI.create(internalUrl.get()))
                    .header("Authorization", "Bearer " + bearerToken)
                    .header("Accept", "application/json")
                    .GET()
                    .build();

            try (HttpClient client = HttpClient.newHttpClient()) {
                HttpResponse<String> response = client.send(request, HttpResponse.BodyHandlers.ofString());
                outcome.put("status", response.statusCode());
                JsonNode body = parseJsonOrNull(response.body());
                if (body != null) {
                    outcome.put("body", body);
                } else {
                    outcome.put("body", response.body());
                }
            }
        } catch (Exception e) {
            outcome.put("status", 0);
            outcome.put("reason", "Call to /api/internal failed: " + e.getMessage());
        }
        return outcome;
    }

    /**
     * Decodes a JWT's payload and extracts the claims relevant to the demo
     * (preferred_username, aud, realm_access.roles, scope).
     */
    private Map<String, Object> decodeClaims(String jwt) {
        Map<String, Object> claims = new LinkedHashMap<>();
        try {
            String[] parts = jwt.split("\\.");
            if (parts.length < 2) {
                claims.put("error", "not a JWT");
                return claims;
            }
            byte[] decoded = Base64.getUrlDecoder().decode(parts[1]);
            JsonNode node = MAPPER.readTree(decoded);
            claims.put("preferred_username", node.path("preferred_username").asText(null));
            claims.put("aud", node.get("aud"));
            JsonNode roles = node.path("realm_access").path("roles");
            claims.put("roles", roles.isMissingNode() ? null : roles);
            claims.put("scope", node.path("scope").asText(null));
        } catch (Exception e) {
            claims.put("error", "Could not decode token: " + e.getMessage());
        }
        return claims;
    }

    private JsonNode parseJsonOrNull(String s) {
        if (s == null || s.isBlank()) {
            return null;
        }
        try {
            return MAPPER.readTree(s);
        } catch (Exception e) {
            return null;
        }
    }
}
