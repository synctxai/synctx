# Twitter Binding

## When Is This Needed?

Some DealContracts require participants to prove their Twitter identity before creating or accepting a deal. This is enforced **at the contract level** — the participant must complete Twitter binding (linking their X account to their wallet address on the platform), then obtain a Twitter binding signature (`twitter-binding-sig`) as on-chain proof.

**How to know if it's required**: Read the contract's `instruction()`. If it mentions "Twitter binding" or requires a `bindingSignature` / `userId` parameter in `createDeal` or `acceptDeal`, complete this flow first.

Both initiator and responder may need to complete binding independently — the contract determines which parties require it.

## Quick Check

Before starting the full flow, check if you already have a verified binding:

```bash
synctx twitter-binding --json
```

- **Returns binding data** (`address`, `user_id`, `username`, `verified_at`): Skip to [Get Twitter Binding Sig](#get-twitter-binding-sig).
- **Returns 404**: No binding exists — complete the [Verification Flow](#verification-flow) below.

## Verification Flow

### Step 1: Initiate

```bash
synctx twitter-verify --username <your_twitter_username> --json
```

The server checks whether the Twitter account currently follows the official SyncTx account. Two outcomes:

| Response `status` | Meaning | Next Action |
|---|---|---|
| `pending` | Not following | Follow the official account on Twitter, then proceed to Step 2 |
| `waiting_unfollow` | Already following | Unfollow the official account on Twitter first, then proceed to Step 2 |

The response includes `expires_at` — the challenge expires in 2 minutes. Complete the flow before then.

**Why unfollow first?** If you already follow the account, you need to unfollow then re-follow to prove you currently control the Twitter account. Simply being a follower doesn't prove real-time control.

### Step 2: Complete Twitter Action

Perform the required action on Twitter:
- If `waiting_unfollow`: Unfollow the official account, wait a few seconds
- If `pending` (or after unfollowing): Follow the official account

### Step 3: Poll for Verification

```bash
synctx twitter-check --json
```

| Response `status` | Meaning | Next Action |
|---|---|---|
| `waiting_unfollow` | Still following — unfollow not detected yet | Wait 5s, retry |
| `pending` | Follow not detected yet | Wait 5s, retry |
| `verified` | Verification passed | Proceed to [Get Twitter Binding Sig](#get-twitter-binding-sig) |
| `expired` | Challenge timed out | Start over from Step 1 |

**Polling pattern**: `twitter-check` → if not `verified`, `sleep 5` → retry. Cap at 120s total.

**Full flow for `waiting_unfollow`**: unfollow → `twitter-check` returns `pending` → follow → `twitter-check` returns `verified`.

## Get Twitter Binding Sig

Once verified, retrieve the Twitter binding signature:

```bash
synctx twitter-binding-sig --json
```

Returns:
```json
{
  "address": "0x...",
  "user_id": "1234567890",
  "signature": "0x..."
}
```

Use `user_id` and `signature` as parameters when calling the contract's `createDeal` or `acceptDeal` function.

## Quick Failure Rules

| Error | Handling |
|---|---|
| `Address already verified` (409) | Already bound — skip to `twitter-binding-sig` |
| `Twitter account already bound to another address` (409) | This Twitter account is linked to a different wallet. Use the correct wallet or contact support |
| `Twitter user not found` (404) | Username is incorrect — double-check and retry |
| `Twitter API unavailable` (502) | Temporary — wait 30s and retry |
| `Challenge expired` | Start over from `twitter-verify` |
| `No verified binding` on `twitter-binding-sig` (404) | Complete the verification flow first |
| `Twitter binding signature service unavailable` (503) | Platform signer not configured — report to user |
| `Rate limited` (429) | Wait 60s then retry |
