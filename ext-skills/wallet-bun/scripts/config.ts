import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { config as loadEnv } from "dotenv";
import { createPublicClient, createWalletClient, http } from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { arbitrum, base, mainnet, optimism } from "viem/chains";

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const SKILL_DIR = join(SCRIPT_DIR, "..");
const ENV_PATH = join(SKILL_DIR, ".env");

loadEnv({ path: ENV_PATH, override: true });

export type WalletStatus = "ok" | "no_env" | "no_key" | "invalid_key";

export const DEFAULT_CHAIN_ID = 8453;
export const DEFAULT_RELAY_URL = "https://relayer.synctx.ai";

export const CHAINS = {
  1: { chain: mainnet, name: "Ethereum", symbol: "ETH" },
  10: { chain: optimism, name: "Optimism", symbol: "ETH" },
  8453: { chain: base, name: "Base", symbol: "ETH" },
  42161: { chain: arbitrum, name: "Arbitrum One", symbol: "ETH" },
} as const;

export type SupportedChainId = keyof typeof CHAINS;

export const USDC = {
  1: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
  10: "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85",
  8453: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
  42161: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831",
} as const;

export function skillDir(): string {
  return SKILL_DIR;
}

export function envPath(): string {
  return ENV_PATH;
}

export function resolveChainId(raw?: string | number): SupportedChainId {
  if (raw == null) return DEFAULT_CHAIN_ID;
  const value = Number(raw);
  if (!(value in CHAINS)) {
    throw new Error(`Unsupported chain: ${raw}`);
  }
  return value as SupportedChainId;
}

function normalizePrivateKey(raw: string): `0x${string}` {
  const trimmed = raw.trim();
  const prefixed = trimmed.startsWith("0x") ? trimmed : `0x${trimmed}`;
  if (!/^0x[0-9a-fA-F]{64}$/.test(prefixed)) {
    throw new Error("PRIVATE_KEY must be 64 hex chars, with or without 0x prefix");
  }
  return prefixed as `0x${string}`;
}

function rpcUrl(chainId: SupportedChainId): string {
  const custom = process.env[`CHAIN_RPC_${chainId}`];
  if (custom) return custom;
  return CHAINS[chainId].chain.rpcUrls.default.http[0]!;
}

export function relayUrl(): string {
  return (process.env.RELAY_URL || DEFAULT_RELAY_URL).replace(/\/+$/, "");
}

export function getAccount() {
  const raw = process.env.PRIVATE_KEY;
  if (!raw) {
    throw new Error(`PRIVATE_KEY not found. Run generate-wallet or set PRIVATE_KEY in ${ENV_PATH}`);
  }
  return privateKeyToAccount(normalizePrivateKey(raw));
}

export function getPublicClient(chainId: number = DEFAULT_CHAIN_ID) {
  const resolved = resolveChainId(chainId);
  return createPublicClient({
    chain: CHAINS[resolved].chain,
    transport: http(rpcUrl(resolved)),
  });
}

export function getWalletClient(chainId: number = DEFAULT_CHAIN_ID) {
  const resolved = resolveChainId(chainId);
  return createWalletClient({
    account: getAccount(),
    chain: CHAINS[resolved].chain,
    transport: http(rpcUrl(resolved)),
  });
}

export function checkWallet(): { status: WalletStatus; address?: string; env_path: string; error?: string } {
  if (!existsSync(ENV_PATH)) {
    return { status: "no_env", env_path: ENV_PATH };
  }

  const raw = process.env.PRIVATE_KEY;
  if (!raw) {
    return { status: "no_key", env_path: ENV_PATH };
  }

  try {
    const account = privateKeyToAccount(normalizePrivateKey(raw));
    return { status: "ok", address: account.address, env_path: ENV_PATH };
  } catch (error) {
    return {
      status: "invalid_key",
      env_path: ENV_PATH,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}

export function generateWallet(): { address: string; env_path: string; message: string } {
  const privateKey = generatePrivateKey();
  const account = privateKeyToAccount(privateKey);

  const existingLines = existsSync(ENV_PATH)
    ? readFileSync(ENV_PATH, "utf8").split(/\r?\n/)
    : [];

  const kept: string[] = [];
  let etherscanSeen = false;
  for (const line of existingLines) {
    if (line.startsWith("PRIVATE_KEY=")) continue;
    if (line.startsWith("ETHERSCAN_API_KEY=")) etherscanSeen = true;
    kept.push(line);
  }

  let insertIndex = 0;
  while (insertIndex < kept.length) {
    const line = kept[insertIndex] ?? "";
    if (line.startsWith("#") || line.trim() === "") {
      insertIndex += 1;
      continue;
    }
    break;
  }
  kept.splice(insertIndex, 0, `PRIVATE_KEY=${privateKey}`);

  if (!etherscanSeen) {
    if (kept.length && kept[kept.length - 1] !== "") kept.push("");
    kept.push("# (optional) Etherscan v2 API key, used as ABI fallback");
    kept.push("ETHERSCAN_API_KEY=");
  }

  writeFileSync(ENV_PATH, `${kept.join("\n").replace(/\n+$/, "")}\n`);
  process.env.PRIVATE_KEY = privateKey;

  return {
    address: account.address,
    env_path: ENV_PATH,
    message: `Wallet created. Address: ${account.address}. Private key saved to ${ENV_PATH}.`,
  };
}
