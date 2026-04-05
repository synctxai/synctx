import { load } from "@std/dotenv";
import { createPublicClient, createWalletClient, http } from "viem";
import { privateKeyToAccount, generatePrivateKey } from "viem/accounts";
import { mainnet, optimism, base, arbitrum } from "viem/chains";
import { join, dirname, fromFileUrl } from "jsr:@std/path@^1";

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

export function skillDir(): string {
  return join(dirname(fromFileUrl(import.meta.url)), "..");
}

function envPath(): string {
  return join(skillDir(), ".env");
}

// ---------------------------------------------------------------------------
// Env
// ---------------------------------------------------------------------------

let _envLoaded = false;

async function ensureEnv(): Promise<void> {
  if (_envLoaded) return;
  try {
    await load({ envPath: envPath(), export: true });
  } catch {
    // .env may not exist yet
  }
  _envLoaded = true;
}

// ---------------------------------------------------------------------------
// Chain config
// ---------------------------------------------------------------------------

export interface ChainInfo {
  chain: typeof mainnet;
  name: string;
  symbol: string;
  usdc: `0x${string}`;
}

export const CHAINS: Record<number, ChainInfo> = {
  1: {
    chain: mainnet,
    name: "Ethereum",
    symbol: "ETH",
    usdc: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
  },
  10: {
    chain: optimism,
    name: "Optimism",
    symbol: "ETH",
    usdc: "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85",
  },
  8453: {
    chain: base,
    name: "Base",
    symbol: "ETH",
    usdc: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
  },
  42161: {
    chain: arbitrum,
    name: "Arbitrum",
    symbol: "ETH",
    usdc: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831",
  },
};

export const DEFAULT_CHAIN_ID = 8453;

export function resolveChainId(raw?: string | number): number {
  if (raw == null) return DEFAULT_CHAIN_ID;
  const id = Number(raw);
  if (!CHAINS[id]) throw new Error(`Unsupported chain: ${id}`);
  return id;
}

// ---------------------------------------------------------------------------
// Clients
// ---------------------------------------------------------------------------

function rpcUrl(chainId: number): string {
  const envKey = `CHAIN_RPC_${chainId}`;
  const custom = Deno.env.get(envKey);
  if (custom) return custom;
  return CHAINS[chainId].chain.rpcUrls.default.http[0];
}

export function getPublicClient(chainId: number = DEFAULT_CHAIN_ID) {
  const info = CHAINS[chainId];
  if (!info) throw new Error(`Unsupported chain: ${chainId}`);
  return createPublicClient({
    chain: info.chain,
    transport: http(rpcUrl(chainId)),
  });
}

export function getAccount() {
  const pk = Deno.env.get("PRIVATE_KEY");
  if (!pk) throw new Error("PRIVATE_KEY not set");
  const hex = pk.startsWith("0x") ? pk : `0x${pk}`;
  return privateKeyToAccount(hex as `0x${string}`);
}

export function getWalletClient(chainId: number = DEFAULT_CHAIN_ID) {
  const info = CHAINS[chainId];
  if (!info) throw new Error(`Unsupported chain: ${chainId}`);
  const account = getAccount();
  return createWalletClient({
    account,
    chain: info.chain,
    transport: http(rpcUrl(chainId)),
  });
}

// ---------------------------------------------------------------------------
// Wallet status
// ---------------------------------------------------------------------------

export type WalletStatus = "ok" | "no_env" | "no_key" | "invalid_key";

export async function checkWallet(): Promise<{
  status: WalletStatus;
  address?: string;
}> {
  await ensureEnv();
  try {
    const pk = Deno.env.get("PRIVATE_KEY");
    if (!pk) {
      // check if .env exists at all
      try {
        await Deno.stat(envPath());
        return { status: "no_key" };
      } catch {
        return { status: "no_env" };
      }
    }
    const hex = pk.startsWith("0x") ? pk : `0x${pk}`;
    const account = privateKeyToAccount(hex as `0x${string}`);
    return { status: "ok", address: account.address };
  } catch {
    return { status: "invalid_key" };
  }
}

export async function generateWallet(): Promise<{
  address: string;
  envFile: string;
}> {
  await ensureEnv();
  const pk = generatePrivateKey();
  const account = privateKeyToAccount(pk);
  const path = envPath();

  let content = "";
  try {
    content = await Deno.readTextFile(path);
  } catch {
    // file doesn't exist
  }

  if (content.includes("PRIVATE_KEY=")) {
    content = content.replace(/^PRIVATE_KEY=.*$/m, `PRIVATE_KEY=${pk}`);
  } else {
    content = content ? `${content}\nPRIVATE_KEY=${pk}\n` : `PRIVATE_KEY=${pk}\n`;
  }

  await Deno.writeTextFile(path, content);
  Deno.env.set("PRIVATE_KEY", pk);
  _envLoaded = true;

  return { address: account.address, envFile: path };
}