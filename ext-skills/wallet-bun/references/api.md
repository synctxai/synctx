# Wallet Bun API Reference

Entry:

```bash
bun scripts/run.ts <command> [options]
```

## Setup

| Command | Description |
|---|---|
| `check-wallet` | Check wallet config status |
| `generate-wallet` | Generate a new wallet and write `.env` |
| `address` | Print the wallet address |

## Balance

| Command | Returns |
|---|---|
| `eth-balance --chain <id>` | `{address, chain_id, balance_raw, balance}` |
| `balance <token> [--owner <addr>] [--chain <id>]` | `{raw, formatted, symbol, decimals}` |
| `all-balances` | `{address, chains: {...}}` |

## Contract Interaction

| Command | Returns |
|---|---|
| `list-functions <contract> [--chain <id>]` | `{read: [...], write: [...]}` |
| `call <contract> <sig> [--args '<json>'] [--chain <id>] [--from <addr>]` | decoded read result |
| `invoke <contract> <sig> [--args '<json>'] [--chain <id>] [--value <wei>] [--dry-run]` | dry-run preview or tx receipt |
| `approve <token> <spender> <amount> [--chain <id>]` | tx receipt or `null` if allowance already sufficient |
| `approve-and-invoke <token> <contract> <amount> <sig> [--args '<json>'] [--chain <id>] [--value <wei>]` | final tx receipt |

## Gelato 7702

| Command | Returns |
|---|---|
| `gelato-relay <contract> <sig> [--args '<json>'] [--approve-token <addr>] [--approve-amount <raw>] [--chain <id>] [--sync] [--timeout <ms>]` | `{taskId,...}` or included receipt result |
| `gelato-status <taskId>` | `{taskId, status, txHash, blockNumber, ...}` |

## Signing

| Command | Returns |
|---|---|
| `sign-message <message>` | `{address, message, signature}` |
| `sign-typed-data <json-or-file>` | `{address, signature}` |

## Decode and Utility

| Command | Returns |
|---|---|
| `decode-logs <txHash> <contract> [--chain <id>]` | `list[dict]` |
| `decode-revert <data> [--contract <addr>] [--chain <id>]` | decoded revert string |
| `to-raw <amount> [--decimals <n>]` | raw integer string |
| `fmt <raw> [--decimals <n>] [--symbol <sym>]` | formatted amount string |

## Signature Format

Function signatures follow the existing wallet convention:

```text
name(inputTypes)->(outputTypes)
```

Examples:

- `balanceOf(address)->(uint256)`
- `name()->(string)`
- `accept(uint256)`

Arguments are passed separately through `--args '<json array>'`.

## Error Output

Errors are written to stderr as JSON:

```json
{"error":"ContractRevert","detail":"Transaction would revert: Error: InsufficientBalance","exit_code":2}
```

Exit codes:

- `0` success
- `1` bad args
- `2` contract revert
- `3` network/runtime error
- `4` wallet config error
