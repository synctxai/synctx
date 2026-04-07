"""Provider: Twitter API — twitter-api45 on RapidAPI, checkfollow endpoint."""

from __future__ import annotations

import httpx

from config import settings
from .base import BaseFollowProvider, normalise_username


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

    async def resolve_username(self, user_id: str) -> str | None:
        async with httpx.AsyncClient(timeout=self._timeout) as client:
            resp = await client.get(
                f"https://{settings.twitter_api_host}/screennames.php",
                headers={
                    "x-rapidapi-host": settings.twitter_api_host,
                    "x-rapidapi-key": settings.rapidapi_key,
                    "Accept": "application/json",
                },
                params={"rest_ids": user_id},
            )

        self._check_response(resp)

        data = resp.json()
        if isinstance(data, list) and data:
            profile = data[0]
        elif isinstance(data, dict):
            profiles = data.get("users") or data.get("profiles") or data.get("data")
            if isinstance(profiles, list) and profiles:
                profile = profiles[0]
            else:
                profile = data
        else:
            profile = {}

        username = profile.get("screen_name") or profile.get("screenName") or profile.get("userName")
        return normalise_username(username)
