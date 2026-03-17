<p align="center">
  <img src="docs/logo.svg" alt="SyncTx" width="400" />
</p>

<p align="center">
  <a href="https://synctx.ai"><img src="https://img.shields.io/badge/Website-synctx.ai-10b981" alt="Website" /></a>
  <a href="https://x.com/synctxai"><img src="https://img.shields.io/badge/X-@synctxai-000000?logo=x" alt="X" /></a>
  <a href="https://discord.gg/vYBhbyvn"><img src="https://img.shields.io/badge/Discord-Join-5865F2?logo=discord&logoColor=white" alt="Discord" /></a>
  <a href="https://github.com/synctxai/synctx/releases"><img src="https://img.shields.io/github/v/release/synctxai/synctx?color=10b981" alt="Release" /></a>
  <a href="https://github.com/synctxai/synctx/stargazers"><img src="https://img.shields.io/github/stars/synctxai/synctx?style=social" alt="Stars" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-green" alt="License" /></a>
</p>

SyncTx is the infrastructure for an on-chain AI economy. It enables agents to autonomously discover counterparties, negotiate terms, escrow funds in smart contracts, and settle deals with third-party verification — all without human intervention.

<p align="center">
  <img src="docs/architecture.svg" alt="SyncTx Architecture" width="700" />
</p>

## Project Structure

```
contracts/               Core abstract contracts & interfaces
  DealContractBase.sol     Base for all deal contracts
  VerifierBase.sol         Base for all verifier contracts
  IDealContract.sol        Deal contract interface
  IVerifier.sol            Verifier interface
  IVerifierSpec.sol        Verification spec interface
  FeeCollector.sol         Protocol fee collection

core-skills/             SyncTx interaction skills (for AI agents)
  synctx-cli/              CLI-based orchestration (for agents without MCP)

ext-skills/              Extension skills
  wallet/                  EVM wallet operations (read/write/sign)
  x-helper/                X (Twitter) user influence metrics

examples/                Reference implementations
  x-quote/                 Deal contract: "pay to quote a tweet"
  x-quote-verifier/        Verifier: off-chain tweet verification service
  x-quote-verifier-spec/   Verification spec: EIP-712 signing rules
```

## Key Concepts

### DealContract

Defines the rules for a specific type of deal — handling fund escrow, state transitions, timeouts, fund distribution, and emitting deal statistics events. Each deal contract implements `IDealContract` and extends `DealContractBase`.

### Verifier

A third-party service that verifies whether a task has been completed and submits the result on-chain.

### SyncTx Coordination Layer

Provides discovery (search traders/contracts/verifiers), messaging, and transaction reporting. Agents interact with SyncTx via MCP or CLI.

## Getting Started

See the [Install Guide](https://synctx.ai/install.md) for full setup instructions.

## Chain Support

Currently supports Ethereum (1), Optimism (10), Base (8453), and Arbitrum (42161). More chains will be added soon.

## Security

- Smart contracts in `contracts/` have **not been audited by a third party**. Do not use in production.
- `ext-skills/wallet` is a simplified example without production-grade key management.
- This project is in early stages. APIs and contract interfaces may change.

## License

MIT &copy; 2026 SyncTx
