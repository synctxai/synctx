# Twitter `user_id` Contract Draft

## Goal

Standardize all X-related contract interfaces on immutable Twitter/X `user_id`.

- `username` is not part of deal authority.
- signatures use `user_id`
- `specParams` use `user_id`
- runtime username lookup stays off-chain only

## TwitterRegistry V2

Canonical identity registry:

- `bind(address addr, uint64 userId, string username)`
- `unbind(address addr)`
- `userIdOf(address addr) -> uint64`
- `usernameOf(address addr) -> string`
- `getAddressByUserId(uint64 userId) -> address`
- `getBinding(address addr) -> (uint64 userId, string username)`

Authority is `userIdOf` / `getAddressByUserId`.
`usernameOf` is metadata only.

## X Follow V3

Campaign signature:

- `target_user_id`
- `fee`
- `deadline`

Per-claim `specParams`:

- `abi.encode(uint64 follower_user_id, uint64 target_user_id)`

Claim flow:

- claimer must be bound in `TwitterRegistry`
- contract reads `follower_user_id` from registry

Verifier runtime:

- resolve `follower_user_id -> username`
- resolve `target_user_id -> username`
- call upstream follow APIs using usernames
- identity authority remains `user_id`

## X Quote V2

Deal signature:

- `tweet_id`
- `quoter_user_id`
- `fee`
- `deadline`

Per-deal `specParams`:

- `abi.encode(string tweet_id, uint64 quoter_user_id, string quote_tweet_id)`

Deal flow:

- `partyB` must already be bound in `TwitterRegistry`
- `createDeal()` reads `quoter_user_id` from registry
- no free-form `quoter_username` input remains on-chain

Verifier runtime:

- fetch quote tweet details
- compare tweet author `user_id` with `quoter_user_id`
- only use username lookup as provider compatibility fallback
