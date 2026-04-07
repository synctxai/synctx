"""Abstract base class for upstream providers."""

from __future__ import annotations

import abc
from typing import Optional

import httpx

from models import TweetInfo


class KnownError(Exception):
    """Known error (authentication failure, quota exhausted, etc.), should not be retried."""


def normalise_username(username) -> str:
    """Unified username normalization: strip leading '@', convert to lowercase."""
    if not username or not isinstance(username, str):
        return ""
    return username.lstrip("@").lower()


def normalise_user_id(user_id) -> str:
    """Normalize X/Twitter user_id to a canonical decimal string."""
    if isinstance(user_id, int):
        return str(user_id) if user_id > 0 else ""
    if isinstance(user_id, str):
        value = user_id.strip()
        return value if value.isdigit() and value != "0" else ""
    return ""


class BaseProvider(abc.ABC):
    """All upstream API providers must implement this interface."""

    name: str = "BaseProvider"

    def __init__(self, timeout: int = 10) -> None:
        self._timeout = timeout

    @abc.abstractmethod
    async def get_tweet_details(self, tweet_id: str) -> Optional[TweetInfo]:
        """Get tweet details.

        Returns:
            TweetInfo — successfully retrieved tweet information
            None      — tweet does not exist (404)

        Raises:
            KnownError — internal issue (auth/quota, etc.), do not retry
            Other exceptions — temporary issue (network/timeout/rate-limit, etc.), can retry
        """
        ...

    def _check_response(self, resp: httpx.Response) -> Optional[bool]:
        """Check HTTP response status code and categorize handling."""
        if resp.status_code == 404:
            return False
        if resp.status_code in (401, 402, 403):
            raise KnownError(f"[{self.name}] HTTP {resp.status_code}: authentication or quota issue")
        resp.raise_for_status()
        return None
