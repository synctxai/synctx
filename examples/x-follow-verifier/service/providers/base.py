"""Abstract base class for follow-check providers."""

from __future__ import annotations

import abc
from typing import Optional

import httpx

from models import FollowResult


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


class BaseFollowProvider(abc.ABC):
    """All follow-check providers must implement this interface."""

    name: str = "BaseFollowProvider"

    def __init__(self, timeout: int = 15) -> None:
        self._timeout = timeout

    @abc.abstractmethod
    async def check_follow(self, username: str, target: str) -> bool:
        """Check if @username follows @target.

        Returns:
            True  — confirmed following
            False — confirmed not following

        Raises:
            KnownError — internal issue (auth/quota, etc.), do not retry
            Other exceptions — temporary issue (network/timeout/rate-limit, etc.), can retry
        """
        ...

    @abc.abstractmethod
    async def resolve_username(self, user_id: str) -> Optional[str]:
        """Resolve a user_id to the current username."""
        ...

    def _check_response(self, resp: httpx.Response) -> None:
        """Check HTTP response status code and raise categorized errors."""
        if resp.status_code in (401, 402, 403):
            raise KnownError(f"[{self.name}] HTTP {resp.status_code}: authentication or quota issue")
        resp.raise_for_status()
