"""Provider: twitterapi.io — check_follow_relationship endpoint."""

from __future__ import annotations

import httpx

from config import settings
from .base import BaseFollowProvider, normalise_username


class TwitterAPIIOFollowProvider(BaseFollowProvider):
    name = "TwitterAPIIO"

    async def check_follow(self, username: str, target: str) -> bool:
        async with httpx.AsyncClient(timeout=self._timeout) as client:
            resp = await client.get(
                f"{settings.twitterapi_io_base_url}/twitter/user/check_follow_relationship",
                headers={
                    "X-API-Key": settings.twitterapi_io_key,
                    "Accept": "application/json",
                },
                params={
                    "source_user_name": username,
                    "target_user_name": target,
                },
            )

        self._check_response(resp)

        data = resp.json()
        return data.get("data", {}).get("following") is True

    async def resolve_username(self, user_id: str) -> str | None:
        async with httpx.AsyncClient(timeout=self._timeout) as client:
            resp = await client.get(
                f"{settings.twitterapi_io_base_url}/twitter/user/info",
                headers={
                    "X-API-Key": settings.twitterapi_io_key,
                    "Accept": "application/json",
                },
                params={"userId": user_id},
            )

        self._check_response(resp)

        data = resp.json().get("data", {})
        username = data.get("userName") or data.get("username")
        return normalise_username(username)
