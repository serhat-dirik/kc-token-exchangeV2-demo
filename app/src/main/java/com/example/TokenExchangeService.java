package com.example;

import io.quarkus.oidc.AccessTokenCredential;
import io.quarkus.oidc.RefreshToken;
import jakarta.enterprise.context.RequestScoped;
import jakarta.enterprise.inject.Instance;
import jakarta.inject.Inject;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.eclipse.microprofile.jwt.JsonWebToken;

import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.util.Map;
import java.util.Optional;
import java.util.logging.Level;
import java.util.logging.Logger;
import java.util.stream.Collectors;

/**
 * Performs RFC 7523 JWT Authorization Grant to exchange the current user's token
 * for a token at the downstream Keycloak, then calls the downstream service.
 *
 * Flow:
 * 1. Get current access token (from OIDC session for web-app, or injected JWT for service)
 * 2. POST to downstream KC token endpoint with grant_type=jwt-bearer
 * 3. Use the resulting access token to call the downstream service
 *
 * Important: KC's JWT Authorization Grant enforces single-use on the assertion's jti claim.
 * In web-app mode, we use the refresh token to obtain a fresh access token (with a new jti)
 * before each JWT Grant call, preventing "Token reuse detected" errors.
 */
@RequestScoped
public class TokenExchangeService {

    private static final Logger LOG = Logger.getLogger(TokenExchangeService.class.getName());

    // In service mode (bearer-only), the injected JWT IS the access token
    @Inject
    JsonWebToken jwt;

    // In web-app mode, the access token is available via AccessTokenCredential
    @Inject
    Instance<AccessTokenCredential> accessTokenCredential;

    @ConfigProperty(name = "app.target-service-url")
    Optional<String> targetServiceUrl;

    @ConfigProperty(name = "app.target-kc-token-url")
    Optional<String> targetKcTokenUrl;

    @ConfigProperty(name = "app.target-kc-client-id")
    Optional<String> targetKcClientId;

    @ConfigProperty(name = "app.target-kc-client-secret")
    Optional<String> targetKcClientSecret;

    // OIDC token endpoint and client credentials for the LOCAL KC (used for token refresh)
    @ConfigProperty(name = "quarkus.oidc.auth-server-url")
    String oidcAuthServerUrl;

    @ConfigProperty(name = "quarkus.oidc.client-id")
    String oidcClientId;

    @ConfigProperty(name = "quarkus.oidc.credentials.secret")
    String oidcClientSecret;

    public String callDownstreamService() {
        if (targetServiceUrl.isEmpty() || targetServiceUrl.get().isBlank()) {
            return "No downstream service configured.";
        }

        try {
            // Get the raw access token string
            String assertion = resolveAccessToken();
            if (assertion == null || assertion.isBlank()) {
                return "Error: No access token available for JWT Grant exchange.";
            }

            LOG.info("Performing JWT Authorization Grant exchange to: " + targetKcTokenUrl.orElse(""));

            // Step 1: Exchange token using RFC 7523 JWT Authorization Grant
            String downstreamToken = performJwtGrant(assertion);

            // Step 2: Call downstream service with the new token
            return callService(downstreamToken);
        } catch (Exception e) {
            LOG.log(Level.SEVERE, "Token exchange or service call failed", e);
            return "Error calling downstream service: " + e.getMessage();
        }
    }

    /**
     * Resolves the current access token. In web-app mode, uses the refresh token to
     * obtain a fresh access token with a new jti before each JWT Grant call.
     * In service/bearer mode, uses the injected JsonWebToken directly.
     */
    private String resolveAccessToken() {
        // Try AccessTokenCredential first (web-app mode)
        if (accessTokenCredential.isResolvable()) {
            try {
                AccessTokenCredential cred = accessTokenCredential.get();
                if (cred != null) {
                    // In web-app mode, use the refresh token to get a FRESH access token
                    // with a new jti. This is required because KC's JWT Authorization Grant
                    // enforces single-use on the assertion's jti claim — reusing the same
                    // access token will fail with "Token reuse detected".
                    RefreshToken refreshToken = cred.getRefreshToken();
                    if (refreshToken != null && refreshToken.getToken() != null
                            && !refreshToken.getToken().isBlank()) {
                        LOG.info("Refreshing access token to obtain fresh jti for JWT Grant assertion");
                        String freshToken = refreshAccessToken(refreshToken.getToken());
                        if (freshToken != null && !freshToken.isBlank()) {
                            LOG.info("Using refreshed access token (web-app mode, fresh jti)");
                            return freshToken;
                        }
                    }

                    // Fallback: use the cached access token if refresh is not available
                    String token = cred.getToken();
                    if (token != null && !token.isBlank()) {
                        LOG.info("Using cached AccessTokenCredential (web-app mode)");
                        return token;
                    }
                }
            } catch (Exception e) {
                LOG.fine("AccessTokenCredential not available, falling back to JWT: " + e.getMessage());
            }
        }
        // Fallback: injected JWT (service/bearer mode)
        // In service mode (App-B, App-C), each incoming HTTP request carries a unique
        // bearer token from a fresh JWT Grant performed by the upstream caller. The jti
        // is already unique per request, so no token refresh is needed.
        if (jwt != null && jwt.getRawToken() != null) {
            LOG.info("Using injected JWT (service mode)");
            return jwt.getRawToken();
        }
        return null;
    }

    /**
     * Uses the refresh token to obtain a fresh access token from the local KC instance.
     * The new access token will have a new jti, satisfying KC's single-use enforcement.
     */
    private String refreshAccessToken(String refreshTokenValue) {
        try {
            String tokenUrl = oidcAuthServerUrl + "/protocol/openid-connect/token";
            Map<String, String> formData = Map.of(
                    "grant_type", "refresh_token",
                    "refresh_token", refreshTokenValue,
                    "client_id", oidcClientId,
                    "client_secret", oidcClientSecret
            );

            String body = formData.entrySet().stream()
                    .map(e -> URLEncoder.encode(e.getKey(), StandardCharsets.UTF_8) + "="
                            + URLEncoder.encode(e.getValue(), StandardCharsets.UTF_8))
                    .collect(Collectors.joining("&"));

            HttpRequest request = HttpRequest.newBuilder()
                    .uri(URI.create(tokenUrl))
                    .header("Content-Type", "application/x-www-form-urlencoded")
                    .POST(HttpRequest.BodyPublishers.ofString(body))
                    .build();

            try (HttpClient client = HttpClient.newHttpClient()) {
                HttpResponse<String> response = client.send(request, HttpResponse.BodyHandlers.ofString());
                if (response.statusCode() == 200) {
                    return extractAccessToken(response.body());
                }
                LOG.warning("Token refresh failed: HTTP " + response.statusCode() + " - " + response.body());
            }
        } catch (Exception e) {
            LOG.warning("Token refresh failed: " + e.getMessage());
        }
        return null;
    }

    /**
     * RFC 7523 JWT Authorization Grant:
     * POST /realms/{realm}/protocol/openid-connect/token
     * grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer
     * assertion={upstream_access_token}
     * client_id={client_id}
     * client_secret={client_secret}
     * scope=openid
     */
    private String performJwtGrant(String assertion) throws Exception {
        Map<String, String> formData = Map.of(
                "grant_type", "urn:ietf:params:oauth:grant-type:jwt-bearer",
                "assertion", assertion,
                "client_id", targetKcClientId.orElse(""),
                "client_secret", targetKcClientSecret.orElse(""),
                "scope", "openid organization"
        );

        String body = formData.entrySet().stream()
                .map(e -> URLEncoder.encode(e.getKey(), StandardCharsets.UTF_8) + "="
                        + URLEncoder.encode(e.getValue(), StandardCharsets.UTF_8))
                .collect(Collectors.joining("&"));

        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(targetKcTokenUrl.orElse("")))
                .header("Content-Type", "application/x-www-form-urlencoded")
                .POST(HttpRequest.BodyPublishers.ofString(body))
                .build();

        try (HttpClient client = HttpClient.newHttpClient()) {
            HttpResponse<String> response = client.send(request, HttpResponse.BodyHandlers.ofString());

            if (response.statusCode() != 200) {
                LOG.severe("JWT Grant failed: HTTP " + response.statusCode() + " - " + response.body());
                return "JWT Grant exchange failed (HTTP " + response.statusCode() + "): " + response.body();
            }

            return extractAccessToken(response.body());
        }
    }

    private String extractAccessToken(String jsonResponse) {
        int idx = jsonResponse.indexOf("\"access_token\"");
        if (idx < 0) {
            throw new RuntimeException("No access_token in response: " + jsonResponse);
        }
        int colonIdx = jsonResponse.indexOf(':', idx);
        int startQuote = jsonResponse.indexOf('"', colonIdx + 1);
        int endQuote = jsonResponse.indexOf('"', startQuote + 1);
        return jsonResponse.substring(startQuote + 1, endQuote);
    }

    private String callService(String bearerToken) throws Exception {
        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(targetServiceUrl.orElse("")))
                .header("Authorization", "Bearer " + bearerToken)
                .header("Accept", "application/json")
                .GET()
                .build();

        try (HttpClient client = HttpClient.newHttpClient()) {
            HttpResponse<String> response = client.send(request, HttpResponse.BodyHandlers.ofString());

            if (response.statusCode() != 200) {
                return "Downstream error (HTTP " + response.statusCode() + "): " + response.body();
            }
            return response.body();
        }
    }
}
