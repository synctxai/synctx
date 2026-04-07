"""Core verification logic.

Error handling strategy:
    - Known errors (KnownError: auth/quota) -> return error immediately, no retry
    - Temporary errors (network/timeout/rate-limit/5xx) -> retry within same provider, then fall through to next
    - Tweet does not exist (returns None) -> treated as "not quoted", return verified=False
"""

from __future__ import annotations

import asyncio
import logging
from typing import Callable, Optional

from config import settings
from models import TweetInfo, VerifyResult
from providers.base import BaseProvider, KnownError, normalise_user_id
from providers.twitter_api import TwitterAPIProvider
from providers.twitterapi_io import TwitterAPIIOProvider

logger = logging.getLogger(__name__)

MAX_RETRIES = 2
RETRY_DELAY = 0.5


def _build_providers() -> list[BaseProvider]:
    timeout = settings.request_timeout
    return [
        TwitterAPIProvider(timeout=timeout),
        TwitterAPIIOProvider(timeout=timeout),
    ]


_providers = _build_providers()


async def _call_with_retry(
    provider: BaseProvider, tweet_id: str
) -> Optional[TweetInfo]:
    for attempt in range(MAX_RETRIES + 1):
        try:
            return await provider.get_tweet_details(tweet_id)
        except KnownError:
            raise
        except Exception:
            if attempt == MAX_RETRIES:
                raise
            await asyncio.sleep(RETRY_DELAY * (attempt + 1))


async def _get_tweet_info(tweet_id: str) -> VerifyResult | TweetInfo | None:
    all_error = True
    error_msg = ""

    has_known_error = False
    for provider in _providers:
        try:
            info = await _call_with_retry(provider, tweet_id)
            if info is not None:
                logger.info("[%s] Successfully fetched tweet %s", provider.name, tweet_id)
                return info
            logger.info("[%s] Tweet %s does not exist", provider.name, tweet_id)
            all_error = False
        except KnownError as e:
            logger.warning("[%s] Known error: %s", provider.name, e)
            error_msg = f"[{provider.name}] {e}"
            has_known_error = True
        except Exception as e:
            logger.warning("[%s] Error: %s", provider.name, e)
            error_msg = f"[{provider.name}] {e}"

    if all_error:
        if has_known_error:
            return VerifyResult.known_error(error_msg)
        return VerifyResult.unknown_error(error_msg)
    return None


async def _verify(
    quoter_user_id: str,
    target_tweet_id: str,
    new_tweet_id: str,
    type_check: Callable[[TweetInfo], bool],
) -> VerifyResult:
    result = await _get_tweet_info(new_tweet_id)

    if isinstance(result, VerifyResult):
        return result

    if result is None:
        return VerifyResult.success(False, "tweet does not exist")

    info: TweetInfo = result
    norm_user_id = normalise_user_id(quoter_user_id)

    if info.author_user_id != norm_user_id:
        return VerifyResult.success(False, "wrong author")
    if not type_check(info):
        return VerifyResult.success(False, "not a quote tweet")
    if info.quoted_tweet_id != target_tweet_id:
        return VerifyResult.success(False, "quoted wrong tweet")

    return VerifyResult.success(True)


async def has_quote(quoter_user_id: str, target_tweet_id: str, new_tweet_id: str) -> VerifyResult:
    return await _verify(quoter_user_id, target_tweet_id, new_tweet_id, lambda i: i.is_quote)
