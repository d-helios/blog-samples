import json
import logging
import time
import uuid
from typing import Any

import httpx
from pydantic import BaseModel, ValidationError

log = logging.getLogger("web.orders")


class Order(BaseModel):
    id: str = ""
    sku: str = ""
    quantity: int = 0
    state: str = "ORDER_STATE_UNSPECIFIED"


class OrderResponse(BaseModel):
    order: Order


class GetOrderRequest(BaseModel):
    id: str


class CreateOrderRequest(BaseModel):
    sku: str
    quantity: int


class SubmitOrderRequest(BaseModel):
    id: str


class CallResult(BaseModel):
    method: str
    status: int
    code: str
    body: Any
    request_id: str
    order: Order | None = None


# Codes a Connect client infers when the error body is not Connect JSON,
# for example a plain-text 401 from the sidecar for an expired token.
_HTTP_TO_CODE = {
    400: "internal",
    401: "unauthenticated",
    403: "permission_denied",
    404: "unimplemented",
    429: "unavailable",
    502: "unavailable",
    503: "unavailable",
    504: "unavailable",
}


class OrdersClient:
    """Connect protocol over plain JSON. No generated code on the Python side."""

    service = "orders.v1.OrdersService"

    def __init__(self, base_url: str) -> None:
        self._http = httpx.AsyncClient(base_url=base_url, timeout=10)

    async def get_order(self, token: str | None, order_id: str) -> CallResult:
        return await self._call("GetOrder", token, GetOrderRequest(id=order_id))

    async def create_order(self, token: str | None, sku: str, quantity: int) -> CallResult:
        return await self._call("CreateOrder", token, CreateOrderRequest(sku=sku, quantity=quantity))

    async def submit_order(self, token: str | None, order_id: str) -> CallResult:
        return await self._call("SubmitOrder", token, SubmitOrderRequest(id=order_id))

    async def _call(self, method: str, token: str | None, msg: BaseModel) -> CallResult:
        request_id = str(uuid.uuid4())
        headers = {"Content-Type": "application/json", "X-Request-Id": request_id}
        if token:
            headers["Authorization"] = f"Bearer {token}"

        start = time.monotonic()
        try:
            resp = await self._http.post(f"/{self.service}/{method}", content=msg.model_dump_json(), headers=headers)
        except httpx.HTTPError as exc:
            log.error("call failed method=%s request_id=%s error=%s", method, request_id, exc)
            return CallResult(method=method, status=0, code="unavailable", body=str(exc), request_id=request_id)

        body = _parse_body(resp)
        order = None
        if resp.status_code == 200:
            code = "ok"
            try:
                order = OrderResponse.model_validate(body).order
            except ValidationError:
                log.warning("unexpected response shape method=%s request_id=%s", method, request_id)
        elif isinstance(body, dict) and "code" in body:
            code = body["code"]
        else:
            code = _HTTP_TO_CODE.get(resp.status_code, "unknown")

        log.info(
            "orders call method=%s status=%d code=%s request_id=%s duration_ms=%d",
            method, resp.status_code, code, request_id, (time.monotonic() - start) * 1000,
        )
        return CallResult(
            method=method, status=resp.status_code, code=code, body=body, request_id=request_id, order=order
        )


def _parse_body(resp: httpx.Response) -> Any:
    try:
        return resp.json()
    except json.JSONDecodeError:
        return resp.text
