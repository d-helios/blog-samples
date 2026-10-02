# Users calling orders and inventory through the mesh from the testclient pod.
# Expected results are the matrices in the README.

POST {{idp}}/application/o/token/
[Form]
grant_type: client_credentials
client_id: demo-cli
username: alice
password: {{alice_app_password}}
scope: openid profile ReadOnly ReadWrite Submit
HTTP 200
[Captures]
alice: jsonpath "$.access_token" redact

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

# carol is not in MyServiceRole, so Authentik refuses to issue her a token.
POST {{idp}}/application/o/token/
[Form]
grant_type: client_credentials
client_id: demo-cli
username: carol
password: {{carol_app_password}}
scope: openid profile ReadOnly ReadWrite Submit
HTTP 400
[Asserts]
jsonpath "$.error" == "invalid_grant"
jsonpath "$.access_token" not exists

# bob creates the order that the matrix rows use.
POST http://orders/orders.v1.OrdersService/CreateOrder
Authorization: Bearer {{bob}}
Content-Type: application/json
{"sku": "widget", "quantity": 2}
HTTP 200
[Captures]
order_id: jsonpath "$.order.id"
[Asserts]
jsonpath "$.order.state" == "ORDER_STATE_DRAFT"

# orders.GetOrder

POST http://orders/orders.v1.OrdersService/GetOrder
Authorization: Bearer {{alice}}
Content-Type: application/json
{"id": "{{order_id}}"}
HTTP 200

POST http://orders/orders.v1.OrdersService/GetOrder
Authorization: Bearer {{bob}}
Content-Type: application/json
{"id": "{{order_id}}"}
HTTP 200

POST http://orders/orders.v1.OrdersService/GetOrder
Authorization: Bearer {{dave}}
Content-Type: application/json
{"id": "{{order_id}}"}
HTTP 200

POST http://orders/orders.v1.OrdersService/GetOrder
Content-Type: application/json
{"id": "{{order_id}}"}
HTTP 401
[Asserts]
jsonpath "$.code" == "unauthenticated"

# orders.CreateOrder

POST http://orders/orders.v1.OrdersService/CreateOrder
Authorization: Bearer {{alice}}
Content-Type: application/json
{"sku": "widget", "quantity": 1}
HTTP 403
[Asserts]
jsonpath "$.code" == "permission_denied"

POST http://orders/orders.v1.OrdersService/CreateOrder
Authorization: Bearer {{dave}}
Content-Type: application/json
{"sku": "widget", "quantity": 1}
HTTP 403
[Asserts]
jsonpath "$.code" == "permission_denied"

POST http://orders/orders.v1.OrdersService/CreateOrder
Content-Type: application/json
{"sku": "widget", "quantity": 1}
HTTP 401
[Asserts]
jsonpath "$.code" == "unauthenticated"

# orders.SubmitOrder, nonexistent id. Authorization runs first, so only dave sees 404.

POST http://orders/orders.v1.OrdersService/SubmitOrder
Authorization: Bearer {{alice}}
Content-Type: application/json
{"id": "does-not-exist"}
HTTP 403
[Asserts]
jsonpath "$.code" == "permission_denied"

POST http://orders/orders.v1.OrdersService/SubmitOrder
Authorization: Bearer {{bob}}
Content-Type: application/json
{"id": "does-not-exist"}
HTTP 403
[Asserts]
jsonpath "$.code" == "permission_denied"

POST http://orders/orders.v1.OrdersService/SubmitOrder
Authorization: Bearer {{dave}}
Content-Type: application/json
{"id": "does-not-exist"}
HTTP 404
[Asserts]
jsonpath "$.code" == "not_found"

POST http://orders/orders.v1.OrdersService/SubmitOrder
Content-Type: application/json
{"id": "does-not-exist"}
HTTP 401
[Asserts]
jsonpath "$.code" == "unauthenticated"

# orders.SubmitOrder, existing DRAFT. dave goes last because he changes the state.

POST http://orders/orders.v1.OrdersService/SubmitOrder
Authorization: Bearer {{alice}}
Content-Type: application/json
{"id": "{{order_id}}"}
HTTP 403
[Asserts]
jsonpath "$.code" == "permission_denied"

POST http://orders/orders.v1.OrdersService/SubmitOrder
Authorization: Bearer {{bob}}
Content-Type: application/json
{"id": "{{order_id}}"}
HTTP 403
[Asserts]
jsonpath "$.code" == "permission_denied"

POST http://orders/orders.v1.OrdersService/SubmitOrder
Content-Type: application/json
{"id": "{{order_id}}"}
HTTP 401
[Asserts]
jsonpath "$.code" == "unauthenticated"

POST http://orders/orders.v1.OrdersService/SubmitOrder
Authorization: Bearer {{dave}}
Content-Type: application/json
{"id": "{{order_id}}"}
HTTP 200
[Asserts]
jsonpath "$.order.state" == "ORDER_STATE_SUBMITTED"

# Workflow: bob creates, dave submits, bob sees SUBMITTED, a second submit fails.
POST http://orders/orders.v1.OrdersService/CreateOrder
Authorization: Bearer {{bob}}
Content-Type: application/json
{"sku": "gadget", "quantity": 1}
HTTP 200
[Captures]
flow_id: jsonpath "$.order.id"
[Asserts]
jsonpath "$.order.state" == "ORDER_STATE_DRAFT"

POST http://orders/orders.v1.OrdersService/SubmitOrder
Authorization: Bearer {{dave}}
Content-Type: application/json
{"id": "{{flow_id}}"}
HTTP 200
[Asserts]
jsonpath "$.order.state" == "ORDER_STATE_SUBMITTED"

POST http://orders/orders.v1.OrdersService/GetOrder
Authorization: Bearer {{bob}}
Content-Type: application/json
{"id": "{{flow_id}}"}
HTTP 200
[Asserts]
jsonpath "$.order.state" == "ORDER_STATE_SUBMITTED"

POST http://orders/orders.v1.OrdersService/SubmitOrder
Authorization: Bearer {{dave}}
Content-Type: application/json
{"id": "{{flow_id}}"}
HTTP 400
[Asserts]
jsonpath "$.code" == "failed_precondition"

# Direct calls to inventory.
# inventory.GetStock

POST http://inventory/inventory.v1.InventoryService/GetStock
Authorization: Bearer {{alice}}
Content-Type: application/json
{"sku": "widget"}
HTTP 200

POST http://inventory/inventory.v1.InventoryService/GetStock
Authorization: Bearer {{bob}}
Content-Type: application/json
{"sku": "widget"}
HTTP 200

POST http://inventory/inventory.v1.InventoryService/GetStock
Authorization: Bearer {{dave}}
Content-Type: application/json
{"sku": "widget"}
HTTP 200

POST http://inventory/inventory.v1.InventoryService/GetStock
Content-Type: application/json
{"sku": "widget"}
HTTP 401
[Asserts]
jsonpath "$.code" == "unauthenticated"

# inventory.Reserve

POST http://inventory/inventory.v1.InventoryService/Reserve
Authorization: Bearer {{alice}}
Content-Type: application/json
{"orderId": "direct-{{reservation}}", "sku": "widget", "quantity": 1}
HTTP 403
[Asserts]
jsonpath "$.code" == "permission_denied"

POST http://inventory/inventory.v1.InventoryService/Reserve
Authorization: Bearer {{dave}}
Content-Type: application/json
{"orderId": "direct-{{reservation}}", "sku": "widget", "quantity": 1}
HTTP 403
[Asserts]
jsonpath "$.code" == "permission_denied"

POST http://inventory/inventory.v1.InventoryService/Reserve
Content-Type: application/json
{"orderId": "direct-{{reservation}}", "sku": "widget", "quantity": 1}
HTTP 401
[Asserts]
jsonpath "$.code" == "unauthenticated"

POST http://inventory/inventory.v1.InventoryService/Reserve
Authorization: Bearer {{bob}}
Content-Type: application/json
{"orderId": "direct-{{reservation}}", "sku": "widget", "quantity": 1}
HTTP 200

# inventory.Commit

POST http://inventory/inventory.v1.InventoryService/Commit
Authorization: Bearer {{alice}}
Content-Type: application/json
{"orderId": "direct-{{reservation}}"}
HTTP 403
[Asserts]
jsonpath "$.code" == "permission_denied"

POST http://inventory/inventory.v1.InventoryService/Commit
Authorization: Bearer {{bob}}
Content-Type: application/json
{"orderId": "direct-{{reservation}}"}
HTTP 403
[Asserts]
jsonpath "$.code" == "permission_denied"

POST http://inventory/inventory.v1.InventoryService/Commit
Content-Type: application/json
{"orderId": "direct-{{reservation}}"}
HTTP 401
[Asserts]
jsonpath "$.code" == "unauthenticated"

POST http://inventory/inventory.v1.InventoryService/Commit
Authorization: Bearer {{dave}}
Content-Type: application/json
{"orderId": "direct-{{reservation}}"}
HTTP 200

# inventory.Recalculate is for the orders service only. A user token does not help.

POST http://inventory/inventory.v1.InventoryService/Recalculate
Authorization: Bearer {{alice}}
Content-Type: application/json
{}
HTTP 403
[Asserts]
jsonpath "$.code" == "permission_denied"

POST http://inventory/inventory.v1.InventoryService/Recalculate
Authorization: Bearer {{bob}}
Content-Type: application/json
{}
HTTP 403
[Asserts]
jsonpath "$.code" == "permission_denied"

POST http://inventory/inventory.v1.InventoryService/Recalculate
Authorization: Bearer {{dave}}
Content-Type: application/json
{}
HTTP 403
[Asserts]
jsonpath "$.code" == "permission_denied"

POST http://inventory/inventory.v1.InventoryService/Recalculate
Content-Type: application/json
{}
HTTP 403
[Asserts]
jsonpath "$.code" == "permission_denied"

# A token that fails validation is rejected by the sidecar before OPA.
POST http://orders/orders.v1.OrdersService/GetOrder
Authorization: Bearer not-a-jwt
Content-Type: application/json
{"id": "{{order_id}}"}
HTTP 401
