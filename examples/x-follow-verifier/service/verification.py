"""Core follow verification logic.

Dual-provider parallel check, matching the merge logic in client.ts:
    - ANY provider detects follow → following=True
    - AT LEAST ONE succeeds AND both say not following → following=False
    - BOTH fail → return error (inconclusive)

Error handling strategy:
    - Known errors (KnownError: auth/quota) -> return error immediately, no retry
    - Temporary errors (network/timeout/rate-limit/5xx) -> retry within same provider, then fall through to next
"""

from __future__ import annotations

import asyncio
import logging
from typing import Optional

from config import settings
from models import FollowResult
from providers.base import BaseFollowProvider, KnownError, normalise_username
from providers.twitter_api import TwitterAPIFollowProvider
from providers.twitterapi_io import TwitterAPIIOFollowProvider

logger = logging.getLogger(__name__)

MAX_RETRIES = 2
RETRY_DELAY = 0.5


def _build_providers() -> list[BaseFollowProvider]:
    timeout = settings.request_timeout
    return [
        TwitterAPIIOFollowProvider(timeout=timeout),
        TwitterAPIFollowProvider(timeout=timeout),
    ]


_providers = _build_providers()


async def _call_with_retry(
    provider: BaseFollowProvider, username: str, target: str
) -> bool:
    for attempt in range(MAX_RETRIES + 1):
        try:
            return await provider.check_follow(username, target)
        except KnownError:
            raise
        except Exception:
            if attempt == MAX_RETRIES:
                raise
            await asyncio.sleep(RETRY_DELAY * (attempt + 1))


async def is_following(username: str, target: str) -> FollowResult:
    """Check if @username follows @target using dual providers in parallel.

    Merge logic (mirrors client.ts):
        - ANY provider confirms follow → True
        - At least one succeeds and both say not following → False
        - Both fail → error (inconclusive)
    """
    username = normalise_username(username)
    target = normalise_username(target)

    async def _check(provider: BaseFollowProvider):
        try:
            following = await _call_with_retry(provider, username, target)
            return ("ok", following, provider.name)
        except KnownError as e:
            logger.warning("[%s] Known error: %s", provider.name, e)
            return ("known_error", str(e), provider.name)
        except Exception as e:
            logger.warning("[%s] Error: %s", provider.name, e)
            return ("error", str(e), provider.name)

    results = await asyncio.gather(*[_check(p) for p in _providers])

    has_success = False
    has_known_error = False
    error_msg = ""

    for status, value, name in results:
        if status == "ok":
            has_success = True
            if value is True:
                logger.info("[%s] Confirmed: %s follows %s", name, username, target)
                return FollowResult.success(True)
        elif status == "known_error":
            has_known_error = True
            error_msg = f"[{name}] {value}"
        else:
            error_msg = f"[{name}] {value}"

    # At least one provider succeeded and none confirmed follow
    if has_success:
        return FollowResult.success(False)

    # Both failed
    if has_known_error:
        return FollowResult.known_error(error_msg)
    return FollowResult.unknown_error(error_msg)
