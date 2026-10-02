# Envoy ext_authz decision for every request that reaches orders or inventory.
#
# The JWT signature, issuer, audience and expiry are checked by Istio
# (RequestAuthentication) before this policy runs, so here the token is only
# decoded. A request with a bad token never gets this far.
package envoy.authz

import rego.v1

default result := {
	"allowed": false,
	"http_status": 403,
	"headers": {"content-type": "application/json"},
	"body": "{\"code\":\"permission_denied\",\"message\":\"no authorization rule for this procedure\"}",
}

# The subject header is set from verified claims (or the mesh identity) and
# replaces any value the client sent, so services can log it as fact.
result := {"allowed": true, "headers": {"x-auth-subject": subject}} if decision == "allow"

result := deny(401, "unauthenticated", "bearer token required") if decision == "unauthenticated"

result := deny(403, "permission_denied", sprintf("%s may not call %s", [subject, procedure])) if {
	decision == "forbidden"
}

deny(status, code, message) := {
	"allowed": false,
	"http_status": status,
	"headers": {"content-type": "application/json"},
	"body": json.marshal({"code": code, "message": message}),
}

procedure := input.attributes.request.http.path

rule := data.rules[procedure]

caller := input.attributes.source.principal

# Service-to-service rules: only the caller's mesh identity counts.
decision := "allow" if caller in rule.callers

decision := "forbidden" if {
	rule.callers
	not caller in rule.callers
}

# User rules: a token from the required group carrying one of the listed scopes.
decision := "unauthenticated" if {
	rule.any_scope
	not claims
}

decision := "allow" if {
	rule.any_scope
	user_allowed
}

decision := "forbidden" if {
	rule.any_scope
	claims
	not user_allowed
}

user_allowed if {
	data.group in object.get(claims, "groups", [])
	some scope in rule.any_scope
	scope in scopes
}

bearer := t if {
	auth := input.attributes.request.http.headers.authorization
	startswith(auth, "Bearer ")
	t := substring(auth, 7, -1)
}

claims := payload if {
	[_, payload, _] := io.jwt.decode(bearer)
}

scopes := {s | some s in split(object.get(claims, "scope", ""), " ")}

default subject := "anonymous"

subject := object.get(claims, "preferred_username", "unknown") if claims

subject := caller if {
	not claims
	caller
}
