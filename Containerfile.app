# =============================================================================
# Multi-stage build for the Quarkus demo application (App-A, App-B, App-C).
# All three instances use the same image, differentiated by env vars at runtime.
#
# Stage 1: Build the fast-jar using Maven wrapper
# Stage 2: Minimal runtime image with the built artifact
# =============================================================================

# Stage 1: Build
FROM registry.access.redhat.com/ubi9/openjdk-21:latest AS builder
WORKDIR /build
COPY --chown=185 . .
RUN ./mvnw package -pl app -DskipTests -Dquarkus.package.jar.type=fast-jar

# Stage 2: Runtime
FROM registry.access.redhat.com/ubi9/openjdk-21-runtime:latest
ENV LANGUAGE='en_US:en'
COPY --from=builder --chown=185 /build/app/target/quarkus-app/lib/ /deployments/lib/
COPY --from=builder --chown=185 /build/app/target/quarkus-app/*.jar /deployments/
COPY --from=builder --chown=185 /build/app/target/quarkus-app/app/ /deployments/app/
COPY --from=builder --chown=185 /build/app/target/quarkus-app/quarkus/ /deployments/quarkus/
EXPOSE 8080
ENV JAVA_OPTS_APPEND="-Dquarkus.http.host=0.0.0.0 -Djava.util.logging.manager=org.jboss.logmanager.LogManager"
ENV JAVA_APP_JAR="/deployments/quarkus-run.jar"
