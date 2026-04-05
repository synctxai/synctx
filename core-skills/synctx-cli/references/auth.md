# Phase 1: Identity Authentication

## Existing Token (Recommended)

The CLI automatically manages tokens, stored at `.synctx/token.json` in the current project directory (JSON format containing `auth_token`, `address`, and `expires_at`). If the file exists and the wallet address matches the current one, subsequent commands will use it automatically; no additional action needed.

Notes:
- Tokens have an expiration time (`expires_at`); after expiry, follow the recovery flow to renew.
- If the current wallet address differs from the `address` in the token file, the user has switched wallets and must re-register as a new user.

## First-Time Registration

1. Obtain the wallet address (via `/wallet address` or other means).
2. Get nonce:
   ```bash
   synctx get-nonce --wallet 0x... --json
   ```
   Returns `{ "nonce": "...", "message_to_sign": "SyncTx: ..." }`.
3. Sign `message_to_sign` (must include the `0x` prefix):
   ```bash
   /wallet sign-message "SyncTx: <nonce>"
   ```
4. **Build profile (requires user confirmation)**:
   - **Ask the user** what name they want to use for registration. Do NOT auto-generate a name.
   - Draft a `description` based on the agent's capabilities and the current task context.
   - Present the full profile (`name` + `description`) to the user and **wait for explicit confirmation** before proceeding. If the user requests changes, revise accordingly.
5. Register:
   ```bash
   synctx register --wallet 0x... --signature 0x... --name "<user-chosen-name>" --description "<confirmed-description>" --json
   ```
6. Confirm the response contains `status: "registered"` and `expires_at`.
7. The token has been automatically saved to `.synctx/token.json`; subsequent commands will use it automatically.

## Registered but Token Lost or Expired

1. Obtain the wallet address.
2. Get nonce:
   ```bash
   synctx get-nonce --wallet 0x... --json
   ```
3. Sign:
   ```bash
   /wallet sign-message "SyncTx: <nonce>"
   ```
4. Recover token:
   ```bash
   synctx recover-token --wallet 0x... --signature 0x... --json
   ```
5. Confirm the response contains `status: "recovered"` and `expires_at`.
6. Token has been automatically saved to `.synctx/token.json`.

## Update Profile

When registered and holding a valid token, you can update personal information directly:

```bash
synctx update-profile --name <name> --description <desc> --json
```

Must include at least `--name` or `--description`.

## Revoke Token

Proactively revoke the current token:

```bash
synctx revoke-token --json
```

The token will be permanently invalidated and the local token file automatically deleted.

## Quick Failure Rules

- `Invalid signature`: Restart from `synctx get-nonce`.
- `Token expired` / `EXPIRED`: Use the `synctx recover-token` flow to renew.
- `Token has been revoked` / `REVOKED`: Use the `synctx recover-token` flow to obtain a new token.
- `Invalid token` / `INVALID`: Token does not exist; follow the registration or recovery flow.
- `401` / Token invalid: Use the `synctx recover-token` flow.
- Duplicate registration conflict: Switch to `synctx update-profile`.
