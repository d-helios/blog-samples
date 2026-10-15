# Envoy ext_authz decision for every request to the MCP host.
#
# The JWT signature, issuer, audience and expiry are checked by Istio
# (RequestAuthentication) before this policy runs, so the token is only
# decoded here. A request with a bad token never gets this far.
package envoy.authz

import rego.v1

default result := {
	"allowed": false,
	"http_status": 403,
	"headers": {"content-type": "application/json"},
	"body": "{\"code\":\"forbidden\",\"message\":\"membership of the required group is needed\"}",
}

# Discovery documents must be readable without a token.
result := {"allowed": true} if discovery

result := {"allowed": true, "headers": {"x-auth-subject": subject}} if {
	not discovery
	user_allowed
}

# No token: tell the MCP client where to start the OAuth flow (RFC 9728).
result := object.union(
	deny(401, "unauthenticated", "bearer token required"),
	{"headers": {
		"content-type": "application/json",
		"www-authenticate": sprintf("Bearer resource_metadata=%q", [data.resource_metadata]),
	}},
) if {
	not discovery
	not claims
}

deny(status, code, message) := {
	"allowed": false,
	"http_status": status,
	"headers": {"content-type": "application/json"},
	"body": json.marshal({"code": code, "message": message}),
}

path := input.attributes.request.http.path

discovery if startswith(path, "/.well-known/")

user_allowed if {
	claims.iss == data.issuer
	data.group in object.get(claims, "groups", [])
}

bearer := t if {
	auth := input.attributes.request.http.headers.authorization
	startswith(auth, "Bearer ")
	t := substring(auth, 7, -1)
}

claims := payload if {
	[_, payload, _] := io.jwt.decode(bearer)
}

subject := object.get(claims, "preferred_username", "unknown")
