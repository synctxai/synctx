import { load } from "@std/dotenv";
import { parseArgs } from "@std/cli";
import { join, dirname, fromFileUrl } from "jsr:@std/path@^1";
import { formatUnits, parseUnits } from "viem";

const skillRoot = join(dirname(fromFileUrl(import.meta.url)), "..");
try {
  await load({ envPath: join(skillRoot, ".env"), export: true });
} catch {
  // .env may not exist
}

import { checkWallet, generateWallet, getAccount } from "./config.ts";
import { balance, read } from "./read.ts";
import { send } from "./send.ts";
import { signMessage, signTypedData } from "./sign.ts";
import { listFunctions } from "./abi.ts";
import { decodeLogs, decodeRevert } from "./decode.ts";
import { getRelayStatus } from "./relay.ts";
import { serialize } from "./abi.ts";

// ---------------------------------------------------------------------------
// Output helpers
// ---------------------------------------------------------------------------

function ok(data: unknown): never {
  console.log(JSON.stringify(serialize(data), null, 2));
  Deno.exit(0);
}

function fail(code: number, message: string): never {
  console.error(JSON.stringify({ error: message }));
  Deno.exit(code);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

const args = parseArgs(Deno.args, {
  string: ["chain", "token", "args", "from", "approve", "value", "decimals", "symbol", "contract", "gasless"],
  boolean: ["dry-run", "help"],
  alias: { h: "help" },
});

const command = args._[0] as string | undefined;

if (!command || args.help) {
  console.log(`Usage: run.ts <command> [options]

Commands:
  check-wallet              Check wallet status
  generate-wallet           Generate a new wallet
  address                   Show wallet address
  balance                   Query ETH + USDC balances
  read CONTRACT SIG         Read contract (view/pure)
  send CONTRACT SIG         Write to contract (gasless via relay or self-pay)
  sign MESSAGE              EIP-191 personal sign
  sign-typed JSON           EIP-712 typed data sign
  list-functions CONTRACT   List contract functions
  decode-logs TX CONTRACT   Decode transaction event logs
  decode-revert HEX_DATA    Decode revert data
  to-raw AMOUNT             Convert human amount to raw
  fmt RAW_AMOUNT            Format raw amount to human
  relay-status TASK_ID      Check Gelato relay task status

Options:
  --chain <id>              Chain ID (default: 8453)
  --args '<json array>'     Function arguments as JSON array
  --from <address>          Caller address for read operations
  --approve TOKEN:AMOUNT    Approve token before send (7702 batch)
  --value <wei>             ETH value to send
  --gasless <provider>      Gasless provider (e.g. "gelato"); omit for self-pay
  --dry-run                 Preview without submitting
  --decimals <n>            Decimals for to-raw/fmt
  --symbol <s>              Symbol for fmt
  --contract <address>      Contract for decode-revert`);
  Deno.exit(0);
}

try {
  switch (command) {
    case "check-wallet": {
      const result = await checkWallet();
      ok(result);
      break;
    }
    case "generate-wallet": {
      const result = await generateWallet();
      ok(result);
      break;
    }
    case "address": {
      const account = getAccount();
      ok({ address: account.address });
      break;
    }

    case "balance": {
      const result = await balance({
        chain: args.chain ? Number(args.chain) : undefined,
        token: args.token,
      });
      ok(result);
      break;
    }

    case "read": {
      const contract = args._[1] as string;
      const sig = args._[2] as string;
      if (!contract || !sig) fail(2, "Usage: read CONTRACT SIG [--args '[...]'] [--chain N]");
      const fnArgs = args.args ? JSON.parse(args.args) as string[] : undefined;
      const result = await read(contract, sig, fnArgs, {
        chain: args.chain ? Number(args.chain) : undefined,
        from: args.from,
      });
      ok(result);
      break;
    }

    case "send": {
      const contract = args._[1] as string;
      const sig = args._[2] as string;
      if (!contract || !sig) fail(2, "Usage: send CONTRACT SIG [--args '[...]'] [--approve TOKEN:AMOUNT] [--dry-run]");
      const fnArgs = args.args ? JSON.parse(args.args) as string[] : undefined;
      const result = await send(contract, sig, fnArgs, {
        chain: args.chain ? Number(args.chain) : undefined,
        value: args.value,
        approve: args.approve,
        dryRun: args["dry-run"],
        gasless: args.gasless,
      });
      ok(result);
      break;
    }

    case "sign": {
      const message = args._[1] as string;
      if (!message) fail(2, "Usage: sign MESSAGE");
      const result = await signMessage(message);
      ok(result);
      break;
    }
    case "sign-typed": {
      const jsonStr = args._[1] as string;
      if (!jsonStr) fail(2, "Usage: sign-typed '<json>'");
      const data = JSON.parse(jsonStr);
      const result = await signTypedData(data);
      ok(result);
      break;
    }

    case "list-functions": {
      const contract = args._[1] as string;
      if (!contract) fail(2, "Usage: list-functions CONTRACT [--chain N]");
      const result = await listFunctions(
        contract,
        args.chain ? Number(args.chain) : 8453,
      );
      ok(result);
      break;
    }

    case "decode-logs": {
      const txHash = args._[1] as string;
      const contract = args._[2] as string;
      if (!txHash || !contract) fail(2, "Usage: decode-logs TX_HASH CONTRACT [--chain N]");
      const result = await decodeLogs(
        txHash,
        contract,
        args.chain ? Number(args.chain) : undefined,
      );
      ok(result);
      break;
    }
    case "decode-revert": {
      const hexData = args._[1] as string;
      if (!hexData) fail(2, "Usage: decode-revert HEX_DATA [--contract 0x...] [--chain N]");
      const result = await decodeRevert(
        hexData,
        args.contract,
        args.chain ? Number(args.chain) : undefined,
      );
      ok(result);
      break;
    }

    case "to-raw": {
      const amount = args._[1] as string;
      const decimals = Number(args.decimals ?? "18");
      if (!amount) fail(2, "Usage: to-raw AMOUNT [--decimals N]");
      const raw = parseUnits(amount, decimals);
      ok({ raw: raw.toString(), amount, decimals });
      break;
    }
    case "fmt": {
      const raw = args._[1] as string;
      const decimals = Number(args.decimals ?? "18");
      const symbol = args.symbol ?? "";
      if (!raw) fail(2, "Usage: fmt RAW_AMOUNT [--decimals N] [--symbol S]");
      const formatted = formatUnits(BigInt(raw), decimals);
      ok({
        formatted: symbol ? `${formatted} ${symbol}` : formatted,
        raw,
        decimals,
        ...(symbol ? { symbol } : {}),
      });
      break;
    }

    case "relay-status": {
      const taskId = args._[1] as string;
      if (!taskId) fail(2, "Usage: relay-status TASK_ID");
      const result = await getRelayStatus(taskId);
      ok(result);
      break;
    }

    default:
      fail(2, `Unknown command: ${command}. Run with --help for usage.`);
  }
} catch (e: unknown) {
  const message = e instanceof Error ? e.message : String(e);
  if (message.includes("PRIVATE_KEY")) {
    fail(4, message);
  } else if (message.includes("fetch") || message.includes("network") || message.includes("ECONNREFUSED")) {
    fail(3, message);
  } else {
    fail(1, message);
  }
}
