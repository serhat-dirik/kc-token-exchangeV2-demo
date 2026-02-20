#!/bin/bash
# Run App-A (UI + Service) on port 8081, connected to KC-A on port 8180
# This is the user-facing app with login UI.

export JAVA_HOME=${JAVA_HOME:-$HOME/.sdkman/candidates/java/current}
export PATH=$HOME/.sdkman/candidates/maven/current/bin:$JAVA_HOME/bin:$PATH

echo "================================================"
echo " Starting App-A (UI + Service) on port 8081"
echo " Keycloak: http://localhost:8180 (realm-a)"
echo " App URL:  http://localhost:8081"
echo "================================================"

./mvnw quarkus:dev -pl app -Dquarkus.profile=app-a -Ddebug=5005
