package com.example;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import io.quarkus.oidc.IdToken;
import io.quarkus.qute.Template;
import io.quarkus.qute.TemplateInstance;
import io.quarkus.security.Authenticated;
import io.quarkus.security.identity.SecurityIdentity;
import jakarta.inject.Inject;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.eclipse.microprofile.jwt.JsonWebToken;

import java.util.ArrayList;
import java.util.List;
import java.util.Optional;

@Path("/")
public class UiResource {

    /** Represents one hop in the service chain (App-B, App-C, etc.) */
    public record ServiceHop(
            String service,
            String message,
            String name,
            String email,
            String roles,
            String tokenIssuer,
            String organization,
            String error
    ) {}

    @Inject
    Template index;

    @Inject
    @IdToken
    JsonWebToken idToken;

    @Inject
    SecurityIdentity securityIdentity;

    @Inject
    TokenExchangeService tokenExchangeService;

    @ConfigProperty(name = "app.name")
    String appName;

    @ConfigProperty(name = "app.target-service-url")
    Optional<String> targetServiceUrl;

    @GET
    @Produces(MediaType.TEXT_HTML)
    public TemplateInstance welcome() {
        return index.data("appName", appName)
                .data("authenticated", false)
                .data("userName", "Anonymous")
                .data("email", "")
                .data("roles", "")
                .data("hasTargetService", targetServiceUrl.isPresent() && !targetServiceUrl.get().isBlank())
                .data("serviceResponse", "")
                .data("serviceChain", List.of())
                .data("prettyJson", "")
                .data("isError", false);
    }

    @GET
    @Path("/secured")
    @Authenticated
    @Produces(MediaType.TEXT_HTML)
    public TemplateInstance secured() {
        return buildSecuredPage("");
    }

    @GET
    @Path("/secured/call-service")
    @Authenticated
    @Produces(MediaType.TEXT_HTML)
    public TemplateInstance callService() {
        String serviceResponse;
        if (targetServiceUrl.isEmpty() || targetServiceUrl.get().isBlank()) {
            serviceResponse = "No target service configured.";
        } else {
            serviceResponse = tokenExchangeService.callDownstreamService();
        }
        return buildSecuredPage(serviceResponse);
    }

    private TemplateInstance buildSecuredPage(String serviceResponse) {
        String name = idToken.getClaim("preferred_username");
        if (name == null || name.isBlank()) {
            name = idToken.getName();
        }
        String email = idToken.getClaim("email");

        // Get roles from SecurityIdentity (populated from access token by Quarkus OIDC)
        var rolesSet = securityIdentity.getRoles();
        String roles = (rolesSet != null && !rolesSet.isEmpty()) ? String.join(", ", rolesSet) : "none";

        // Parse service response into structured data for card display
        List<ServiceHop> serviceChain = List.of();
        String prettyJson = "";
        boolean isError = false;

        if (serviceResponse != null && !serviceResponse.isEmpty()) {
            if (serviceResponse.trim().startsWith("{")) {
                serviceChain = parseServiceChain(serviceResponse);
                prettyJson = prettyPrintJson(serviceResponse);
            } else {
                // Non-JSON response (error message)
                isError = true;
                prettyJson = serviceResponse;
            }
        }

        return index.data("appName", appName)
                .data("authenticated", true)
                .data("userName", name != null ? name : "Unknown")
                .data("email", email != null ? email : "N/A")
                .data("roles", roles)
                .data("hasTargetService", targetServiceUrl.isPresent() && !targetServiceUrl.get().isBlank())
                .data("serviceResponse", serviceResponse)
                .data("serviceChain", serviceChain)
                .data("prettyJson", prettyJson)
                .data("isError", isError);
    }

    // ---- JSON parsing helpers for structured UI display ----

    /**
     * Parses the raw JSON response into a list of ServiceHop records,
     * recursively expanding nested downstreamResponse JSON strings.
     */
    private List<ServiceHop> parseServiceChain(String rawJson) {
        List<ServiceHop> hops = new ArrayList<>();
        try {
            ObjectMapper mapper = new ObjectMapper();
            JsonNode node = mapper.readTree(rawJson);
            addHop(hops, node, mapper);
        } catch (Exception ignored) {
            // If parsing fails, return empty list; raw JSON will still be shown
        }
        return hops;
    }

    private void addHop(List<ServiceHop> hops, JsonNode node, ObjectMapper mapper) {
        if (node == null || !node.isObject()) return;

        hops.add(new ServiceHop(
                textOrDefault(node, "service", "Unknown Service"),
                textOrDefault(node, "message", ""),
                textOrDefault(node, "name", "N/A"),
                textOrDefault(node, "email", "N/A"),
                textOrDefault(node, "roles", "none"),
                textOrDefault(node, "tokenIssuer", ""),
                extractOrgName(node),
                textOrDefault(node, "downstreamError", null)
        ));

        // Recursively parse nested downstream response (it's a JSON string)
        JsonNode downstream = node.get("downstreamResponse");
        if (downstream != null && downstream.isTextual()) {
            String dsText = downstream.asText();
            if (dsText.trim().startsWith("{")) {
                try {
                    JsonNode nested = mapper.readTree(dsText);
                    addHop(hops, nested, mapper);
                } catch (Exception ignored) {}
            }
        }
    }

    /**
     * Extracts the organization name from the KC 26 organization claim.
     * KC 26 can emit the claim in different formats:
     *   - Array: ["org-name-1", "org-name-2"]
     *   - Object: {"<org-id>": {"name": "Org Name"}}
     */
    private String extractOrgName(JsonNode node) {
        JsonNode org = node.get("organization");
        if (org == null || org.isNull()) return null;

        // Array format: ["kc-a-external-users"]
        if (org.isArray() && !org.isEmpty()) {
            return org.get(0).asText();
        }

        // Object format: {"<org-id>": {"name": "Org Name"}}
        if (org.isObject()) {
            var fields = org.fields();
            if (fields.hasNext()) {
                var entry = fields.next();
                JsonNode orgData = entry.getValue();
                if (orgData != null && orgData.isObject() && orgData.has("name")) {
                    return orgData.get("name").asText();
                }
                return entry.getKey();
            }
        }

        return null;
    }

    private String textOrDefault(JsonNode node, String field, String defaultValue) {
        JsonNode value = node.get(field);
        return (value != null && !value.isNull() && !value.asText().isBlank())
                ? value.asText() : defaultValue;
    }

    /**
     * Pretty-prints JSON with indentation, recursively expanding nested JSON
     * strings (like downstreamResponse) into real JSON objects for readability.
     */
    private String prettyPrintJson(String rawJson) {
        try {
            ObjectMapper mapper = new ObjectMapper();
            JsonNode root = mapper.readTree(rawJson);
            expandNestedJson(root, mapper);
            return mapper.writerWithDefaultPrettyPrinter().writeValueAsString(root);
        } catch (Exception e) {
            return rawJson;
        }
    }

    private void expandNestedJson(JsonNode node, ObjectMapper mapper) {
        if (!node.isObject()) return;
        ObjectNode obj = (ObjectNode) node;
        List<String> fieldNames = new ArrayList<>();
        obj.fieldNames().forEachRemaining(fieldNames::add);
        for (String field : fieldNames) {
            JsonNode child = obj.get(field);
            if (child.isTextual()) {
                String text = child.asText().trim();
                if (text.startsWith("{") || text.startsWith("[")) {
                    try {
                        JsonNode parsed = mapper.readTree(text);
                        if (parsed.isObject() || parsed.isArray()) {
                            expandNestedJson(parsed, mapper);
                            obj.set(field, parsed);
                        }
                    } catch (Exception ignored) {}
                }
            } else {
                expandNestedJson(child, mapper);
            }
        }
    }
}
