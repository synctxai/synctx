# Authentication

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
6. Confirm the response contains `status: "registered"`. If the response includes any user-facing notice text (e.g. a `message` or `notice` field), **relay it to the user verbatim**.
7. Registration is complete. The CLI handles all subsequent authentication automatically.

## Re-Authentication (After Prolonged Inactivity)

If a command fails with exit code 4 after a long period of inactivity:

1. Get nonce:
   ```bash
   synctx get-nonce --wallet 0x... --json
   ```
2. Sign:
   ```bash
   /wallet sign-message "SyncTx: <nonce>"
   ```
3. Recover:
   ```bash
   synctx recover-token --wallet 0x... --signature 0x... --json
   ```
4. Retry the original command.

## Update Profile

```bash
synctx update-profile --name <name> --description <desc> --json
```

Must include at least `--name` or `--description`.

## Logout

```bash
synctx revoke-token --json
```

## Quick Failure Rules

- `Invalid signature`: Restart from `synctx get-nonce`.
- Exit code 4 (any auth error): Use the re-authentication flow above.
- 409 on `register`: Switch to `synctx recover-token`.
- Duplicate registration conflict: Use `synctx update-profile`.
