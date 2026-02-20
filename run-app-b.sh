#!/bin/bash
# Run App-B (Service) on port 8082, connected to KC-B on port 8280
# This is a bearer-only service called by App-A.

export JAVA_HOME=${JAVA_HOME:-$HOME/.sdkman/candidates/java/current}
export PATH=$HOME/.sdkman/candidates/maven/current/bin:$JAVA_HOME/bin:$PATH

echo "================================================"
echo " Starting App-B (Service) on port 8082"
echo " Keycloak: http://localhost:8280 (realm-b)"
echo " API URL:  http://localhost:8082/api/hello"
echo "================================================"

./mvnw quarkus:dev -pl app -Dquarkus.profile=app-b -Ddebug=5006
