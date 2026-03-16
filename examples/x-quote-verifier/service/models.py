"""Data models for the tweet verification service."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional


@dataclass
class TweetInfo:
    """Tweet information returned by upstream API (after normalization)."""

    author_username: str        # lowercase, without '@'
    is_quote: bool
    quoted_tweet_id: Optional[str]  # ID of the quoted original tweet


@dataclass
class VerifyResult:
    """Unified return type for verification results.

    Four cases:
        1. Quoted     -> verified=True,  error=None
        2. Not quoted -> verified=False, error=None
        3. Process error (unknown) -> verified=None, error="...", error_known=False
        4. Process error (known)   -> verified=None, error="...", error_known=True
    """

    verified: Optional[bool] = None
    error: Optional[str] = None
    error_known: bool = False

    @staticmethod
    def success(verified: bool) -> VerifyResult:
        return VerifyResult(verified=verified)

    @staticmethod
    def unknown_error(msg: str) -> VerifyResult:
        """Vendor/network temporary issues."""
        return VerifyResult(error=msg, error_known=False)

    @staticmethod
    def known_error(msg: str) -> VerifyResult:
        """Internal issues (authentication failure, quota exhausted, etc.)."""
        return VerifyResult(error=msg, error_known=True)
