"""Data models for the follow verification service."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional


@dataclass
class FollowResult:
    """Unified return type for follow verification results.

    Four cases:
        1. Following     -> following=True,  error=None
        2. Not following -> following=False, error=None
        3. Process error (unknown) -> following=None, error="...", error_known=False
        4. Process error (known)   -> following=None, error="...", error_known=True
    """

    following: Optional[bool] = None
    error: Optional[str] = None
    error_known: bool = False

    @staticmethod
    def success(following: bool) -> FollowResult:
        return FollowResult(following=following)

    @staticmethod
    def unknown_error(msg: str) -> FollowResult:
        """Vendor/network temporary issues."""
        return FollowResult(error=msg, error_known=False)

    @staticmethod
    def known_error(msg: str) -> FollowResult:
        """Internal issues (authentication failure, quota exhausted, etc.)."""
        return FollowResult(error=msg, error_known=True)
