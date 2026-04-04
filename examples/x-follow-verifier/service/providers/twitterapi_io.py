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
                f"{settings.twitterapi_io_base_url}/twitter/user/batch_info_by_ids",
                headers={
                    "X-API-Key": settings.twitterapi_io_key,
                    "Accept": "application/json",
                },
                params={"userIds": user_id},
            )

        self._check_response(resp)

        users = resp.json().get("users", [])
        if not users:
            return None
        username = users[0].get("userName") or users[0].get("username")
        return normalise_username(username)
