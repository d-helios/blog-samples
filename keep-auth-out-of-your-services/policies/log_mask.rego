# Keep bearer tokens out of OPA decision logs.
package system.log

import rego.v1

mask contains "/input/attributes/request/http/headers/authorization"
