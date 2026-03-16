"""Query Twitter user influence metrics (follower count, engagement rate, average replies)."""

import os
from pathlib import Path

import httpx
from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parent.parent / ".env")

API_KEY = os.environ.get("TWITTER_API_KEY", "")

BASE_URL = "https://api.twitterapi.io"
TIMEOUT = 15


def lookup(username: str, tweet_limit: int = 20) -> dict:
    """
    Query influence data for the specified user.

    Args:
        username: Twitter username (without @)
        tweet_limit: max number of tweets used to calculate engagement rate

    Returns:
        {"username", "followers", "engagement_rate", "avg_replies"}
    """
    headers = {"X-API-Key": API_KEY}

    with httpx.Client(headers=headers, timeout=TIMEOUT) as client:
        # 1. User info
        resp = client.get(f"{BASE_URL}/twitter/user/info", params={"userName": username})
        resp.raise_for_status()
        user_data = resp.json()
        user = user_data.get("data") or user_data
        followers = (
            user.get("followers")
            or user.get("followers_count")
            or user.get("followersCount")
            or 0
        )

        if not followers:
            return {"username": username, "followers": 0, "engagement_rate": 0.0, "avg_replies": 0.0}

        # 2. Recent tweets
        resp = client.get(
            f"{BASE_URL}/twitter/user/last_tweets",
            params={"userName": username, "cursor": ""},
        )
        resp.raise_for_status()
        tweet_data = resp.json()
        all_tweets = (
            (tweet_data.get("data") or {}).get("tweets")
            or tweet_data.get("tweets")
            or []
        )
        original = [t for t in all_tweets if not t.get("retweeted_tweet")][:tweet_limit]

        if not original:
            return {"username": username, "followers": followers, "engagement_rate": 0.0, "avg_replies": 0.0}

        total_eng = sum(
            (t.get("likeCount") or t.get("favorite_count") or 0)
            + (t.get("retweetCount") or t.get("retweet_count") or 0)
            + (t.get("replyCount") or t.get("reply_count") or 0)
            for t in original
        )
        total_replies = sum(
            t.get("replyCount") or t.get("reply_count") or 0
            for t in original
        )
        avg_eng = total_eng / len(original)
        avg_replies = total_replies / len(original)
        engagement_rate = avg_eng / followers

    return {
        "username": username,
        "followers": followers,
        "engagement_rate": round(engagement_rate, 6),
        "avg_replies": round(avg_replies, 2),
    }


def has_quoted(username: str, target_tweet_id: str, max_pages: int = 3) -> dict:
    """
    Check whether the specified user has quoted a given tweet.

    Traverses the user's recent tweet timeline to find any quote of the target tweet.

    Args:
        username: Twitter username (without @)
        target_tweet_id: target tweet ID
        max_pages: max number of pages to traverse, default 3

    Returns:
        {"username", "target_tweet_id", "quoted": bool, "quote_tweet_id": str | None}
    """
    headers = {"X-API-Key": API_KEY}
    target_id = str(target_tweet_id)

    with httpx.Client(headers=headers, timeout=TIMEOUT) as client:
        cursor = ""
        for _ in range(max_pages):
            resp = client.get(
                f"{BASE_URL}/twitter/user/last_tweets",
                params={"userName": username, "cursor": cursor},
            )
            resp.raise_for_status()
            tweet_data = resp.json()

            data = tweet_data.get("data") or tweet_data
            tweets = data.get("tweets") or []
            if not tweets:
                break

            for t in tweets:
                qt = t.get("quoted_tweet")
                if isinstance(qt, dict) and qt.get("id") == target_id:
                    return {
                        "username": username,
                        "target_tweet_id": target_id,
                        "quoted": True,
                        "quote_tweet_id": t.get("id"),
                    }

            cursor = (
                data.get("next_cursor")
                or tweet_data.get("next_cursor")
                or ""
            )
            if not cursor:
                break

    return {
        "username": username,
        "target_tweet_id": target_id,
        "quoted": False,
        "quote_tweet_id": None,
    }


if __name__ == "__main__":
    import sys
    name = sys.argv[1] if len(sys.argv) > 1 else "elonmusk"
    print(lookup(name))
