#!/bin/bash
# Run App-C (Terminal Service) on port 8083, connected to KC-C on port 8380
# This is the terminal service in the chain.

export JAVA_HOME=${JAVA_HOME:-$HOME/.sdkman/candidates/java/current}
export PATH=$HOME/.sdkman/candidates/maven/current/bin:$JAVA_HOME/bin:$PATH

echo "================================================"
echo " Starting App-C (Terminal Service) on port 8083"
echo " Keycloak: http://localhost:8380 (realm-c)"
echo " API URL:  http://localhost:8083/api/hello"
echo "================================================"

./mvnw quarkus:dev -pl app -Dquarkus.profile=app-c -Ddebug=5007
