import { decodeErrorResult, decodeEventLog, type Abi, type Hex } from "viem";
import { getPublicClient, resolveChainId } from "./config.ts";
import { loadAbi, serialize } from "./abi.ts";

const STANDARD_ERROR_ABI = [
  {
    type: "error" as const,
    name: "Error",
    inputs: [{ name: "message", type: "string" }],
  },
  {
    type: "error" as const,
    name: "Panic",
    inputs: [{ name: "code", type: "uint256" }],
  },
] as const;

function formatCustomError(errorName: string, args: unknown): string {
  if (Array.isArray(args)) {
    return `${errorName}(${args.map((value) => String(serialize(value))).join(", ")})`;
  }
  if (args && typeof args === "object") {
    const entries = Object.entries(args).map(([key, value]) => `${key}=${String(serialize(value))}`);
    return `${errorName}(${entries.join(", ")})`;
  }
  if (args == null) return `${errorName}()`;
  return `${errorName}(${String(serialize(args))})`;
}

export async function decodeRevert(
  data: string,
  contractAddress?: string,
  chainId: number = resolveChainId(),
): Promise<string> {
  const hex = data as Hex;

  if (contractAddress) {
    try {
      const abi = await loadAbi(contractAddress, chainId);
      const decoded = decodeErrorResult({ abi, data: hex });
      if (decoded.errorName === "Error") {
        return `Error: ${String((decoded.args as unknown[])[0] ?? "")}`;
      }
      if (decoded.errorName === "Panic") {
        const code = BigInt((decoded.args as unknown[])[0] as bigint);
        const reasons: Record<string, string> = {
          "1": "assertion failed",
          "17": "overflow",
          "18": "division by zero",
          "33": "invalid enum",
          "50": "out of bounds",
          "65": "out of memory",
        };
        return `Panic: ${reasons[code.toString()] ?? `code ${code.toString()}`}`;
      }
      return formatCustomError(decoded.errorName, decoded.args);
    } catch {
      // Fall through to standard errors.
    }
  }

  try {
    const decoded = decodeErrorResult({ abi: STANDARD_ERROR_ABI, data: hex });
    if (decoded.errorName === "Error") {
      return `Error: ${String((decoded.args as readonly unknown[])[0] ?? "")}`;
    }
    const code = BigInt((decoded.args as readonly unknown[])[0] as bigint);
    const reasons: Record<string, string> = {
      "1": "assertion failed",
      "17": "overflow",
      "18": "division by zero",
      "33": "invalid enum",
      "50": "out of bounds",
      "65": "out of memory",
    };
    return `Panic: ${reasons[code.toString()] ?? `code ${code.toString()}`}`;
  } catch {
    return `Unknown error: ${data}`;
  }
}

export async function decodeLogs(
  txHash: string,
  contractAddress: string,
  chainId: number = resolveChainId(),
): Promise<Array<Record<string, unknown>>> {
  const client = getPublicClient(chainId);
  const receipt = await client.getTransactionReceipt({ hash: txHash as Hex });

  let abi: Abi;
  try {
    abi = await loadAbi(contractAddress, chainId);
  } catch {
    return receipt.logs
      .filter((log) => log.address.toLowerCase() === contractAddress.toLowerCase())
      .map((log) => ({
        event: "Unknown",
        address: log.address,
        topics: log.topics,
        data: log.data,
      }));
  }

  const decoded: Array<Record<string, unknown>> = [];
  for (const log of receipt.logs) {
    if (log.address.toLowerCase() !== contractAddress.toLowerCase()) continue;
    try {
      const event = decodeEventLog({
        abi,
        topics: log.topics,
        data: log.data,
      });
      const serializedArgs = serialize(event.args);
      if (serializedArgs && typeof serializedArgs === "object" && !Array.isArray(serializedArgs)) {
        decoded.push({ event: event.eventName, ...(serializedArgs as Record<string, unknown>) });
      } else {
        decoded.push({ event: event.eventName, args: serializedArgs });
      }
    } catch {
      decoded.push({
        event: "Unknown",
        address: log.address,
        topics: log.topics,
        data: log.data,
      });
    }
  }

  return decoded;
}
