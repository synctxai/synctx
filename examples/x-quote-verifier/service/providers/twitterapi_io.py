"""Provider: twitterapi.io"""

from __future__ import annotations

from typing import Any, Dict, Optional

import httpx

from config import settings
from models import TweetInfo
from .base import BaseProvider, normalise_username


class TwitterAPIIOProvider(BaseProvider):
    name = "TwitterAPIIO"

    async def get_tweet_details(self, tweet_id: str) -> Optional[TweetInfo]:
        async with httpx.AsyncClient(timeout=self._timeout) as client:
            resp = await client.get(
                f"{settings.twitterapi_io_base_url}/twitter/tweets",
                headers={"X-API-Key": settings.twitterapi_io_key},
                params={"tweet_ids": tweet_id},
            )

        if self._check_response(resp) is False:
            return None

        data: Dict[str, Any] = resp.json()
        tweets = data.get("tweets") or []
        if not tweets:
            return None

        tweet = tweets[0]

        author: str = tweet.get("author", {}).get("userName", "")

        qt: Optional[Dict[str, Any]] = tweet.get("quoted_tweet")
        is_quote = isinstance(qt, dict) and len(qt) > 0
        quoted_id: Optional[str] = qt.get("id") if is_quote else None

        return TweetInfo(
            author_username=normalise_username(author),
            is_quote=is_quote,
            quoted_tweet_id=quoted_id,
        )
