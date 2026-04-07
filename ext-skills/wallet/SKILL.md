---
name: wallet-deno
description: >-
  Multi-chain EVM wallet — read contract state, send transactions, sign messages,
  query token balances, and interact with any verified smart contract via ABI.
  Use this skill when the task involves blockchain operations such as checking balances,
  querying allowances, approving tokens, calling or invoking smart contracts,
  signing messages (EIP-191/EIP-712), or sending on-chain transactions.
  Also use when the user mentions wallet, ETH, USDC, token balance, contract calls,
  DeFi, on-chain interaction, or transaction signing, even if they don't explicitly
  say "wallet".
license: MIT
compatibility: Requires Deno 2.x+ and network access
metadata:
  author: synctxai
  version: "1.1"
---

## On Load

When this skill is first loaded, **immediately** run `check-wallet` before doing anything else.

```bash
# 0. Check deno is available
if ! command -v deno &>/dev/null; then
  echo '{"error":"deno not found. Install: curl -fsSL https://deno.land/install.sh | sh"}' >&2
  exit 4
fi

deno run -P scripts/run.ts check-wallet
```

Based on the result:

- `"status": "ok"` → Wallet is ready. Proceed with the user's request.
- `"status": "no_env"`, `"no_key"`, or `"invalid_key"` → Automatically run `generate-wallet` to create a new wallet. Then tell the user:
  - The new wallet address
  - The private key storage location (`.env` file next to this SKILL.md)
  - Run `balance` to show ETH + USDC balances across all chains
  - If balances are insufficient, suggest the user transfer ETH (for gas) and USDC (for trading) to the wallet address

> **Warning:** The private key is stored in a local `.env` file and is not production-grade secure. Only deposit minimal funds for testing.

## Critical Constraints

1. **NEVER write raw Deno/ethers code.** Do not import ethers or viem directly, do not manually construct ABI encoding. ALL contract interactions MUST go through the `run.ts` CLI commands.
2. **NEVER fabricate data.** Addresses, amounts, function signatures — all must come from user input or on-chain queries. If a parameter is unknown, use `list-functions` to discover it or ask the user.
3. **Write operations require user confirmation** (except when overridden by the SyncTx workflow's Special Authorizations). Follow the [Write Operation Workflow](#workflow-write-operations) below.

## Command Reference

### Setup

| Command | Description |
|---------|-------------|
| `check-wallet` | Check wallet status (ok / no_env / no_key / invalid_key) |
| `generate-wallet` | Generate new private key, write to .env |
| `address` | Show wallet address |

### Balance

```bash
deno run -P scripts/run.ts balance                                   # All 4 chains: ETH + USDC
deno run -P scripts/run.ts balance --chain 8453                      # Single chain: ETH + USDC
deno run -P scripts/run.ts balance --token 0xTOKEN --chain 8453      # Specific ERC20 on specific chain
```

### Contract Read

Function signature format: `name(inputTypes)->(outputTypes)`

- `balanceOf(address)->(uint256)` — with return type
- `name()->(string)` — no args
- `approve(address,uint256)->(bool)` — bool return
- `fn(address,uint96)` — write, no return type needed

```bash
deno run -P scripts/run.ts read CONTRACT "balanceOf(address)->(uint256)" --args '["0xOwner"]' --chain 8453
deno run -P scripts/run.ts read CONTRACT "name()->(string)"
```

Use `--from 0xAddress` when the view function depends on `msg.sender`.

### Contract Write (`send`)

All writes go through the `send` command, two modes:

- **Gasless** (`--gasless gelato`): Gelato 7702 Turbo relay. The platform returns a `gasless` field on each contract — pass its value to `--gasless`.
- **Self-pay** (no `--gasless`): Sends directly, user pays gas.

When a call requires token approval, use `--approve TOKEN:AMOUNT`. In gasless mode, approve + business call are batched atomically via EIP-7702 (both revert if either fails). In self-pay mode, they are two separate transactions.

```bash
# Gasless
deno run -P scripts/run.ts send CONTRACT "fn(uint256)" --args '["42"]' --gasless gelato

# Self-pay
deno run -P scripts/run.ts send CONTRACT "fn(uint256)" --args '["42"]'

# With token approval (gasless, atomic) — approve + call batched via EIP-7702
deno run -P scripts/run.ts send CONTRACT "createDeal(address,uint96)" \
  --args '["0x...", "1000000"]' \
  --approve 0xUSDC:1000000 --gasless gelato

# With token approval (self-pay, two txs)
deno run -P scripts/run.ts send CONTRACT "createDeal(address,uint96)" \
  --args '["0x...", "1000000"]' \
  --approve 0xUSDC:1000000

# Preview without submitting
deno run -P scripts/run.ts send CONTRACT "fn()" --dry-run

# With ETH value (rare, self-pay only)
deno run -P scripts/run.ts send CONTRACT "fn()" --value 1000000000000000000
```

### Signing

```bash
deno run -P scripts/run.ts sign "hello world"                                    # EIP-191
deno run -P scripts/run.ts sign-typed '{"domain":{...},"types":{...},...}'       # EIP-712
```

### ERC20 Pre-Call Check

Before calling any contract method that moves tokens (e.g. `createDeal`), **always check the current allowance first**. If allowance < required amount, approve before sending.

```bash
# 1. Check current allowance
deno run -P scripts/run.ts read TOKEN "allowance(address,address)->(uint256)" \
  --args '["0xOwnerAddr","0xSpenderContract"]' --chain 8453

# 2a. Gasless: --approve batches approve + call atomically (both revert if either fails)
deno run -P scripts/run.ts send CONTRACT "createDeal(...)" --args '[...]' \
  --approve 0xUSDC:AMOUNT --gasless gelato

# 2b. Self-pay: two separate transactions
deno run -P scripts/run.ts send TOKEN "approve(address,uint256)" \
  --args '["0xSpenderContract","AMOUNT"]'
deno run -P scripts/run.ts send CONTRACT "createDeal(...)" --args '[...]'
```

> **Rule**: Never send a token-consuming call without verifying allowance. In gasless mode, always use `--approve` to batch atomically. In self-pay mode, confirm the approve tx is mined before sending the business call.

### ABI Discovery & Decoding

```bash
deno run -P scripts/run.ts list-functions CONTRACT --chain 8453                  # List read/write functions
deno run -P scripts/run.ts decode-logs TX_HASH CONTRACT --chain 8453             # Decode event logs
deno run -P scripts/run.ts decode-revert HEX_DATA --contract 0x... --chain 8453  # Decode revert reason
```

### Utilities

```bash
deno run -P scripts/run.ts to-raw 1.5 --decimals 6          # → 1500000
deno run -P scripts/run.ts fmt 1500000 --decimals 6 --symbol USDC  # → "1.5 USDC"
deno run -P scripts/run.ts relay-status TASK_ID              # Check relay task status
```

## Workflow: Unknown Contract Interaction

1. `list-functions CONTRACT --chain 8453` → discover all function signatures
2. Find the target function sig from output
3. Read: `read addr "sig" --args [...]` / Write: `send addr "sig" --args [...]`
4. After write: check the tx response for needed data (e.g. returned IDs or status). Only use `decode-logs` if you need event data not in the tx response.
5. On failure: use `decode-revert` with the revert hex data to get the human-readable reason.

## Workflow: Write Operations

Write operations are irreversible on-chain transactions. Follow this sequence:

1. **Preview**: Run `send` with `--dry-run` to estimate gas and preview transaction details
2. **Confirm**: Present to user: target contract, function, args, estimated gas cost
3. **Execute**: Run `send` without `--dry-run` after user confirmation
4. **Verify**: Check the tx response for needed data. Use `decode-logs` only if additional event data is required.
5. **On failure**: Use `decode-revert` with the revert hex to get the revert reason.

Exception: when the SyncTx workflow's Special Authorizations override confirmation (steps 2-3 are skipped).

## Output Format

- All commands output JSON to stdout
- Errors output `{ "error": "message" }` to stderr
- Exit codes: 0=success, 1=runtime error, 2=bad args, 3=network error, 4=wallet not configured

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `PRIVATE_KEY` | Yes | EOA private key (hex with 0x prefix) |
| `RELAY_URL` | No | Relay proxy URL (default: `https://relayer.synctx.ai`) |
| `ETHERSCAN_API_KEY` | No | For ABI fetching from Etherscan |
| `ABI_PROXY_URL` | No | ABI caching proxy URL |
| `CHAIN_RPC_<ID>` | No | Custom RPC URL per chain (e.g. `CHAIN_RPC_8453`) |

## Rules

1. Parse `$ARGUMENTS` and map to the corresponding command.
2. If `PRIVATE_KEY` is missing, automatically run `generate-wallet` to create one and inform the user. Read-only ops (`read`, `list-functions`) don't need it.
3. Read operations execute directly via RPC. **Write operations use Gelato relay when `--gasless gelato` is specified, otherwise send directly (self-pay)**. Check the contract's `gasless` field from the platform to decide.
4. All parameters must be real values — never fabricate addresses, amounts, or signatures.
5. If required parameters are missing, ask the user.
6. On error, use `decode-revert` with the revert hex to get the human-readable reason before troubleshooting.
7. Respond in the user's language.
