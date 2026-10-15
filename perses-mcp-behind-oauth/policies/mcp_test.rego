package envoy.authz_test

import data.envoy.authz
import rego.v1

# Unsigned test tokens: signature checking is Istio's job, not this policy's.
token(claims) := sprintf("Bearer %s", [io.jwt.encode_sign({"alg": "HS256"}, claims, {"kty": "oct", "k": "c2VjcmV0"})])

request(path, headers) := {"attributes": {"request": {"http": {"path": path, "headers": headers}}}}

test_group_member_allowed if {
	r := authz.result with input as request("/mcp", {"authorization": token({"iss": "https://auth.localhost/application/o/perses-mcp/", "groups": ["Observability MCP"], "preferred_username": "alice"})})
	r.allowed
	r.headers["x-auth-subject"] == "alice"
}

test_other_group_forbidden if {
	r := authz.result with input as request("/mcp", {"authorization": token({"iss": "https://auth.localhost/application/o/perses-mcp/", "groups": ["Other"], "preferred_username": "bob"})})
	not r.allowed
	r.http_status == 403
}

test_no_groups_claim_forbidden if {
	r := authz.result with input as request("/mcp", {"authorization": token({"preferred_username": "bob"})})
	r.http_status == 403
}

test_no_token_gets_challenge if {
	r := authz.result with input as request("/mcp", {})
	r.http_status == 401
	contains(r.headers["www-authenticate"], "resource_metadata=\"https://mcp.localhost/.well-known/oauth-protected-resource\"")
}

test_discovery_open if {
	r := authz.result with input as request("/.well-known/oauth-protected-resource", {})
	r.allowed
}

# A Perses login token also passes the gateway's JWT check.
test_other_issuer_forbidden if {
	r := authz.result with input as request("/mcp", {"authorization": token({"iss": "https://auth.localhost/application/o/perses/", "groups": ["Observability MCP"]})})
	r.http_status == 403
}
