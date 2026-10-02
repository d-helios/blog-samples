import base64
import json
import logging
import time
from typing import Any

from authlib.integrations.starlette_client import OAuth
from nicegui import app

from .config import Settings

log = logging.getLogger("web.auth")

SCOPES = "openid profile email offline_access ReadOnly ReadWrite Submit"
REFRESH_MARGIN_SECONDS = 60


class Auth:
    def __init__(self, settings: Settings) -> None:
        self.oauth = OAuth()
        self.client = self.oauth.register(
            name="authentik",
            client_id=settings.client_id,
            client_secret=settings.client_secret,
            server_metadata_url=(
                f"{settings.oidc_url}/application/o/{settings.oidc_app_slug}/.well-known/openid-configuration"
            ),
            client_kwargs={"scope": SCOPES, "code_challenge_method": "S256"},
        )

    async def login_redirect(self, request, redirect_uri: str):
        return await self.client.authorize_redirect(request, redirect_uri)

    async def complete_login(self, request) -> str:
        token = await self.client.authorize_access_token(request)
        self._store(token)
        user = app.storage.user["username"]
        log.info("login user=%s scopes=%r", user, claims(token["access_token"]).get("scope"))
        return user

    async def logout_redirect(self, request, post_logout_redirect_uri: str):
        id_token = app.storage.user.get("id_token")
        log.info("logout user=%s", app.storage.user.get("username"))
        app.storage.user.clear()
        return await self.client.logout_redirect(
            request,
            post_logout_redirect_uri=post_logout_redirect_uri,
            id_token_hint=id_token,
        )

    async def access_token(self) -> str | None:
        """Return a valid access token for the current session, refreshing it if needed."""
        store = app.storage.user
        if "access_token" not in store:
            return None
        if store["expires_at"] - time.time() > REFRESH_MARGIN_SECONDS:
            return store["access_token"]

        try:
            token = await self.client.fetch_access_token(
                grant_type="refresh_token",
                refresh_token=store["refresh_token"],
            )
        except Exception as exc:
            log.warning("token refresh failed user=%s error=%s", store.get("username"), exc)
            store.clear()
            return None

        self._store(token)
        log.info("token refreshed user=%s", store["username"])
        return store["access_token"]

    @staticmethod
    def _store(token: dict[str, Any]) -> None:
        store = app.storage.user
        access = token["access_token"]
        store["access_token"] = access
        store["refresh_token"] = token.get("refresh_token", store.get("refresh_token"))
        store["id_token"] = token.get("id_token", store.get("id_token"))
        store["expires_at"] = token.get("expires_at") or time.time() + token.get("expires_in", 0)
        store["username"] = claims(access).get("preferred_username", "?")


def claims(jwt: str) -> dict[str, Any]:
    """Decode a JWT payload without verifying it. For display only."""
    try:
        payload = jwt.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload))
    except (IndexError, ValueError):
        return {}
