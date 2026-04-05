---
name: wallet-deno
description: >-
  Multi-chain EVM wallet. Use when the user needs to query balances, interact
  with smart contracts, or sign messages.
license: MIT
compatibility: Requires Deno 2.x+ and network access
metadata:
  author: synctxai
  version: "1.0"
---

## On Load

```bash
# 0. Check deno is available
if ! command -v deno &>/dev/null; then
  echo '{"error":"deno not found. Install: curl -fsSL https://deno.land/install.sh | sh"}' >&2
  exit 4
fi

# 1. Check wallet status
deno run -P scripts/run.ts check-wallet
# If status is "no_env" or "no_key":
deno run -P scripts/run.ts generate-wallet

# 2. Show address
deno run -P scripts/run.ts address

# 3. Check balances
deno run -P scripts/run.ts balance
```

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
- `createDeal(address,uint96,bytes32)` — write, no return
- `name()->(string)` — no args
- `approve(address,uint256)->(bool)` — bool return

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
deno run -P scripts/run.ts send CONTRACT "accept(uint256)" --args '["42"]' --gasless gelato

# Self-pay
deno run -P scripts/run.ts send CONTRACT "accept(uint256)" --args '["42"]'

# With token approval (gasless, atomic)
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
deno run -P scripts/run.ts send CONTRACT "deposit()" --value 1000000000000000000
```

### Signing

```bash
deno run -P scripts/run.ts sign "hello world"                                    # EIP-191
deno run -P scripts/run.ts sign-typed '{"domain":{...},"types":{...},...}'       # EIP-712
```

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
2. Read operations execute directly via RPC. **Write operations use Gelato relay when `--gasless gelato` is specified, otherwise send directly (self-pay)**. Check the contract's `gasless` field from the platform to decide.
3. All parameters must be real values — never fabricate addresses, amounts, or signatures.
4. If required parameters are missing, ask the user.
5. On error, read the corresponding script source to troubleshoot.
6. Respond in the user's language.
