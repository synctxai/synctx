# API Quick Reference

```bash
W="deno run --allow-net --allow-env --allow-read --allow-write scripts/run.ts"
```

## Commands

| Command | Positional Args | Key Options |
|---------|----------------|-------------|
| `check-wallet` | — | — |
| `generate-wallet` | — | — |
| `address` | — | — |
| `balance` | — | `--chain`, `--token` |
| `read` | CONTRACT SIG | `--args`, `--chain`, `--from` |
| `send` | CONTRACT SIG | `--args`, `--chain`, `--approve`, `--value`, `--dry-run` |
| `sign` | MESSAGE | — |
| `sign-typed` | JSON | — |
| `list-functions` | CONTRACT | `--chain` |
| `decode-logs` | TX_HASH CONTRACT | `--chain` |
| `decode-revert` | HEX_DATA | `--contract`, `--chain` |
| `to-raw` | AMOUNT | `--decimals` |
| `fmt` | RAW_AMOUNT | `--decimals`, `--symbol` |
| `relay-status` | TASK_ID | — |

## Option Details

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `--chain` | number | 8453 | Chain ID |
| `--args` | JSON array | — | Function arguments: `'["0x...", "42"]'` |
| `--from` | address | — | Caller for read (msg.sender-dependent views) |
| `--approve` | TOKEN:AMOUNT | — | Atomic approve batch: `0xUSDC:1000000` |
| `--value` | string | "0" | ETH value in wei |
| `--dry-run` | flag | false | Preview without submitting |
| `--decimals` | number | 18 | Decimal places for to-raw/fmt |
| `--symbol` | string | — | Token symbol for fmt display |
| `--token` | address | — | ERC20 address for balance query |
| `--contract` | address | — | Contract for decode-revert ABI lookup |

## USDC Addresses

| Chain | ID | USDC Address |
|-------|-----|-------------|
| Ethereum | 1 | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| Optimism | 10 | `0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85` |
| Base | 8453 | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Arbitrum | 42161 | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` |

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Runtime error |
| 2 | Invalid arguments |
| 3 | Network error |
| 4 | Wallet not configured |