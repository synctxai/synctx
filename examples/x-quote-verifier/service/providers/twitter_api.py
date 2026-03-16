"""Provider: Twitter API — twitter-api45 on RapidAPI."""

from __future__ import annotations

from typing import Any, Dict, Optional

import httpx

from config import settings
from models import TweetInfo
from .base import BaseProvider, normalise_username


class TwitterAPIProvider(BaseProvider):
    name = "TwitterAPI45"

    async def get_tweet_details(self, tweet_id: str) -> Optional[TweetInfo]:
        async with httpx.AsyncClient(timeout=self._timeout) as client:
            resp = await client.get(
                f"https://{settings.twitter_api_host}/tweet.php",
                headers={
                    "x-rapidapi-host": settings.twitter_api_host,
                    "x-rapidapi-key": settings.rapidapi_key,
                },
                params={"id": tweet_id},
            )

        if self._check_response(resp) is False:
            return None

        data: Dict[str, Any] = resp.json()
        if not data or data.get("error"):
            return None

        author = data.get("author", {}).get("screen_name", "")

        quoted: Optional[Dict[str, Any]] = data.get("quoted")
        is_quote = isinstance(quoted, dict) and len(quoted) > 0
        quoted_id: Optional[str] = quoted.get("tweet_id") if is_quote else None

        return TweetInfo(
            author_username=normalise_username(author),
            is_quote=is_quote,
            quoted_tweet_id=quoted_id,
        )
