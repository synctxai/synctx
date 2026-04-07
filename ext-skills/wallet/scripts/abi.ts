import {
  encodeFunctionData,
  decodeFunctionResult,
  type Abi,
  type AbiFunction,
  parseAbiItem,
} from "viem";
import { join } from "jsr:@std/path@^1";
import { skillDir } from "./config.ts";

// ---------------------------------------------------------------------------
// Sig parsing: "name(types)->(returns)"
// ---------------------------------------------------------------------------

export interface ParsedSig {
  name: string;
  inputTypes: string[];
  outputTypes: string[];
  abi: AbiFunction;
}

export function parseSig(sig: string): ParsedSig {
  // Split on "->" for return types
  const [funcPart, returnPart] = sig.split("->");
  const match = funcPart.match(/^(\w+)\(([^)]*)\)$/);
  if (!match) throw new Error(`Invalid signature: ${sig}`);

  const name = match[1];
  const inputTypes = match[2] ? match[2].split(",").map((s) => s.trim()) : [];

  let outputTypes: string[] = [];
  if (returnPart) {
    const retMatch = returnPart.trim().match(/^\(([^)]*)\)$/);
    if (retMatch) {
      outputTypes = retMatch[1] ? retMatch[1].split(",").map((s) => s.trim()) : [];
    } else {
      outputTypes = [returnPart.trim()];
    }
  }

  // Build ABI item string for viem
  const inputParams = inputTypes
    .map((t, i) => `${t} arg${i}`)
    .join(", ");
  const outputParams = outputTypes.length
    ? ` returns (${outputTypes.map((t, i) => `${t} out${i}`).join(", ")})`
    : "";
  const abiString = `function ${name}(${inputParams})${outputParams}`;
  const abi = parseAbiItem(abiString) as AbiFunction;

  return { name, inputTypes, outputTypes, abi };
}

// ---------------------------------------------------------------------------
// Argument conversion
// ---------------------------------------------------------------------------

export function convertArg(value: string, type: string): unknown {
  if (type === "bool") {
    return value === "true" || value === "1";
  }
  if (type === "address") {
    return value as `0x${string}`;
  }
  if (type.startsWith("uint") || type.startsWith("int")) {
    return BigInt(value);
  }
  if (type.startsWith("bytes") && type !== "bytes") {
    // fixed-size bytes: pass as-is (hex string)
    return value as `0x${string}`;
  }
  if (type === "bytes") {
    return value as `0x${string}`;
  }
  if (type.endsWith("[]")) {
    const inner = type.slice(0, -2);
    const arr = JSON.parse(value) as string[];
    return arr.map((v) => convertArg(String(v), inner));
  }
  if (type.startsWith("tuple")) {
    return JSON.parse(value);
  }
  return value;
}

function convertArgs(
  args: string[] | undefined,
  types: string[],
): unknown[] {
  if (!args || args.length === 0) return [];
  return args.map((a, i) => convertArg(a, types[i]));
}

// ---------------------------------------------------------------------------
// Calldata encoding
// ---------------------------------------------------------------------------

export function encodeCalldata(
  sig: string,
  args?: string[],
): `0x${string}` {
  const parsed = parseSig(sig);
  const converted = convertArgs(args, parsed.inputTypes);
  return encodeFunctionData({
    abi: [parsed.abi],
    functionName: parsed.name,
    args: converted,
  });
}

export function decodeResult(sig: string, data: `0x${string}`): unknown {
  const parsed = parseSig(sig);
  return decodeFunctionResult({
    abi: [parsed.abi],
    functionName: parsed.name,
    data,
  });
}

// ---------------------------------------------------------------------------
// Serialization (bigint-safe)
// ---------------------------------------------------------------------------

export function serialize(value: unknown): unknown {
  if (typeof value === "bigint") return value.toString();
  if (Array.isArray(value)) return value.map(serialize);
  if (value && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value)) {
      out[k] = serialize(v);
    }
    return out;
  }
  return value;
}

// ---------------------------------------------------------------------------
// ABI loading / caching
// ---------------------------------------------------------------------------

function cacheDir(): string {
  return join(skillDir(), "abis");
}

function cachePath(chainId: number, address: string): string {
  return join(cacheDir(), String(chainId), `${address.toLowerCase()}.json`);
}

async function readCache(
  chainId: number,
  address: string,
): Promise<Abi | null> {
  try {
    const text = await Deno.readTextFile(cachePath(chainId, address));
    const data = JSON.parse(text);
    return Array.isArray(data) ? data : data.abi ?? null;
  } catch {
    return null;
  }
}

async function writeCache(
  chainId: number,
  address: string,
  abi: Abi,
): Promise<void> {
  const path = cachePath(chainId, address);
  const dir = join(cacheDir(), String(chainId));
  await Deno.mkdir(dir, { recursive: true });
  await Deno.writeTextFile(path, JSON.stringify(abi, null, 2));
}

async function fetchFromAbiProxy(
  address: string,
  chainId: number,
): Promise<Abi | null> {
  const proxyUrl = Deno.env.get("ABI_PROXY_URL");
  if (!proxyUrl) return null;
  try {
    const url = `${proxyUrl}/abi/${chainId}/${address}`;
    const res = await fetch(url);
    if (!res.ok) return null;
    const json = await res.json();
    // abi-proxy returns Etherscan-compatible format
    if (json.status === "1" && json.result) {
      return typeof json.result === "string"
        ? JSON.parse(json.result)
        : json.result;
    }
    return null;
  } catch {
    return null;
  }
}

async function fetchFromSourcify(
  address: string,
  chainId: number,
): Promise<Abi | null> {
  try {
    const url = `https://sourcify.dev/server/files/any/${chainId}/${address}`;
    const res = await fetch(url);
    if (!res.ok) return null;
    const json = await res.json();
    if (json.files) {
      const metadata = json.files.find(
        (f: { name: string }) => f.name === "metadata.json",
      );
      if (metadata) {
        const meta = JSON.parse(metadata.content);
        const output = meta.output;
        if (output?.abi) return output.abi;
      }
    }
    return null;
  } catch {
    return null;
  }
}

async function fetchFromEtherscan(
  address: string,
  chainId: number,
): Promise<Abi | null> {
  const apiKey = Deno.env.get("ETHERSCAN_API_KEY");
  if (!apiKey) return null;
  try {
    const url =
      `https://api.etherscan.io/v2/api?chainid=${chainId}&module=contract&action=getabi&address=${address}&apikey=${apiKey}`;
    const res = await fetch(url);
    if (!res.ok) return null;
    const json = await res.json();
    if (json.status === "1" && json.result) {
      return JSON.parse(json.result);
    }
    return null;
  } catch {
    return null;
  }
}

export async function loadAbi(
  address: string,
  chainId: number,
): Promise<Abi> {
  // 1. Local cache
  const cached = await readCache(chainId, address);
  if (cached) return cached;

  // 2. ABI proxy
  let abi = await fetchFromAbiProxy(address, chainId);
  if (abi) {
    await writeCache(chainId, address, abi);
    return abi;
  }

  // 3. Sourcify
  abi = await fetchFromSourcify(address, chainId);
  if (abi) {
    await writeCache(chainId, address, abi);
    return abi;
  }

  // 4. Etherscan v2
  abi = await fetchFromEtherscan(address, chainId);
  if (abi) {
    await writeCache(chainId, address, abi);
    return abi;
  }

  throw new Error(
    `ABI not found for ${address} on chain ${chainId}. Provide a local ABI file at abis/${chainId}/${address.toLowerCase()}.json`,
  );
}

// ---------------------------------------------------------------------------
// Function listing
// ---------------------------------------------------------------------------

export async function listFunctions(
  address: string,
  chainId: number,
): Promise<{ read: string[]; write: string[] }> {
  const abi = await loadAbi(address, chainId);
  const read: string[] = [];
  const write: string[] = [];

  for (const item of abi) {
    if (item.type !== "function") continue;
    const fn = item as AbiFunction;
    const inputs = fn.inputs.map((i) => i.type).join(",");
    const outputs = fn.outputs.map((o) => o.type).join(",");
    const sig = `${fn.name}(${inputs})${outputs ? `->(${outputs})` : ""}`;

    if (
      fn.stateMutability === "view" ||
      fn.stateMutability === "pure"
    ) {
      read.push(sig);
    } else {
      write.push(sig);
    }
  }

  return { read, write };
}