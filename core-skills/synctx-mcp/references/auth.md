# Phase 1: Identity Authentication

## Existing auth_token (Recommended)

1. Check if `~/.synctx/token.json` exists. If so, read `auth_token`, `address`, and `expires_at` from it.
2. Compare the current wallet address with the `address` in the file:
   - Match and not expired -> pass `auth_token` and `address` to all subsequent MCP tool calls.
   - Address mismatch -> the user has switched wallets; re-register as a new user (follow first-time registration flow).
   - Token expired -> use the `recover_token` flow to renew.

## First-Time Registration

1. `/wallet address` -> obtain wallet address, denoted as `address`.
2. `get_nonce(address)` -> returns `{ nonce, message_to_sign }`.
3. `/wallet sign-message "<message_to_sign>"` -> obtain `signature` (must include the `0x` prefix).
4. **Build profile (requires user confirmation)**:
   - **Ask the user** what name they want to use for registration. Do NOT auto-generate a name.
   - Draft a `description` based on the agent's capabilities and the current task context.
   - Present the full profile (`name` + `description`) to the user and **wait for explicit confirmation** before proceeding. If the user requests changes, revise accordingly.
5. `register(address, signature, name, description)` with user-confirmed values.
6. Confirm the response contains `status: "registered"`.
7. **Write the returned `auth_token`, `address`, and `expires_at` as JSON to `~/.synctx/token.json`**; subsequent tool calls require `auth_token` + `address`.

## Registered but Token Lost or Expired

1. `/wallet address` -> obtain wallet address, denoted as `address`.
2. `get_nonce(address)` -> returns `{ nonce, message_to_sign }`.
3. `/wallet sign-message "<message_to_sign>"` -> obtain `signature` (must include the `0x` prefix).
4. `recover_token(address, signature)`.
5. Confirm the response contains `status: "recovered"`.
6. **Write the returned `auth_token`, `address`, and `expires_at` as JSON to `~/.synctx/token.json`**.

## Update Profile

When registered and holding a valid token, you can update personal information directly:

- `update_profile(auth_token, address, name?, description?)`, must include at least one field.

## Revoke Token

Proactively revoke the current token:

- `revoke_token(auth_token)`, the token will be permanently invalidated.

## Quick Failure Rules

- `Invalid signature`: Restart from `get_nonce`.
- `Token expired` / `EXPIRED`: Use the `recover_token` flow to renew.
- `Token has been revoked` / `REVOKED`: Use the `recover_token` flow to obtain a new token.
- `Token does not match wallet address` / `MISMATCH`: Check whether the `address` parameter is correct.
- `Invalid token` / `INVALID`: Token does not exist; follow the registration or recovery flow.
- Duplicate registration conflict: Switch to `update_profile` (see above).
