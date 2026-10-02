import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    app_url: str
    orders_url: str
    oidc_url: str
    oidc_app_slug: str
    client_id: str
    client_secret: str
    storage_secret: str


def load() -> Settings:
    return Settings(
        app_url=os.environ.get("APP_URL", "http://web.localtest.me").rstrip("/"),
        orders_url=os.environ.get("ORDERS_URL", "http://orders").rstrip("/"),
        oidc_url=os.environ.get("OIDC_URL", "http://auth.localtest.me").rstrip("/"),
        oidc_app_slug=os.environ.get("OIDC_APP_SLUG", "demo-web"),
        client_id=os.environ["OIDC_CLIENT_ID"],
        client_secret=os.environ["OIDC_CLIENT_SECRET"],
        storage_secret=os.environ["STORAGE_SECRET"],
    )
