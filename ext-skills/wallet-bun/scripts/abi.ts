import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { basename, isAbsolute, join } from "node:path";
import {
  decodeFunctionResult,
  encodeFunctionData,
  getAddress,
  isAddress,
  parseAbiItem,
  type Abi,
  type AbiFunction,
  type Hex,
} from "viem";
import { getPublicClient, skillDir } from "./config.ts";

const EIP1967_IMPLEMENTATION_SLOT =
  "0x360894A13BA1A3210667C828492DB98DCA3E2076CC3735A920A3CA505D382BBC" as const;
const PROXY_FUNCTIONS = new Set(["admin", "implementation", "changeAdmin", "upgradeTo", "upgradeToAndCall"]);

function splitTopLevel(value: string): string[] {
  if (!value.trim()) return [];
  const parts: string[] = [];
  let current = "";
  let depthParen = 0;
  let depthBracket = 0;

  for (const char of value) {
    if (char === "," && depthParen === 0 && depthBracket === 0) {
      if (current.trim()) parts.push(current.trim());
      current = "";
      continue;
    }
    if (char === "(") depthParen += 1;
    if (char === ")") depthParen -= 1;
    if (char === "[") depthBracket += 1;
    if (char === "]") depthBracket -= 1;
    current += char;
  }

  if (current.trim()) parts.push(current.trim());
  return parts;
}

export interface ParsedSig {
  name: string;
  inputTypes: string[];
  outputTypes: string[];
  abi: AbiFunction;
}

export function parseSig(sig: string): ParsedSig {
  const arrow = sig.indexOf("->");
  const functionPart = arrow >= 0 ? sig.slice(0, arrow) : sig;
  const outputPart = arrow >= 0 ? sig.slice(arrow + 2).trim() : "";

  const match = functionPart.trim().match(/^([A-Za-z_][A-Za-z0-9_]*)\((.*)\)$/);
  if (!match) {
    throw new Error(`Invalid function signature: ${sig}`);
  }

  const name = match[1]!;
  const inputTypes = splitTopLevel(match[2] ?? "");

  let outputsRaw = outputPart;
  if (outputsRaw.startsWith("(") && outputsRaw.endsWith(")")) {
    outputsRaw = outputsRaw.slice(1, -1);
  }
  const outputTypes = splitTopLevel(outputsRaw);

  const inputParams = inputTypes.map((type, index) => `${type} arg${index}`).join(", ");
  const outputParams = outputTypes.length
    ? ` returns (${outputTypes.map((type, index) => `${type} out${index}`).join(", ")})`
    : "";
  const abi = parseAbiItem(`function ${name}(${inputParams})${outputParams}`) as AbiFunction;

  return { name, inputTypes, outputTypes, abi };
}

export function serialize(value: unknown): unknown {
  if (typeof value === "bigint") return value.toString();
  if (value instanceof Uint8Array) {
    return `0x${Buffer.from(value).toString("hex")}`;
  }
  if (Array.isArray(value)) return value.map((item) => serialize(item));
  if (value && typeof value === "object") {
    const output: Record<string, unknown> = {};
    for (const [key, item] of Object.entries(value)) {
      output[key] = serialize(item);
    }
    return output;
  }
  return value;
}

function convertArg(value: unknown, abiType: string): unknown {
  if (abiType.endsWith("[]")) {
    const innerType = abiType.slice(0, -2);
    const parsed = typeof value === "string" ? JSON.parse(value) : value;
    if (!Array.isArray(parsed)) {
      throw new Error(`Expected JSON array for ${abiType}`);
    }
    return parsed.map((item) => convertArg(item, innerType));
  }
  if (abiType === "address") return String(value) as `0x${string}`;
  if (abiType === "bool") {
    if (typeof value === "boolean") return value;
    return ["true", "1", "yes"].includes(String(value).toLowerCase());
  }
  if (abiType.startsWith("uint") || abiType.startsWith("int")) return BigInt(String(value));
  if (abiType === "bytes" || abiType.startsWith("bytes")) return String(value) as Hex;
  if (abiType.startsWith("(") || abiType.startsWith("tuple")) {
    return typeof value === "string" ? JSON.parse(value) : value;
  }
  return value;
}

function convertArgs(args: unknown[] | undefined, types: string[]): unknown[] {
  if (!args?.length) return [];
  return args.map((value, index) => convertArg(value, types[index] ?? "string"));
}

export function encodeCalldata(sig: string, args?: unknown[]): Hex {
  const parsed = parseSig(sig);
  return encodeFunctionData({
    abi: [parsed.abi],
    functionName: parsed.name,
    args: convertArgs(args, parsed.inputTypes),
  });
}

export function decodeCallResult(sig: string, data: Hex): unknown {
  const parsed = parseSig(sig);
  if (!parsed.outputTypes.length) return data;
  const decoded = decodeFunctionResult({
    abi: [parsed.abi],
    functionName: parsed.name,
    data,
  });
  if (Array.isArray(decoded) && decoded.length === 1) {
    return decoded[0];
  }
  return decoded;
}

function normalizeAbiJson(input: unknown): Abi {
  if (Array.isArray(input)) return input as Abi;
  if (input && typeof input === "object" && Array.isArray((input as { abi?: unknown }).abi)) {
    return (input as { abi: Abi }).abi;
  }
  throw new Error("Invalid ABI JSON");
}

function abiCachePath(chainId: number, address: string): string {
  return join(skillDir(), "abis", String(chainId), `${address.toLowerCase()}.json`);
}

async function fetchFromAbiProxy(address: string, chainId: number): Promise<Abi | null> {
  const proxyUrl = process.env.ABI_PROXY_URL;
  if (!proxyUrl) return null;
  try {
    const response = await fetch(`${proxyUrl.replace(/\/+$/, "")}/abi/${chainId}/${address}`);
    if (!response.ok) return null;
    const json = await response.json() as { status?: string; result?: unknown };
    if (json.status === "1" && json.result) {
      return normalizeAbiJson(typeof json.result === "string" ? JSON.parse(json.result) : json.result);
    }
  } catch {
    return null;
  }
  return null;
}

async function fetchFromSourcify(address: string, chainId: number): Promise<Abi | null> {
  try {
    const response = await fetch(`https://sourcify.dev/server/files/any/${chainId}/${address}`);
    if (!response.ok) return null;
    const json = await response.json() as { files?: Array<{ name?: string; content?: string }> };
    const metadata = json.files?.find((file) => file.name === "metadata.json");
    if (!metadata?.content) return null;
    const parsed = JSON.parse(metadata.content) as { output?: { abi?: Abi } };
    return parsed.output?.abi ?? null;
  } catch {
    return null;
  }
}

async function fetchFromEtherscan(address: string, chainId: number): Promise<Abi | null> {
  const apiKey = process.env.ETHERSCAN_API_KEY;
  if (!apiKey) return null;
  try {
    const url = new URL("https://api.etherscan.io/v2/api");
    url.searchParams.set("chainid", String(chainId));
    url.searchParams.set("module", "contract");
    url.searchParams.set("action", "getabi");
    url.searchParams.set("address", address);
    url.searchParams.set("apikey", apiKey);
    const response = await fetch(url);
    if (!response.ok) return null;
    const json = await response.json() as { status?: string; result?: string };
    if (json.status === "1" && json.result) {
      return normalizeAbiJson(JSON.parse(json.result));
    }
  } catch {
    return null;
  }
  return null;
}

function looksLikeProxyAbi(abi: Abi): boolean {
  const names = abi
    .filter((item): item is AbiFunction => item.type === "function")
    .map((item) => item.name);
  return names.length > 0 && names.every((name) => PROXY_FUNCTIONS.has(name));
}

async function resolveImplementationAddress(address: string, chainId: number): Promise<string | null> {
  try {
    const implementation = await getPublicClient(chainId).readContract({
      address: address as `0x${string}`,
      abi: [
        {
          type: "function",
          name: "implementation",
          stateMutability: "view",
          inputs: [],
          outputs: [{ name: "", type: "address" }],
        },
      ],
      functionName: "implementation",
    });
    if (implementation && implementation !== "0x0000000000000000000000000000000000000000") {
      return getAddress(implementation);
    }
  } catch {
    // Fall through to EIP-1967 slot probing.
  }

  try {
    const raw = await getPublicClient(chainId).getStorageAt({
      address: address as `0x${string}`,
      slot: EIP1967_IMPLEMENTATION_SLOT,
    });
    if (!raw || /^0x0+$/i.test(raw)) return null;
    return getAddress(`0x${raw.slice(-40)}`);
  } catch {
    return null;
  }
}

async function fetchAbiFromSources(address: string, chainId: number): Promise<Abi | null> {
  return (
    await fetchFromAbiProxy(address, chainId) ??
    await fetchFromEtherscan(address, chainId) ??
    await fetchFromSourcify(address, chainId)
  );
}

async function fetchAndCacheAbi(address: string, chainId: number): Promise<Abi> {
  const cachedPath = abiCachePath(chainId, address);
  if (existsSync(cachedPath)) {
    const cached = normalizeAbiJson(JSON.parse(readFileSync(cachedPath, "utf8")));
    if (!looksLikeProxyAbi(cached)) {
      return cached;
    }
  }

  let abi = await fetchAbiFromSources(address, chainId);
  if (abi && looksLikeProxyAbi(abi)) {
    const implementationAddress = await resolveImplementationAddress(address, chainId);
    if (implementationAddress && implementationAddress.toLowerCase() !== address.toLowerCase()) {
      const implementationAbi = await fetchAbiFromSources(implementationAddress, chainId);
      if (implementationAbi) {
        abi = implementationAbi;
      }
    }
  }

  if (!abi) {
    throw new Error(
      `Cannot fetch ABI for ${address} on chain ${chainId}. Provide a local ABI file or configure ABI_PROXY_URL / ETHERSCAN_API_KEY.`,
    );
  }

  mkdirSync(join(skillDir(), "abis", String(chainId)), { recursive: true });
  writeFileSync(cachedPath, JSON.stringify(abi, null, 2));
  return abi;
}

export async function loadAbi(input: string, chainId: number): Promise<Abi> {
  const candidates = [
    input,
    join(process.cwd(), input),
    join(skillDir(), input),
    join(skillDir(), "scripts", input),
    join(skillDir(), "abis", basename(input)),
  ];

  for (const candidate of candidates) {
    if (!candidate) continue;
    if (!isAbsolute(candidate) && !candidate.startsWith(".")) continue;
    if (!existsSync(candidate)) continue;
    return normalizeAbiJson(JSON.parse(readFileSync(candidate, "utf8")));
  }

  if (isAddress(input)) {
    return fetchAndCacheAbi(input, chainId);
  }

  if (existsSync(input)) {
    return normalizeAbiJson(JSON.parse(readFileSync(input, "utf8")));
  }

  throw new Error(`ABI source not found: ${input}`);
}

export async function listFunctions(input: string, chainId: number): Promise<{ read: string[]; write: string[] }> {
  const abi = await loadAbi(input, chainId);
  const read: string[] = [];
  const write: string[] = [];

  for (const item of abi) {
    if (item.type !== "function") continue;
    const fn = item as AbiFunction;
    const inputs = fn.inputs.map((entry: AbiFunction["inputs"][number]) => entry.type).join(",");
    const outputs = fn.outputs.map((entry: AbiFunction["outputs"][number]) => entry.type).join(",");
    const sig = `${fn.name}(${inputs})${outputs ? `->(${outputs})` : ""}`;
    if (fn.stateMutability === "view" || fn.stateMutability === "pure") {
      read.push(sig);
    } else {
      write.push(sig);
    }
  }

  return { read, write };
}
