import json
import logging
import os

from fastapi import Request
from fastapi.responses import RedirectResponse
from nicegui import app, ui

from . import config
from .auth import Auth, claims
from .orders import CallResult, OrdersClient

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logging.getLogger("httpx").setLevel(logging.WARNING)
log = logging.getLogger("web")

settings = config.load()
auth = Auth(settings)
orders = OrdersClient(settings.orders_url)


@app.get("/login")
async def login(request: Request):
    return await auth.login_redirect(request, f"{settings.app_url}/auth/callback")


@app.get("/auth/callback")
async def callback(request: Request):
    try:
        await auth.complete_login(request)
    except Exception:
        log.exception("login failed")
        return RedirectResponse("/?error=login_failed")
    return RedirectResponse("/")


@app.get("/logout")
async def logout(request: Request):
    return await auth.logout_redirect(request, f"{settings.app_url}/")


@ui.page("/")
async def index(error: str | None = None) -> None:
    token = await auth.access_token()

    with ui.header().classes("items-center justify-between"):
        ui.label("Orders demo").classes("text-lg font-medium")
        if token:
            with ui.row().classes("items-center"):
                ui.label(f"Signed in as {app.storage.user['username']}")
                ui.button("Log out", on_click=lambda: ui.navigate.to("/logout")).props("flat color=white")

    if not token:
        with ui.column().classes("absolute-center items-center"):
            if error:
                ui.label("Login failed, see the web service log.").classes("text-negative")
            ui.button("Log in with Authentik", on_click=lambda: ui.navigate.to("/login"))
        return

    token_card(token)
    actions()


def token_card(token: str) -> None:
    c = claims(token)
    with ui.card().classes("w-full"):
        ui.label("Access token (decoded for display, never used for decisions)").classes("text-sm text-grey-7")
        with ui.grid(columns="auto 1fr").classes("gap-x-6 gap-y-1"):
            ui.label("user")
            ui.label(c.get("preferred_username", "?")).classes("font-mono")
            ui.label("groups")
            ui.label(", ".join(c.get("groups", [])) or "(none)").classes("font-mono")
            ui.label("scope")
            ui.label(c.get("scope", "")).classes("font-mono")


def actions() -> None:
    with ui.row().classes("w-full items-start no-wrap gap-4"):
        with ui.card().classes("w-96"):
            ui.label("Order").classes("font-medium")
            order_id = ui.input("Order ID").classes("w-full")
            with ui.row():
                ui.button("Get order", on_click=lambda: run(orders.get_order, order_id.value.strip()))
                ui.button("Submit order", on_click=lambda: run(orders.submit_order, order_id.value.strip()))

            ui.separator()
            ui.label("New order").classes("font-medium")
            sku = ui.select(["widget", "gadget"], value="widget", label="SKU").classes("w-full")
            quantity = ui.number("Quantity", value=1, min=1, precision=0).classes("w-full")
            ui.button("Create order", on_click=lambda: run(orders.create_order, sku.value, int(quantity.value or 0)))

        with ui.card().classes("grow"):
            ui.label("Result").classes("font-medium")
            result = ui.column().classes("w-full")
            with result:
                ui.label("No calls yet.").classes("text-grey-7")

    async def run(call, *args) -> None:
        token = await auth.access_token()
        if token is None:
            ui.navigate.to("/")
            return
        res = await call(token, *args)
        if res.order and res.order.id:
            order_id.value = res.order.id
        render(result, res)


def render(container: ui.column, res: CallResult) -> None:
    color = "positive" if res.status == 200 else "negative"
    container.clear()
    with container:
        with ui.row().classes("items-center"):
            ui.badge(str(res.status), color=color).classes("text-base")
            ui.label(res.code).classes("font-mono")
            ui.label(res.method).classes("text-grey-7")
        body = res.body if isinstance(res.body, str) else json.dumps(res.body, indent=2)
        ui.code(body, language="json").classes("w-full")
        ui.label(f"request id {res.request_id}").classes("text-xs text-grey-7")


ui.run(
    host="0.0.0.0",
    port=int(os.environ.get("PORT", "8080")),
    title="Orders demo",
    storage_secret=settings.storage_secret,
    session_middleware_kwargs={"same_site": "lax", "https_only": False},
    reload=False,
    show=False,
    show_welcome_message=False,
)
