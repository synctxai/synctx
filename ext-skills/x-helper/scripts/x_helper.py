"""Query Twitter user profile and tweet data via free public APIs.

Primary:  fxtwitter  (api.fxtwitter.com)
Fallback: vxtwitter  (api.vxtwitter.com)

No API key required.
"""
from __future__ import annotations

import httpx

FXTWITTER = "https://api.fxtwitter.com"
VXTWITTER = "https://api.vxtwitter.com"
TIMEOUT = 15
HEADERS = {"User-Agent": "x-helper/2.0"}


# ---------------------------------------------------------------------------
# Internal: provider-specific fetchers
# ---------------------------------------------------------------------------

def _lookup_fx(client: httpx.Client, username: str) -> dict:
    resp = client.get(f"{FXTWITTER}/{username}")
    resp.raise_for_status()
    user = resp.json().get("user") or {}
    return {
        "username": user.get("screen_name", username),
        "followers": user.get("followers", 0),
        "following": user.get("following", 0),
        "tweets": user.get("tweets", 0),
        "likes": user.get("likes", 0),
        "description": user.get("description", ""),
    }


def _lookup_vx(client: httpx.Client, username: str) -> dict:
    resp = client.get(f"{VXTWITTER}/{username}")
    resp.raise_for_status()
    data = resp.json()
    return {
        "username": data.get("screen_name", username),
        "followers": data.get("followers_count", 0),
        "following": data.get("following_count", 0),
        "tweets": data.get("tweet_count", 0),
        "likes": 0,
        "description": data.get("description", ""),
    }


def _parse_quote_fx(tweet: dict) -> dict | None:
    qt = tweet.get("quote")
    if isinstance(qt, dict) and qt.get("id"):
        return {
            "tweet_id": qt["id"],
            "username": (qt.get("author") or {}).get("screen_name", ""),
            "text": qt.get("text", ""),
        }
    return None


def _parse_quote_vx(data: dict) -> dict | None:
    qt = data.get("qrt")
    if isinstance(qt, dict) and qt.get("tweetID"):
        return {
            "tweet_id": qt["tweetID"],
            "username": qt.get("user_screen_name", ""),
            "text": qt.get("text", ""),
        }
    return None


def _get_tweet_fx(client: httpx.Client, tweet_id: str) -> dict:
    resp = client.get(f"{FXTWITTER}/i/status/{tweet_id}")
    resp.raise_for_status()
    tweet = resp.json().get("tweet") or {}
    return {
        "tweet_id": tweet.get("id", tweet_id),
        "username": (tweet.get("author") or {}).get("screen_name", ""),
        "text": tweet.get("text", ""),
        "likes": tweet.get("likes", 0),
        "retweets": tweet.get("retweets", 0),
        "replies": tweet.get("replies", 0),
        "quote": _parse_quote_fx(tweet),
    }


def _get_tweet_vx(client: httpx.Client, tweet_id: str) -> dict:
    resp = client.get(f"{VXTWITTER}/i/status/{tweet_id}")
    resp.raise_for_status()
    data = resp.json()
    return {
        "tweet_id": data.get("tweetID", tweet_id),
        "username": data.get("user_screen_name", ""),
        "text": data.get("text", ""),
        "likes": data.get("likes", 0),
        "retweets": data.get("retweets", 0),
        "replies": data.get("replies", 0),
        "quote": _parse_quote_vx(data),
    }


def _try_with_fallback(primary, fallback, *args):
    """Call *primary*; on any network / HTTP error fall back to *fallback*."""
    try:
        return primary(*args)
    except (httpx.HTTPStatusError, httpx.TransportError):
        return fallback(*args)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def lookup(username: str) -> dict:
    """
    Query profile data for the specified user.

    Args:
        username: Twitter username (without @)

    Returns:
        {"username", "followers", "following", "tweets", "likes", "description"}
    """
    username = username.lstrip("@")
    with httpx.Client(headers=HEADERS, timeout=TIMEOUT) as client:
        return _try_with_fallback(_lookup_fx, _lookup_vx, client, username)


def get_tweet(tweet_id: str, username: str = "i") -> dict:
    """
    Fetch a single tweet by ID.

    Args:
        tweet_id: tweet ID
        username: tweet author username (ignored by API, default "i")

    Returns:
        {"tweet_id", "username", "text", "likes", "retweets", "replies",
         "quote": {...} | None}
    """
    with httpx.Client(headers=HEADERS, timeout=TIMEOUT) as client:
        return _try_with_fallback(_get_tweet_fx, _get_tweet_vx, client, tweet_id)


def has_quoted(username: str, target_tweet_id: str, quote_tweet_id: str) -> dict:
    """
    Verify that a specific tweet is a quote of the target tweet.

    Args:
        username: expected quote author (without @)
        target_tweet_id: the tweet that should be quoted
        quote_tweet_id: the tweet claimed to be the quote

    Returns:
        {"username", "target_tweet_id", "quoted": bool, "quote_tweet_id": str | None}
    """
    username = username.lstrip("@")
    target_id = str(target_tweet_id)
    quote_id = str(quote_tweet_id)

    try:
        tweet = get_tweet(quote_id)
    except (httpx.HTTPStatusError, httpx.TransportError):
        return {
            "username": username,
            "target_tweet_id": target_id,
            "quoted": False,
            "quote_tweet_id": None,
        }

    quoted = (
        tweet.get("username", "").lower() == username.lower()
        and tweet.get("quote") is not None
        and str(tweet["quote"].get("tweet_id")) == target_id
    )

    return {
        "username": username,
        "target_tweet_id": target_id,
        "quoted": quoted,
        "quote_tweet_id": quote_id if quoted else None,
    }


if __name__ == "__main__":
    import sys
    name = sys.argv[1] if len(sys.argv) > 1 else "elonmusk"
    print(lookup(name))
