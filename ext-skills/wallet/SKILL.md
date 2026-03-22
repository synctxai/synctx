---
name: wallet
description: >
  EVM wallet operations — read contract state, send transactions, sign messages,
  query token balances, and interact with any verified smart contract via ABI.
  Use this skill when the task involves blockchain operations such as checking balances,
  querying allowances, approving tokens, calling or invoking smart contracts,
  signing messages (EIP-191/EIP-712), or sending on-chain transactions.
  Also use when the user mentions wallet, ETH, USDC, token balance, contract calls,
  DeFi, on-chain interaction, or transaction signing, even if they don't explicitly
  say "wallet".
compatibility: "Requires Python 3.9+ and uv (https://docs.astral.sh/uv/). Fallback: python3 + pip also works."
metadata:
  author: synctxai
  version: "1.1"
---

# Wallet Skill

Multi-chain EVM wallet: Base (8453, default), Optimism (10), Ethereum (1), Arbitrum (42161). Always pass `--chain 8453` (or omit for Base) unless the user specifies another chain.

## On Load

When this skill is first loaded, **immediately** run `check-wallet` before doing anything else.
Based on the result:

- `"status": "ok"` → Wallet is ready. Proceed with the user's request.
- `"status": "no_env"`, `"status": "no_key"`, or `"status": "invalid_key"` → Automatically run `generate-wallet` to create a new wallet. Then tell the user:
  - The new wallet address
  - The private key storage location (`.env` file next to this SKILL.md)
  - Run `all-balances` to show ETH + USDC balances across all four chains
  - If balances are insufficient, suggest the user transfer ETH (for gas) and USDC (for trading) to the wallet address

> **Warning:** This is a simplified example implementation. The private key is stored in a local `.env` file and is not production-grade secure. Only deposit minimal funds for testing.

## Critical Constraints

1. **NEVER write raw web3.py code.** Do not import `web3` directly, do not use `web3.eth.contract(abi=...)`, do not use `encode_abi()`, do not manually construct ABI encoding. ALL contract interactions MUST go through the `run.py` CLI commands.
2. **NEVER fabricate data.** Addresses, amounts, function signatures — all must come from user input or on-chain queries. If a parameter is unknown, use `list-functions` to discover it or ask the user.
3. **Write operations require user confirmation** (except when overridden by the SyncTx workflow's Special Authorizations). Follow the [Write Operation Workflow](#workflow-write-operations) below.

## Setup

1. Install uv (if not installed): `curl -LsSf https://astral.sh/uv/install.sh | sh`
2. Dependencies are automatically installed on first run via PEP 723.
3. **Wallet**: Run `generate-wallet` to create a new wallet, or set `PRIVATE_KEY=<64 hex chars>` in `.env` (next to SKILL.md) to import an existing one.

## Execution

All commands run from the skill directory root. Use relative paths:

```bash
uv run scripts/run.py <command> [options]
uv run scripts/run.py --help          # List all commands
uv run scripts/run.py <command> --help # Command-specific help
```

If `uv` is unavailable, replace `uv run` with `python3` — `run.py` will auto-install dependencies via pip.

## Quick Reference

### Wallet Setup

```bash
# Check wallet status
uv run scripts/run.py check-wallet

# Generate a new wallet (saves private key to .env)
uv run scripts/run.py generate-wallet
```

### Address & Balance

```bash
uv run scripts/run.py address
uv run scripts/run.py all-balances                # ETH + USDC on all 4 chains
uv run scripts/run.py eth-balance --chain 8453     # single chain ETH
uv run scripts/run.py balance 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85 --chain 8453
```

### Contract Read

```bash
# Discover functions
uv run scripts/run.py list-functions 0x...contract...

# Call read function (use sig from list-functions output)
uv run scripts/run.py call 0x...contract... "balanceOf(address)->(uint256)" --args '["0x...addr..."]' --chain 8453

# msg.sender-dependent functions:
uv run scripts/run.py call 0x...contract... "dealStatus(uint256)->(uint8)" --args '["3"]' --chain 8453 --from 0x...your_addr...
```

### Contract Write

```bash
# Dry run (estimate gas, show details, no execution)
uv run scripts/run.py invoke 0x...contract... "accept(uint256)" --args '["3"]' --chain 8453 --dry-run

# Execute
uv run scripts/run.py invoke 0x...contract... "accept(uint256)" --args '["3"]' --chain 8453
```

### ERC20 Operations

```bash
uv run scripts/run.py balance 0x...token... --chain 8453
uv run scripts/run.py approve 0x...token... 0x...spender... 1000000 --chain 8453
uv run scripts/run.py approve-and-invoke 0x...token... 0x...contract... 1000000 "createDeal(...)" --args '[...]' --chain 8453
```

### Signing

```bash
uv run scripts/run.py sign-message "hello world"
uv run scripts/run.py sign-typed-data '{"types":...}'
```

### Event Logs

```bash
uv run scripts/run.py decode-logs 0x...tx_hash... 0x...contract... --chain 8453
```

## Workflow: Unknown Contract Interaction

1. `list-functions 0x...contract...` → discover all function signatures
2. Find the target function sig from output
3. Read: `call addr sig --args [...]` / Write: `invoke addr sig --args [...]`
4. After write: `decode-logs tx_hash contract_addr` to extract event data
5. On failure: error message contains human-readable revert reason automatically

## Workflow: Write Operations

Write operations are irreversible on-chain transactions. Follow this sequence:

1. **Preview**: Run `invoke` with `--dry-run` to estimate gas and preview transaction details
2. **Confirm**: Present to user: target contract, function, args, estimated gas cost
3. **Execute**: Run `invoke` without `--dry-run` after user confirmation
4. **Verify**: Run `decode-logs` on the tx_hash to confirm expected events were emitted
5. **On failure**: The error message auto-includes decoded revert reason — report it to user

Exception: when the SyncTx workflow's Special Authorizations override confirmation (steps 2-3 are skipped).

## Error Handling

Errors output structured JSON to stderr with `error`, `detail`, and `exit_code` fields.
Exit codes: 0=success, 1=bad args, 2=contract revert, 3=network error, 4=config error.
Read the `detail` field to decide next steps.

## Further Reading

- [references/api.md](references/api.md) — complete function signatures, parameter types, sig format, `-c` advanced mode
- Run `<command> --help` for command-specific parameters

## Rules

1. If `PRIVATE_KEY` is missing, automatically run `generate-wallet` to create one and inform the user. Read-only ops (`call`, `list-functions`) don't need it.
2. On error, read the `detail` field from stderr JSON to troubleshoot.
3. Respond in the user's language.
