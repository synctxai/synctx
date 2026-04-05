#!/usr/bin/env bun

import { existsSync, readFileSync } from "node:fs";
import { parseArgs } from "node:util";
import { formatUnits, parseUnits } from "viem";
import { listFunctions, serialize } from "./abi.ts";
import { checkWallet, envPath, generateWallet, getAccount, resolveChainId } from "./config.ts";
import { decodeLogs, decodeRevert } from "./decode.ts";
import { gelatoRelay, getRelayStatus } from "./gelato.ts";
import { allBalances, callContract, ethBalance, tokenBalance } from "./read.ts";
import { approve, approveAndInvoke, approvePreview, invoke } from "./send.ts";

function out(data: unknown): void {
  if (typeof data === "string" || typeof data === "number" || typeof data === "boolean") {
    console.log(String(data));
  } else {
    console.log(JSON.stringify(serialize(data), null, 2));
  }
  process.exit(0);
}

function fail(error: string, detail: string, exitCode: number): void {
  console.error(JSON.stringify({ error, detail, exit_code: exitCode }));
  process.exit(exitCode);
}

function parseJsonArgs(raw?: string): unknown[] {
  if (!raw) return [];
  const parsed = JSON.parse(raw);
  if (!Array.isArray(parsed)) {
    throw new Error("--args must be a JSON array");
  }
  return parsed;
}

function readTypedDataInput(raw: string): unknown {
  if ((raw.startsWith("{") && raw.endsWith("}")) || (raw.startsWith("[") && raw.endsWith("]"))) {
    return JSON.parse(raw);
  }
  if (existsSync(raw)) {
    return JSON.parse(readFileSync(raw, "utf8"));
  }
  return JSON.parse(raw);
}

function usage(): string {
  return `Usage:
  bun scripts/run.ts <command> [options]

Commands:
  check-wallet
  generate-wallet
  address
  eth-balance           --chain <id>
  balance               <token> [--owner <address>] [--chain <id>]
  all-balances
  list-functions        <contract-or-abi> [--chain <id>]
  call                  <contract> <sig> [--args '<json>'] [--chain <id>] [--from <address>]
  invoke                <contract> <sig> [--args '<json>'] [--chain <id>] [--value <wei>] [--dry-run]
  approve               <token> <spender> <amount> [--chain <id>]
  approve-and-invoke    <token> <contract> <amount> <sig> [--args '<json>'] [--chain <id>] [--value <wei>]
  gelato-relay          <contract> <sig> [--args '<json>'] [--approve-token <addr>] [--approve-amount <raw>] [--chain <id>] [--sync] [--timeout <ms>]
  gelato-status         <taskId>
  sign-message          <message>
  sign-typed-data       <json-or-file>
  decode-logs           <txHash> <contract> [--chain <id>]
  decode-revert         <data> [--contract <addr>] [--chain <id>]
  to-raw                <amount> [--decimals <n>]
  fmt                   <raw> [--decimals <n>] [--symbol <sym>]
`;
}

const { positionals, values } = parseArgs({
  args: process.argv.slice(2),
  allowPositionals: true,
  strict: false,
  options: {
    args: { type: "string" },
    owner: { type: "string" },
    chain: { type: "string" },
    from: { type: "string" },
    value: { type: "string" },
    contract: { type: "string" },
    symbol: { type: "string" },
    decimals: { type: "string" },
    "approve-token": { type: "string" },
    "approve-amount": { type: "string" },
    timeout: { type: "string" },
    help: { type: "boolean", short: "h" },
    "dry-run": { type: "boolean" },
    sync: { type: "boolean" },
  },
});

const command = positionals[0];
if (!command || values.help) {
  console.log(usage());
  process.exit(0);
}

function stringOption(name: keyof typeof values): string | undefined {
  const value = values[name];
  return typeof value === "string" ? value : undefined;
}

function booleanOption(name: keyof typeof values): boolean {
  return values[name] === true;
}

async function main() {
  switch (command) {
    case "check-wallet":
      out(checkWallet());
      return;
    case "generate-wallet":
      out(generateWallet());
      return;
    case "address":
      out(getAccount().address);
      return;
    case "eth-balance":
      out(await ethBalance(resolveChainId(stringOption("chain"))));
      return;
    case "balance": {
      const token = positionals[1];
      if (!token) fail("BadArgs", "Usage: balance <token> [--owner <address>] [--chain <id>]", 1);
      out(await tokenBalance(token, stringOption("owner"), resolveChainId(stringOption("chain"))));
      return;
    }
    case "all-balances":
      out(await allBalances());
      return;
    case "list-functions": {
      const contract = positionals[1];
      if (!contract) fail("BadArgs", "Usage: list-functions <contract-or-abi> [--chain <id>]", 1);
      out(await listFunctions(contract, resolveChainId(stringOption("chain"))));
      return;
    }
    case "call": {
      const contract = positionals[1];
      const sig = positionals[2];
      if (!contract || !sig) fail("BadArgs", "Usage: call <contract> <sig> [--args '<json>'] [--chain <id>] [--from <address>]", 1);
      out(await callContract(contract, sig, parseJsonArgs(stringOption("args")), {
        chainId: resolveChainId(stringOption("chain")),
        from: stringOption("from"),
      }));
      return;
    }
    case "invoke": {
      const contract = positionals[1];
      const sig = positionals[2];
      if (!contract || !sig) fail("BadArgs", "Usage: invoke <contract> <sig> [--args '<json>'] [--chain <id>] [--value <wei>] [--dry-run]", 1);
      out(await invoke(contract, sig, parseJsonArgs(stringOption("args")), {
        chainId: resolveChainId(stringOption("chain")),
        value: BigInt(stringOption("value") ?? "0"),
        dryRun: booleanOption("dry-run"),
      }));
      return;
    }
    case "approve": {
      const token = positionals[1];
      const spender = positionals[2];
      const amount = positionals[3];
      if (!token || !spender || !amount) fail("BadArgs", "Usage: approve <token> <spender> <amount> [--chain <id>]", 1);
      out(await approve(token, spender, amount, resolveChainId(stringOption("chain"))));
      return;
    }
    case "approve-and-invoke": {
      const token = positionals[1];
      const contract = positionals[2];
      const amount = positionals[3];
      const sig = positionals[4];
      if (!token || !contract || !amount || !sig) {
        fail("BadArgs", "Usage: approve-and-invoke <token> <contract> <amount> <sig> [--args '<json>'] [--chain <id>] [--value <wei>]", 1);
      }
      out(await approveAndInvoke(token, contract, amount, sig, parseJsonArgs(stringOption("args")), {
        chainId: resolveChainId(stringOption("chain")),
        value: BigInt(stringOption("value") ?? "0"),
      }));
      return;
    }
    case "gelato-relay": {
      const contract = positionals[1];
      const sig = positionals[2];
      if (!contract || !sig) {
        fail("BadArgs", "Usage: gelato-relay <contract> <sig> [--args '<json>'] [--approve-token <addr>] [--approve-amount <raw>] [--chain <id>] [--sync] [--timeout <ms>]", 1);
      }
      out(await gelatoRelay(contract, sig, parseJsonArgs(stringOption("args")), {
        chainId: resolveChainId(stringOption("chain")),
        approveToken: stringOption("approve-token"),
        approveAmount: BigInt(stringOption("approve-amount") ?? "0"),
        sync: booleanOption("sync"),
        timeoutMs: Number(stringOption("timeout") ?? "30000"),
      }));
      return;
    }
    case "gelato-status": {
      const taskId = positionals[1];
      if (!taskId) fail("BadArgs", "Usage: gelato-status <taskId>", 1);
      out(await getRelayStatus(taskId));
      return;
    }
    case "sign-message": {
      const message = positionals[1];
      if (!message) fail("BadArgs", "Usage: sign-message <message>", 1);
      out({
        address: getAccount().address,
        message,
        signature: await getAccount().signMessage({ message }),
      });
      return;
    }
    case "sign-typed-data": {
      const input = positionals[1];
      if (!input) fail("BadArgs", "Usage: sign-typed-data <json-or-file>", 1);
      const typedData = readTypedDataInput(input) as {
        domain: Record<string, unknown>;
        types: Record<string, Array<{ name: string; type: string }>>;
        primaryType: string;
        message: Record<string, unknown>;
      };
      out({
        address: getAccount().address,
        signature: await getAccount().signTypedData(typedData),
      });
      return;
    }
    case "decode-logs": {
      const txHash = positionals[1];
      const contract = positionals[2];
      if (!txHash || !contract) fail("BadArgs", "Usage: decode-logs <txHash> <contract> [--chain <id>]", 1);
      out(await decodeLogs(txHash, contract, resolveChainId(stringOption("chain"))));
      return;
    }
    case "decode-revert": {
      const data = positionals[1];
      if (!data) fail("BadArgs", "Usage: decode-revert <data> [--contract <addr>] [--chain <id>]", 1);
      out(await decodeRevert(data, stringOption("contract"), resolveChainId(stringOption("chain"))));
      return;
    }
    case "to-raw": {
      const amount = positionals[1];
      if (!amount) fail("BadArgs", "Usage: to-raw <amount> [--decimals <n>]", 1);
      out(parseUnits(amount, Number(stringOption("decimals") ?? "18")).toString());
      return;
    }
    case "fmt": {
      const raw = positionals[1];
      if (!raw) fail("BadArgs", "Usage: fmt <raw> [--decimals <n>] [--symbol <sym>]", 1);
      const formatted = formatUnits(BigInt(raw), Number(stringOption("decimals") ?? "18"));
      const symbol = stringOption("symbol");
      out(symbol ? `${formatted} ${symbol}` : formatted);
      return;
    }
    default:
      fail("BadArgs", `Unknown command: ${command}`, 1);
  }
}

void main().catch(async (error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  if (message.includes("Transaction would revert")) {
    fail("ContractRevert", message, 2);
  }
  if (message.includes("PRIVATE_KEY") || message.includes(envPath())) {
    fail("ConfigError", message, 4);
  }
  if (
    message.includes("fetch") ||
    message.includes("network") ||
    message.includes("Relay") ||
    message.includes("Status query failed") ||
    message.includes("ECONNREFUSED")
  ) {
    fail("NetworkError", message, 3);
  }
  fail("Error", message, 3);
});
