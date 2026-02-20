package com.example;

import io.quarkus.oidc.OidcSession;
import jakarta.enterprise.inject.Instance;
import jakarta.inject.Inject;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.core.Response;

import java.net.URI;

@Path("/logout")
public class LogoutResource {

    @Inject
    Instance<OidcSession> oidcSession;

    @GET
    public Response logout() {
        if (oidcSession.isResolvable()) {
            oidcSession.get().logout().await().indefinitely();
        }
        return Response.seeOther(URI.create("/")).build();
    }
}
