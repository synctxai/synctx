import {
  decodeErrorResult,
  decodeEventLog,
  type Abi,
  type Log,
  hexToString,
} from "viem";
import { getPublicClient, resolveChainId } from "./config.ts";
import { loadAbi, serialize } from "./abi.ts";

// ---------------------------------------------------------------------------
// decode-revert
// ---------------------------------------------------------------------------

const ERROR_ABI = [
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

export async function decodeRevert(
  data: string,
  contract?: string,
  chainId?: number,
): Promise<{
  error: string;
  args?: unknown;
  raw: string;
}> {
  const hex = data as `0x${string}`;
  const resolvedChain = resolveChainId(chainId);

  if (contract) {
    try {
      const abi = await loadAbi(contract, resolvedChain);
      const decoded = decodeErrorResult({ abi, data: hex });
      return {
        error: decoded.errorName,
        args: serialize(decoded.args),
        raw: data,
      };
    } catch {
      // fall through
    }
  }

  try {
    const decoded = decodeErrorResult({ abi: ERROR_ABI, data: hex });
    return {
      error: decoded.errorName,
      args: serialize(decoded.args),
      raw: data,
    };
  } catch {
    // fall through
  }

  if (hex.length > 10) {
    try {
      const text = hexToString(hex);
      if (text && /[\x20-\x7e]/.test(text)) {
        return { error: "RawMessage", args: text.replace(/\0/g, "").trim(), raw: data };
      }
    } catch {
      // ignore
    }
  }

  return { error: "Unknown", raw: data };
}

// ---------------------------------------------------------------------------
// decode-logs
// ---------------------------------------------------------------------------

interface DecodedLog {
  eventName: string;
  args: unknown;
  address: string;
  logIndex: number;
  transactionIndex: number;
}

export async function decodeLogs(
  txHash: string,
  contract: string,
  chainId?: number,
): Promise<DecodedLog[]> {
  const resolvedChain = resolveChainId(chainId);
  const client = getPublicClient(resolvedChain);

  const receipt = await client.getTransactionReceipt({
    hash: txHash as `0x${string}`,
  });

  let abi: Abi;
  try {
    abi = await loadAbi(contract, resolvedChain);
  } catch {
    return receipt.logs
      .filter(
        (log: Log) =>
          log.address.toLowerCase() === contract.toLowerCase(),
      )
      .map((log: Log) => ({
        eventName: "Unknown",
        args: { topics: log.topics, data: log.data },
        address: log.address,
        logIndex: log.logIndex,
        transactionIndex: log.transactionIndex,
      }));
  }

  const decoded: DecodedLog[] = [];
  for (const log of receipt.logs) {
    if (log.address.toLowerCase() !== contract.toLowerCase()) continue;
    try {
      const event = decodeEventLog({
        abi,
        data: log.data,
        topics: log.topics,
      });
      decoded.push({
        eventName: event.eventName,
        args: serialize(event.args),
        address: log.address,
        logIndex: log.logIndex,
        transactionIndex: log.transactionIndex,
      });
    } catch {
      decoded.push({
        eventName: "Unknown",
        args: { topics: log.topics, data: log.data },
        address: log.address,
        logIndex: log.logIndex,
        transactionIndex: log.transactionIndex,
      });
    }
  }

  return decoded;
}
