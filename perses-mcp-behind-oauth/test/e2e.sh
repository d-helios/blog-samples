#!/usr/bin/env bash
# Runs from the host: *.localhost resolves to the kind ingress on 127.0.0.1.
# The gateway serves HTTPS with a certificate from the lab CA, so every curl
# trusts that CA explicitly (loaded from passage).
set -euo pipefail

MCP=https://mcp.localhost
TOKEN_URL=https://auth.localhost/application/o/token/
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"e2e","version":"0"}}}'
fail=0

CACERT="$(mktemp)"
trap 'rm -f "$CACERT"' EXIT
passage show local/lab/ca.pem > "$CACERT"

check() { # name, expected, actual
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want $2, got $3"; fail=1; fi
}

token() { # user, app password
  curl -fsS --cacert "$CACERT" "$TOKEN_URL" -d grant_type=client_credentials -d client_id=perses-mcp -d "scope=openid profile" \
    -d "username=$1" -d "password=$2" | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])'
}

mcp_init() { # extra curl args
  curl -s --cacert "$CACERT" -o /dev/null -w '%{http_code}' "$MCP/mcp" -X POST \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' "$@" -d "$INIT"
}

headers=$(curl -s --cacert "$CACERT" -D - -o /dev/null "$MCP/mcp" -X POST -H 'Content-Type: application/json' -d "$INIT")
check "no token: 401" 401 "$(echo "$headers" | head -1 | awk '{print $2}')"
echo "$headers" | grep -qi '^www-authenticate: Bearer resource_metadata="https://mcp.localhost/.well-known/oauth-protected-resource"' \
  && echo "ok   no token: WWW-Authenticate points at resource metadata" \
  || { echo "FAIL no token: WWW-Authenticate missing"; fail=1; }

check "protected resource metadata" https://auth.localhost/application/o/perses-mcp/ \
  "$(curl -fsS --cacert "$CACERT" $MCP/.well-known/oauth-protected-resource | python3 -c 'import json,sys; print(json.load(sys.stdin)["authorization_servers"][0])')"

check "issuer is https" https://auth.localhost/application/o/perses-mcp/ \
  "$(curl -fsS --cacert "$CACERT" $MCP/.well-known/oauth-protected-resource >/dev/null && curl -fsS --cacert "$CACERT" https://auth.localhost/application/o/perses-mcp/.well-known/openid-configuration | python3 -c 'import json,sys; print(json.load(sys.stdin)["issuer"])')"

check "garbage token: 401" 401 "$(mcp_init -H 'Authorization: Bearer not-a-jwt')"
check "alice (Observability MCP): 200" 200 "$(mcp_init -H "Authorization: Bearer $(token alice alice-app-password)")"
check "bob (no group): 403" 403 "$(mcp_init -H "Authorization: Bearer $(token bob bob-app-password)")"

exit $fail
