# Twitter Verification

## When Is This Needed?

Some DealContracts require participants to prove their Twitter identity before creating or accepting a deal. This is enforced **at the contract level** — the participant must complete Twitter verification (linking their X account to their wallet address on the platform).

**How to know if it's required**: Read the contract's `instruction()`. If it mentions "Twitter verification" (or the legacy term "Twitter binding") or requires a `userId` parameter in `createDeal` or `acceptDeal`, complete this flow first.

Both initiator and responder may need to complete verification independently — the contract determines which parties require it.

## Quick Check

Before starting the full flow, check if you already have a verified account:

```bash
synctx twitter-me --json
```

- **Returns binding details** (`userId`, `username`, `bindingTime`): Already verified — use `userId` directly when calling the contract.
- **Returns 404**: Not verified — complete the [Verification Flow](#verification-flow) below.

To check whether an *arbitrary* address is bound (no token required, returns only `{ bound: true/false }`):

```bash
synctx twitter-status --address 0x... --json
```

## Verification Flow

### Step 1: Initiate

```bash
synctx twitter-verify --username <your_twitter_username> --json
```

The server checks whether the Twitter account currently follows the official SyncTx account. Two paths:

| Response `status` | Meaning | Challenge | Expiry |
|---|---|---|---|
| `pending_follow` | Not following | Follow the official account on Twitter | 5 minutes |
| `pending_engagement` | Already following | Retweet or quote the specified tweet | 10 minutes |

For `pending_engagement`, the response includes `tweet_url` — the tweet to retweet or quote.

### Step 2: Complete Twitter Action

Perform the required action on Twitter:
- If `pending_follow`: Follow the official SyncTx account
- If `pending_engagement`: Retweet or quote-tweet the URL in `tweet_url`

### Step 3: Poll for Verification

```bash
synctx twitter-check --json
```

| Response `status` | Meaning | Next Action |
|---|---|---|
| `pending_follow` | Follow not detected yet | Wait 5s, retry |
| `pending_engagement` | Retweet/quote not detected yet | Wait 5s, retry |
| `verified` | Verification passed | Done — use `user_id` from the response |
| `expired` | Challenge timed out | Start over from Step 1 |

**Polling pattern**: `twitter-check` → if not `verified`, `sleep 5` → retry. Cap at 120s total.

## Using the Verification Result

Once verified, use the `userId` from the verification response (or from `twitter-me --json`) as the parameter when calling the contract's `createDeal` or `acceptDeal` function. The platform records the verification on-chain automatically — no separate signature step is needed.

## Quick Failure Rules

| Error | Handling |
|---|---|
| `Address already verified` (409) | Already verified — use `twitter-me --json` to get `userId` |
| `Twitter account already bound to another address` (409) | This Twitter account is linked to a different wallet. Use the correct wallet or contact support |
| `Twitter user not found` (404) | Username is incorrect — double-check and retry |
| `Twitter API unavailable` (502) | Temporary — wait 30s and retry |
| `Challenge expired` | Start over from `twitter-verify` |
| `Unable to verify — all verification tweets have already been retweeted/quoted` (422) | Contact admin — no available verification tweets left |
| `Rate limited` (429) | Wait 60s then retry |
