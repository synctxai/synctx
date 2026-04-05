---
name: wallet-bun
description: >
  Bun + viem wallet skill — read contract state, send direct EVM transactions,
  sign messages, query balances, and submit gasless writes through Gelato 7702.
compatibility: "Requires Bun 1.3+."
metadata:
  author: synctxai
  version: "0.1"
---

# Wallet Skill (Bun)

Single-entry EVM wallet skill for local private-key agents.

- Chains: Base (`8453`, default), Optimism (`10`), Ethereum (`1`), Arbitrum (`42161`)
- Runtime: Bun 1.3+
- Entry: `bun scripts/run.ts <command> [options]`

## On Load

Run these commands from the skill root:

```bash
bun scripts/run.ts check-wallet
```

If the wallet is missing or invalid:

```bash
bun scripts/run.ts generate-wallet
```

Then show the address and balances:

```bash
bun scripts/run.ts address
bun scripts/run.ts all-balances
```

## Setup

Install dependencies once:

```bash
bun install
```

Then either:

1. Run `bun scripts/run.ts generate-wallet`, or
2. Copy `.env.example` to `.env` and set `PRIVATE_KEY=...`

## Execution

Always use the single entry:

```bash
bun scripts/run.ts <command> [options]
```

Examples:

```bash
# Address and balances
bun scripts/run.ts address
bun scripts/run.ts eth-balance --chain 8453
bun scripts/run.ts balance 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 --chain 8453
bun scripts/run.ts all-balances

# Discover and read contracts
bun scripts/run.ts list-functions 0x...contract... --chain 8453
bun scripts/run.ts call 0x...contract... "name()->(string)" --chain 8453
bun scripts/run.ts call 0x...contract... "dealStatus(uint256)->(uint8)" --args '["3"]' --from 0x...addr... --chain 8453

# Direct writes
bun scripts/run.ts invoke 0x...contract... "accept(uint256)" --args '["3"]' --chain 8453 --dry-run
bun scripts/run.ts invoke 0x...contract... "accept(uint256)" --args '["3"]' --chain 8453
bun scripts/run.ts approve 0x...token... 0x...spender... 1000000 --chain 8453

# Gasless writes
bun scripts/run.ts gelato-relay 0x...contract... "accept(uint256)" --args '["3"]' --chain 8453
bun scripts/run.ts gelato-relay 0x...contract... "createDeal(...)" --args '[...]' --approve-token 0x...USDC... --approve-amount 1000000 --chain 8453
bun scripts/run.ts gelato-status 0xtask_id...

# Signing and helpers
bun scripts/run.ts sign-message "hello world"
bun scripts/run.ts sign-typed-data '{"domain":{...},"types":{...},"primaryType":"Mail","message":{...}}'
bun scripts/run.ts to-raw 1.5 --decimals 6
bun scripts/run.ts fmt 1500000 --decimals 6 --symbol USDC
```

## Rules

1. If `PRIVATE_KEY` is missing, run `generate-wallet` instead of asking the user to hand-edit files.
2. Prefer `gelato-relay` on supported production chains; use `invoke` for local/dev chains.
3. Do not fabricate addresses, amounts, signatures, or ABI signatures.
4. All write operations are real on-chain actions; preview with `invoke --dry-run` when needed.
5. Errors are emitted as structured JSON on stderr.
