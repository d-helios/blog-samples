# Runs with the orders service account, i.e. with orders' mesh identity.
# The identity is enough for Recalculate, but user-level RPCs still need a
# token that allows them.

POST {{idp}}/application/o/token/
[Form]
grant_type: client_credentials
client_id: demo-cli
username: bob
password: {{bob_app_password}}
scope: openid profile ReadOnly ReadWrite Submit
HTTP 200
[Captures]
bob: jsonpath "$.access_token" redact

POST {{idp}}/application/o/token/
[Form]
grant_type: client_credentials
client_id: demo-cli
username: dave
password: {{dave_app_password}}
scope: openid profile ReadOnly ReadWrite Submit
HTTP 200
[Captures]
dave: jsonpath "$.access_token" redact

POST http://inventory/inventory.v1.InventoryService/Recalculate
Content-Type: application/json
{}
HTTP 200
[Asserts]
jsonpath "$.stock" count >= 1

POST http://inventory/inventory.v1.InventoryService/Reserve
Authorization: Bearer {{bob}}
Content-Type: application/json
{"orderId": "mesh-{{reservation}}", "sku": "widget", "quantity": 1}
HTTP 200

# Without a token, orders' identity alone does not allow Commit.
POST http://inventory/inventory.v1.InventoryService/Commit
Content-Type: application/json
{"orderId": "mesh-{{reservation}}"}
HTTP 401
[Asserts]
jsonpath "$.code" == "unauthenticated"

# bob's token forwarded from a legitimate orders pod is still checked.
POST http://inventory/inventory.v1.InventoryService/Commit
Authorization: Bearer {{bob}}
Content-Type: application/json
{"orderId": "mesh-{{reservation}}"}
HTTP 403
[Asserts]
jsonpath "$.code" == "permission_denied"

POST http://inventory/inventory.v1.InventoryService/Commit
Authorization: Bearer {{dave}}
Content-Type: application/json
{"orderId": "mesh-{{reservation}}"}
HTTP 200
