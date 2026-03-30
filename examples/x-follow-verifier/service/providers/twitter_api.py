"""Provider: Twitter API — twitter-api45 on RapidAPI, checkfollow endpoint."""

from __future__ import annotations

import httpx

from config import settings
from .base import BaseFollowProvider


class TwitterAPIFollowProvider(BaseFollowProvider):
    name = "TwitterAPI45"

    async def check_follow(self, username: str, target: str) -> bool:
        async with httpx.AsyncClient(timeout=self._timeout) as client:
            resp = await client.get(
                f"https://{settings.twitter_api_host}/checkfollow.php",
                headers={
                    "x-rapidapi-host": settings.twitter_api_host,
                    "x-rapidapi-key": settings.rapidapi_key,
                    "Accept": "application/json",
                },
                params={
                    "user": username,
                    "follows": target,
                },
            )

        self._check_response(resp)

        data = resp.json()
        # API45 checkfollow returns: { "follows": true/false } or { "status": "Following" }
        return data.get("follows") is True or data.get("status") == "Following"
