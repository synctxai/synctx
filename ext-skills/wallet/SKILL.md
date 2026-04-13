---
name: wallet
description: >-
  Multi-chain EVM wallet — read contract state, send transactions, sign
  messages, query token balances, and interact with any verified smart contract
  via ABI. Use this skill when the task involves blockchain operations such as
  checking balances, querying allowances, approving tokens, calling or invoking
  smart contracts, signing messages (EIP-191/EIP-712), or sending on-chain
  transactions. Also use when the user mentions wallet, ETH, USDC, token
  balance, contract calls, DeFi, on-chain interaction, or transaction signing,
  even if they don't explicitly say "wallet".
license: MIT
compatibility: Requires Deno 2.x+ and network access
metadata:
  author: synctxai
  version: "1.2"
---

## 0. Critical Constraints

1. **NEVER write raw Deno/ethers code.** Do not import ethers or viem directly; do not manually construct ABI encoding. ALL contract interactions MUST go through the `run.ts` CLI commands described below.
2. **NEVER fabricate data.** Addresses, amounts, and function signatures must come from user input or on-chain queries. If a parameter is unknown, use `list-functions` to discover it or ask the user.
3. **Write operations require user confirmation** — preview with `--dry-run`, present the details, then execute only after the user approves. Exception: when the SyncTx workflow's Special Authorizations override this (confirmation is skipped).

## 1. On Load

When this skill is first loaded, determine `WALLET_DIR` — the **absolute path** to the directory containing this SKILL.md — and **immediately** run `check-wallet` before doing anything else. All subsequent commands use `$WALLET_DIR` so the caller never needs to `cd`; the current working directory must remain unchanged.

```bash
# WALLET_DIR = absolute path to this skill's directory (set once, reuse everywhere)
WALLET_DIR="/absolute/path/to/this/skill"

# Check deno availability; fall back to ~/.deno/bin/deno if PATH is missing
if ! command -v deno &>/dev/null; then
  if [ -x "$HOME/.deno/bin/deno" ]; then
    export PATH="$HOME/.deno/bin:$PATH"
  else
    echo '{"error":"deno not found. Install: curl -fsSL https://deno.land/install.sh | sh"}' >&2
    exit 4
  fi
fi

deno run -P "$WALLET_DIR/scripts/run.ts" check-wallet
```

> **Deno path fallback**: if a later command fails with `command not found: deno`, retry **once** using the explicit path `$HOME/.deno/bin/deno run -P "$WALLET_DIR/scripts/run.ts" ...`. Once that works, keep using `$HOME/.deno/bin/deno` for the rest of the session — do **not** prepend `export PATH=...` to every command, since each bash call is a fresh subshell and `export` does not persist.
>
> **Important**: never `cd` into `$WALLET_DIR`. All commands use absolute paths via `$WALLET_DIR` so the working directory is not affected.

Based on the result:

- `"status": "ok"` → Wallet is ready; proceed with the user's request.
- `"status": "no_env"`, `"no_key"`, or `"invalid_key"` → Automatically run `generate-wallet` to create a new wallet, then tell the user:
  - The new wallet address
  - Where the private key is stored (`.env` file next to this SKILL.md)
  - Run `balance` to show ETH + USDC balances across all chains
  - If balances are insufficient, suggest transferring ETH (for gas) and USDC (for trading) to the wallet address

> **Warning:** The private key is stored in a local `.env` file and is not production-grade secure. Only deposit minimal funds for testing.

## 2. Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `PRIVATE_KEY` | Yes | EOA private key (hex with `0x` prefix) |
| `ETHERSCAN_API_KEY` | No | For ABI fetching from Etherscan |
| `ABI_PROXY_URL` | No | ABI caching proxy URL |
| `CHAIN_RPC_<ID>` | No | Custom RPC URL per chain (e.g. `CHAIN_RPC_8453`) |

If `PRIVATE_KEY` is missing, automatically run `generate-wallet` and inform the user. Read-only operations (`read`, `list-functions`) do not require it. Read operations execute directly via RPC; write operations send transactions directly and the user pays gas.

## 3. Command Reference

### Setup

| Command | Description |
|---------|-------------|
| `check-wallet` | Check wallet status (ok / no_env / no_key / invalid_key) |
| `generate-wallet` | Generate new private key, write to `.env` |
| `address` | Show wallet address |

### Balance

```bash
deno run -P "$WALLET_DIR/scripts/run.ts" balance                                   # All 4 chains: ETH + USDC
deno run -P "$WALLET_DIR/scripts/run.ts" balance --chain 8453                      # Single chain: ETH + USDC
deno run -P "$WALLET_DIR/scripts/run.ts" balance --token 0xTOKEN --chain 8453      # Specific ERC20 on specific chain
```

### Contract Read

Function signature format: `name(inputTypes)->(outputTypes)`.

```bash
deno run -P "$WALLET_DIR/scripts/run.ts" read CONTRACT "balanceOf(address)->(uint256)" --args '["0xOwner"]' --chain 8453
deno run -P "$WALLET_DIR/scripts/run.ts" read CONTRACT "name()->(string)"
```

Arguments are passed as a JSON array via `--args`. Omit `--args` when there are no parameters. Use `--from 0xAddress` when the view function depends on `msg.sender`.

### Contract Write (`send`)

All writes go through the `send` command. When a call requires token approval, use `--approve TOKEN:AMOUNT` — the approve and business call are executed as two separate transactions.

```bash
# Basic write
deno run -P "$WALLET_DIR/scripts/run.ts" send CONTRACT "fn(uint256)" --args '["42"]'

# With token approval (two txs: approve then call)
deno run -P "$WALLET_DIR/scripts/run.ts" send CONTRACT "createDeal(address,uint96)" \
  --args '["0x...", "1000000"]' --approve 0xUSDC:1000000

# Preview without submitting
deno run -P "$WALLET_DIR/scripts/run.ts" send CONTRACT "fn()" --dry-run

# With ETH value (rare)
deno run -P "$WALLET_DIR/scripts/run.ts" send CONTRACT "fn()" --value 1000000000000000000
```

### Signing

```bash
deno run -P "$WALLET_DIR/scripts/run.ts" sign "hello world"                                    # EIP-191
deno run -P "$WALLET_DIR/scripts/run.ts" sign-typed '{"domain":{...},"types":{...},...}'       # EIP-712
```

### ABI Discovery & Decoding

| Command | Description |
|---------|-------------|
| `list-functions CONTRACT --chain 8453` | List read/write functions |
| `decode-logs TX_HASH CONTRACT --chain 8453` | Decode event logs |
| `decode-revert HEX_DATA --contract 0x... --chain 8453` | Decode revert reason |

### Utilities

```bash
deno run -P "$WALLET_DIR/scripts/run.ts" to-raw 1.5 --decimals 6          # → 1500000
deno run -P "$WALLET_DIR/scripts/run.ts" fmt 1500000 --decimals 6 --symbol USDC  # → "1.5 USDC"
```

## 4. Workflow: Unknown Contract Interaction

Before reading or writing any contract you have not seen in this session — including calling `instruction()` — you MUST discover its ABI first:

1. **Discover**: run `list-functions CONTRACT --chain 8453`. The exact return type and parameter encoding must come from this list, not from guesses (e.g. `instruction()->(string)` vs `instruction() returns (string)`).
2. **Find** the target function signature from the output.
3. **Call**: `read addr "sig" --args [...]` for reads, `send addr "sig" --args [...]` for writes.
4. **After a write**: check the tx response for needed data (returned IDs, status, etc.). Only use `decode-logs` if you need event data not already in the tx response.
5. **On failure**: use `decode-revert` with the revert hex data to get the human-readable reason **before** doing anything else — never re-attempt a send with tweaked args until you understand the revert.

### Fallback: ABI Not Found (Proxy Contracts)

If `list-functions` returns `{"error":"ABI not found ..."}`, the contract is likely an unverified proxy. Resolve the implementation and retry:

```bash
# 1. Read the proxy's implementation pointer
deno run -P "$WALLET_DIR/scripts/run.ts" read PROXY "IMPLEMENTATION()->(address)" --chain 8453
# Other common names: implementation(), getImplementation(), masterCopy()

# 2. Discover functions on the implementation
deno run -P "$WALLET_DIR/scripts/run.ts" list-functions IMPL_ADDR --chain 8453

# 3. Read/send on the ORIGINAL PROXY address using the impl's signatures
```

The call target remains the **proxy address**, not the implementation.

## 5. Workflow: Write Operations

Write operations are irreversible on-chain transactions. Follow this sequence:

1. **Preview**: run `send` with `--dry-run` to estimate gas and preview details.
2. **Confirm**: present to the user the target contract, function, args, and estimated gas cost.
3. **Execute**: run `send` without `--dry-run` after user confirmation.
4. **Verify**: check the tx response for needed data. Use `decode-logs` only if additional event data is required.
5. **On failure**: use `decode-revert` with the revert hex to get the reason.

Exception: when the SyncTx workflow's Special Authorizations apply, steps 2–3 (user confirmation) are skipped.

## 6. EIP-712 Signatures & Deadline Handling

An EIP-712 signature binds to **every field** of the signed struct. If any bound field (deadline, amount, nonce, etc.) drifts between signing and the contract call, `ecrecover` recovers a different address and the transaction reverts — often with an opaque `InvalidSignature` error. To change any bound field after signing, you must **re-sign**; signatures cannot be patched.

**Trap**: calling `$(date +%s)` twice yields two different timestamps. Lock signature-bound values into a shell variable **once** and reuse it for both `request-sign` and `send`:

```bash
DEADLINE=$(($(date +%s) + 3600))
SIG=$(synctx request-sign --deadline $DEADLINE ...)
deno run -P "$WALLET_DIR/scripts/run.ts" send CONTRACT "fn(...)" --args '[..., "'$DEADLINE'", ..., "'$SIG'"]'
```

**Verifier-signature workflow**: when a contract function takes `(bytes signature, uint deadline)` or similar (e.g. `fulfillWithVerifierSig`), obtain the signature via `synctx request-sign --deadline $DEADLINE --verifier 0x...` first, then pass the same `$DEADLINE` to `send`. The verifier address and counterparty are typically given by the user or read from `requiredSpecs()`.

## 7. ERC20 Allowance Check

Before calling any contract method that moves tokens (e.g. `createDeal`), **always check the current allowance first**. If the allowance is less than the required amount, approve before sending. Never send a token-consuming call without verifying allowance, and confirm the approve transaction is mined before sending the business call.

```bash
# 1. Check current allowance
deno run -P "$WALLET_DIR/scripts/run.ts" read TOKEN "allowance(address,address)->(uint256)" \
  --args '["0xOwnerAddr","0xSpenderContract"]' --chain 8453

# 2. Approve then call (two separate transactions)
deno run -P "$WALLET_DIR/scripts/run.ts" send CONTRACT "createDeal(...)" --args '[...]' \
  --approve 0xUSDC:AMOUNT
```

## 8. Revert Handling

When a transaction fails, **always decode the revert reason first** — before any further troubleshooting or retry. If `send` returns a revert with a custom 4-byte selector (e.g. `0xa86b6512`), immediately call `decode-revert <hex>`. Never re-attempt a send until you understand the revert.

Common revert recovery patterns:

- **`InvalidVerifierSignature` / `InvalidSignature` / `MetaTxInvalidSignature`**: the verifier signature is stale or bound to a different deadline. Re-request a fresh signature via `synctx request-sign --deadline $DEADLINE --verifier 0x...` (locking the new deadline per §6), then retry `send` with the new signature and the same deadline. Do **not** re-read `instruction()` — the contract logic is fine; only the signature needs refreshing.
- **`InvalidParams`**: the arguments do not match the contract's expected layout. Re-read `instruction()` to confirm parameter encoding.

## 9. Output Format & Exit Codes

All commands output JSON to stdout. Errors output `{ "error": "message" }` to stderr.

| Exit Code | Meaning |
|-----------|---------|
| 0 | Success |
| 1 | Runtime error |
| 2 | Bad arguments |
| 3 | Network error |
| 4 | Wallet not configured |

## 10. Rules

1. Parse `$ARGUMENTS` and map to the corresponding command.
2. If `PRIVATE_KEY` is missing, automatically run `generate-wallet` and inform the user. Read-only operations (`read`, `list-functions`) do not need it.
3. Read operations execute directly via RPC. Write operations send transactions directly — the user pays gas.
4. All parameters must be real values — never fabricate addresses, amounts, or signatures.
5. If required parameters are missing, ask the user.
6. On error, use `decode-revert` with the revert hex to get the human-readable reason before troubleshooting.
7. Respond in the user's language.
