package envoy.authz_test

import rego.v1

import data.envoy.authz

orders_sa := "spiffe://cluster.local/ns/demo/sa/orders"

testclient_sa := "spiffe://cluster.local/ns/demo/sa/testclient"

users := {
	"alice": {"groups": ["MyServiceRole"], "scope": "openid profile ReadOnly"},
	"bob": {"groups": ["MyServiceRole"], "scope": "openid profile ReadWrite"},
	"dave": {"groups": ["MyServiceRole"], "scope": "openid profile ReadOnly Submit"},
	"carol": {"groups": [], "scope": "openid profile ReadOnly ReadWrite Submit"},
}

# The policy only decodes tokens (Istio verifies them), so any signing key works here.
token(claims) := io.jwt.encode_sign(
	{"alg": "HS256", "typ": "JWT"},
	object.union(claims, {"preferred_username": "test"}),
	{"kty": "oct", "k": "dGVzdA"},
)

request(path, caller, headers) := {"attributes": {
	"source": {"principal": caller},
	"request": {"http": {"path": path, "headers": headers}},
}}

as_user(path, user) := request(path, testclient_sa, {"authorization": concat(" ", ["Bearer", token(users[user])])})

status(req) := code if {
	res := authz.result with input as req
	code := object.get(res, "http_status", 200)
}

# rpc -> [alice, bob, dave, carol, no token]
user_matrix := {
	"/orders.v1.OrdersService/GetOrder": [200, 200, 200, 403, 401],
	"/orders.v1.OrdersService/CreateOrder": [403, 200, 403, 403, 401],
	"/orders.v1.OrdersService/SubmitOrder": [403, 403, 200, 403, 401],
	"/inventory.v1.InventoryService/GetStock": [200, 200, 200, 403, 401],
	"/inventory.v1.InventoryService/Reserve": [403, 200, 403, 403, 401],
	"/inventory.v1.InventoryService/Commit": [403, 403, 200, 403, 401],
	"/inventory.v1.InventoryService/Recalculate": [403, 403, 403, 403, 403],
}

callers := ["alice", "bob", "dave", "carol"]

mismatches contains sprintf("%s as %s: got %d, want %d", [path, user, got, want]) if {
	some path, row in user_matrix
	some i, user in callers
	want := row[i]
	got := status(as_user(path, user))
	got != want
}

mismatches contains sprintf("%s without token: got %d, want %d", [path, got, want]) if {
	some path, row in user_matrix
	want := row[4]
	got := status(request(path, testclient_sa, {}))
	got != want
}

test_user_matrix if {
	count(mismatches) == 0
}

test_recalculate_allowed_for_orders_without_token if {
	status(request("/inventory.v1.InventoryService/Recalculate", orders_sa, {})) == 200
}

test_orders_identity_does_not_replace_user_token if {
	status(request("/inventory.v1.InventoryService/Commit", orders_sa, {})) == 401
	req := request(
		"/inventory.v1.InventoryService/Commit", orders_sa,
		{"authorization": concat(" ", ["Bearer", token(users.bob)])},
	)
	status(req) == 403
}

test_unknown_procedure_denied if {
	status(as_user("/orders.v1.OrdersService/DeleteOrder", "bob")) == 403
}

test_non_bearer_authorization_is_unauthenticated if {
	status(request("/orders.v1.OrdersService/GetOrder", testclient_sa, {"authorization": "Basic Ym9iOmJvYg=="})) == 401
}

test_submit_does_not_imply_read if {
	submit_only := {"groups": ["MyServiceRole"], "scope": "Submit"}
	req := request(
		"/orders.v1.OrdersService/GetOrder", testclient_sa,
		{"authorization": concat(" ", ["Bearer", token(submit_only)])},
	)
	status(req) == 403
}

test_allowed_request_carries_verified_subject if {
	res := authz.result with input as as_user("/orders.v1.OrdersService/SubmitOrder", "dave")
	res.headers["x-auth-subject"] == "test"
}

test_service_call_subject_is_mesh_identity if {
	res := authz.result with input as request("/inventory.v1.InventoryService/Recalculate", orders_sa, {"x-auth-subject": "dave"})
	res.headers["x-auth-subject"] == orders_sa
}

test_deny_body_is_connect_error if {
	res := authz.result with input as as_user("/orders.v1.OrdersService/CreateOrder", "alice")
	json.unmarshal(res.body).code == "permission_denied"
}
