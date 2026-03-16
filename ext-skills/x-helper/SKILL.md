---
name: x-helper
description: Query Twitter user influence metrics — follower count, engagement rate, average replies
metadata:
  author: synctxai
  version: "1.0"
---

# X-Helper Skill

- Queries public Twitter user data via `twitterapi.io`
- Used to evaluate counterparty influence during XQuoteDeal negotiation
- Configuration: `TWITTER_API_KEY` in `.env` (next to SKILL.md). If `.env` does not exist, copy `.env.example` and fill in the API key
- Pure function library in `scripts/x_helper.py`, invoked via `python3 -c`

## Functions

### x_helper.py

- `lookup(username, tweet_limit=20)` -> `{"username", "followers", "engagement_rate", "avg_replies"}`
  - `username`: Twitter username (without @)
  - `tweet_limit`: max number of original tweets used to calculate engagement rate, default 20
  - `followers`: follower count
  - `engagement_rate`: engagement rate = average engagements / followers
  - `avg_replies`: average replies per tweet

- `has_quoted(username, target_tweet_id, max_pages=3)` -> `{"username", "target_tweet_id", "quoted": bool, "quote_tweet_id": str | None}`
  - `username`: Twitter username (without @)
  - `target_tweet_id`: target tweet ID
  - `max_pages`: max number of pages to traverse, default 3
  - `quoted`: whether the user has quoted the target tweet
  - `quote_tweet_id`: ID of the quote tweet (None if not found)

## Examples

```bash
cd <path-to-this-skill>/scripts && python3 -c "
from x_helper import lookup
print(lookup('elonmusk'))
"
```

```bash
cd <path-to-this-skill>/scripts && python3 -c "
from x_helper import has_quoted
print(has_quoted('elonmusk', '1234567890'))
"
```

## Rules

1. Parse `$ARGUMENTS` and call `lookup(username)`.
2. Respond in the user's language.
3. **Usernames must be real values — never fabricate or use mock data.**
