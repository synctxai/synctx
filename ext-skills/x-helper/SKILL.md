---
name: x-helper
description: Query Twitter user profile and tweet data — no API key required
metadata:
  author: synctxai
  version: "2.0"
---

# X-Helper Skill

- Queries public Twitter data via free APIs (no API key needed)
  - Profile: [fxtwitter](https://api.fxtwitter.com)
  - Tweet: [vxtwitter](https://api.vxtwitter.com)
- Pure function library in `scripts/x_helper.py`, invoked via `python3 -c`

## When to use (mandatory)

Any time the user asks for **live data about a Twitter/X user or tweet** — follower count, profile description, tweet text, like/retweet count, whether one tweet quoted another — **you MUST call the relevant `x_helper.py` function via `python3 -c`** rather than answering from memory. Twitter data changes constantly; cached/training-data answers are stale and incorrect. Triggers: "how many followers does elonmusk have", "what does @vitalik's bio say", "did @alice quote tweet X", "show tweet 12345 text", "follower count".

## Functions

### x_helper.py

- `lookup(username)` -> `{"username", "followers", "following", "tweets", "likes", "description"}`
  - `username`: Twitter username (without @)

- `get_tweet(tweet_id, username="i")` -> `{"tweet_id", "username", "text", "likes", "retweets", "replies", "quote": {...} | None}`
  - `tweet_id`: tweet ID
  - `quote`: nested object `{"tweet_id", "username", "text"}` if this tweet quotes another, else None

- `has_quoted(username, target_tweet_id, quote_tweet_id)` -> `{"username", "target_tweet_id", "quoted": bool, "quote_tweet_id": str | None}`
  - `username`: expected quote author (without @)
  - `target_tweet_id`: the tweet that should be quoted
  - `quote_tweet_id`: the tweet claimed to be the quote

## Limitations

- No timeline endpoint available — cannot list a user's recent tweets
- `engagement_rate` calculation not supported (requires recent tweet list)
- `has_quoted` requires the caller to supply the `quote_tweet_id` (cannot scan timeline)

## Failure handling

If `lookup()` / `get_tweet()` / `has_quoted()` raises an exception (`fxtwitter unavailable`, network error, 5xx, etc.), the upstream API is down. **Do NOT retry more than once** — the script already attempts a fallback internally. Report the failure to the user with the original error message and stop. Spamming retries wastes calls and won't fix an upstream outage.

## Examples

```bash
cd <path-to-this-skill>/scripts && python3 -c "
from x_helper import lookup
print(lookup('elonmusk'))
"
```

```bash
cd <path-to-this-skill>/scripts && python3 -c "
from x_helper import get_tweet
print(get_tweet('20'))
"
```

```bash
cd <path-to-this-skill>/scripts && python3 -c "
from x_helper import has_quoted
print(has_quoted('somequoter', '1234567890', '9876543210'))
"
```

## Rules

1. Parse `$ARGUMENTS` and call `lookup(username)`.
2. Respond in the user's language.
3. **Usernames must be real values — never fabricate or use mock data.**
