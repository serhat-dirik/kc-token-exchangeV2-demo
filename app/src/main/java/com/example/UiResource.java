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
import java.util.Map;
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

    /**
     * View model for the within-realm Standard Token Exchange (RFC 8693) panel.
     * Captures both call outcomes plus the before/after token audience and roles.
     */
    public record SteView(
            int originalStatus,
            String originalReason,
            String beforeAud,
            String beforeRoles,
            int exchangedStatus,
            String exchangedReason,
            String afterAud,
            String afterRoles,
            String prettyJson
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

    @Inject
    SteResource steResource;

    @ConfigProperty(name = "app.name")
    String appName;

    @ConfigProperty(name = "app.target-service-url")
    Optional<String> targetServiceUrl;

    @ConfigProperty(name = "app.internal-url")
    Optional<String> internalUrl;

    @GET
    @Produces(MediaType.TEXT_HTML)
    public TemplateInstance welcome() {
        return index.data("appName", appName)
                .data("authenticated", false)
                .data("userName", "Anonymous")
                .data("email", "")
                .data("roles", "")
                .data("hasTargetService", targetServiceUrl.isPresent() && !targetServiceUrl.get().isBlank())
                .data("hasInternalService", internalUrl.isPresent() && !internalUrl.get().isBlank())
                .data("serviceResponse", "")
                .data("serviceChain", List.of())
                .data("prettyJson", "")
                .data("isError", false)
                .data("steResult", null);
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

    @GET
    @Path("/secured/call-internal")
    @Authenticated
    @Produces(MediaType.TEXT_HTML)
    public TemplateInstance callInternal() {
        // Orchestrate forward-as-is + Standard Token Exchange via SteResource,
        // then render the structured outcome (before/after aud + roles, statuses).
        SteView view = null;
        if (internalUrl.isPresent() && !internalUrl.get().isBlank()) {
            try {
                Map<String, Object> ste = steResource.ste();
                view = toSteView(ste);
            } catch (Exception e) {
                view = new SteView(0, "STE error: " + e.getMessage(), "", "",
                        0, "", "", "", prettyPrintObject(Map.of("error", e.getMessage())));
            }
        }
        return buildSecuredPage("", view);
    }

    private TemplateInstance buildSecuredPage(String serviceResponse) {
        return buildSecuredPage(serviceResponse, null);
    }

    private TemplateInstance buildSecuredPage(String serviceResponse, SteView steResult) {
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
                .data("hasInternalService", internalUrl.isPresent() && !internalUrl.get().isBlank())
                .data("serviceResponse", serviceResponse)
                .data("serviceChain", serviceChain)
                .data("prettyJson", prettyJson)
                .data("isError", isError)
                .data("steResult", steResult);
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

        // Recursively parse nested downstream response.
        // It may be a JSON string (raw response from callService) or already an object
        // (if the pretty-printer already expanded it).
        JsonNode downstream = node.get("downstreamResponse");
        if (downstream != null) {
            if (downstream.isTextual()) {
                String dsText = downstream.asText();
                if (dsText.trim().startsWith("{")) {
                    try {
                        JsonNode nested = mapper.readTree(dsText);
                        addHop(hops, nested, mapper);
                    } catch (Exception ignored) {}
                }
            } else if (downstream.isObject()) {
                addHop(hops, downstream, mapper);
            }
        }
    }

    /**
     * Extracts the organization name from the KC 26 organization claim.
     * Handles multiple formats:
     *   - String array: ["kc-a-external-users"]  (after API fix)
     *   - Object array: [{"string":"org-name","chars":"org-name","valueType":"STRING"}]  (legacy JsonValue leak)
     *   - Object map: {"<org-id>": {"name": "Org Name"}}  (KC admin API format)
     *   - Simple string: "org-name"
     */
    private String extractOrgName(JsonNode node) {
        JsonNode org = node.get("organization");
        if (org == null || org.isNull()) return null;

        // Array format
        if (org.isArray() && !org.isEmpty()) {
            JsonNode first = org.get(0);
            // Clean string: ["kc-a-external-users"]
            if (first.isTextual()) {
                return first.asText();
            }
            // Legacy JsonValue object: [{"string":"org-name", ...}]
            if (first.isObject() && first.has("string")) {
                return first.get("string").asText();
            }
            return first.asText();
        }

        // Simple string
        if (org.isTextual()) {
            return org.asText();
        }

        // Object map format: {"<org-id>": {"name": "Org Name"}}
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

    // ---- Standard Token Exchange (RFC 8693) view helpers ----

    /**
     * Converts the raw /api/ste result map into the structured {@link SteView}
     * used by the template.
     */
    @SuppressWarnings("unchecked")
    private SteView toSteView(Map<String, Object> ste) {
        Map<String, Object> original = (Map<String, Object>) ste.getOrDefault("original", Map.of());
        Map<String, Object> exchanged = (Map<String, Object>) ste.getOrDefault("exchanged", Map.of());
        Map<String, Object> before = (Map<String, Object>) ste.getOrDefault("before", Map.of());
        Map<String, Object> after = (Map<String, Object>) ste.getOrDefault("after", Map.of());

        return new SteView(
                asInt(original.get("status")),
                reasonOf(original),
                stringOf(before.get("aud")),
                stringOf(before.get("roles")),
                asInt(exchanged.get("status")),
                reasonOf(exchanged),
                stringOf(after.get("aud")),
                stringOf(after.get("roles")),
                prettyPrintObject(ste)
        );
    }

    @SuppressWarnings("unchecked")
    private String reasonOf(Map<String, Object> outcome) {
        if (outcome.containsKey("reason")) {
            return stringOf(outcome.get("reason"));
        }
        Object body = outcome.get("body");
        if (body instanceof JsonNode node) {
            if (node.hasNonNull("reason")) return node.get("reason").asText();
            if (node.hasNonNull("message")) return node.get("message").asText();
        } else if (body instanceof Map<?, ?> map) {
            if (map.containsKey("reason")) return stringOf(map.get("reason"));
            if (map.containsKey("message")) return stringOf(map.get("message"));
        }
        return body != null ? stringOf(body) : "";
    }

    private int asInt(Object o) {
        if (o instanceof Number n) return n.intValue();
        try { return o != null ? Integer.parseInt(o.toString()) : 0; }
        catch (NumberFormatException e) { return 0; }
    }

    private String stringOf(Object o) {
        return o == null ? "" : o.toString();
    }

    private String prettyPrintObject(Object obj) {
        try {
            return new ObjectMapper().writerWithDefaultPrettyPrinter().writeValueAsString(obj);
        } catch (Exception e) {
            return String.valueOf(obj);
        }
    }
}
