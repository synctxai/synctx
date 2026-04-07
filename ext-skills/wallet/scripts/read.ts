import { formatEther, formatUnits, type PublicClient } from "viem";
import {
  CHAINS,
  getPublicClient,
  getAccount,
  resolveChainId,
} from "./config.ts";
import { encodeCalldata, decodeResult, serialize } from "./abi.ts";

// ---------------------------------------------------------------------------
// ERC20 minimal ABI fragments
// ---------------------------------------------------------------------------

const ERC20_BALANCE_OF = [
  {
    type: "function" as const,
    name: "balanceOf",
    stateMutability: "view" as const,
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;

const ERC20_DECIMALS = [
  {
    type: "function" as const,
    name: "decimals",
    stateMutability: "view" as const,
    inputs: [],
    outputs: [{ name: "", type: "uint8" }],
  },
] as const;

const ERC20_SYMBOL = [
  {
    type: "function" as const,
    name: "symbol",
    stateMutability: "view" as const,
    inputs: [],
    outputs: [{ name: "", type: "string" }],
  },
] as const;

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

async function getEthBalance(
  client: PublicClient,
  address: `0x${string}`,
): Promise<bigint> {
  return await client.getBalance({ address });
}

async function getTokenBalance(
  client: PublicClient,
  token: `0x${string}`,
  owner: `0x${string}`,
): Promise<{ balance: bigint; decimals: number; symbol: string }> {
  const [balance, decimals, symbol] = await Promise.all([
    client.readContract({
      address: token,
      abi: ERC20_BALANCE_OF,
      functionName: "balanceOf",
      args: [owner],
    }),
    client.readContract({
      address: token,
      abi: ERC20_DECIMALS,
      functionName: "decimals",
    }),
    client.readContract({
      address: token,
      abi: ERC20_SYMBOL,
      functionName: "symbol",
    }),
  ]);
  return { balance, decimals, symbol };
}

// ---------------------------------------------------------------------------
// balance()
// ---------------------------------------------------------------------------

export interface BalanceOptions {
  chain?: number;
  token?: string;
}

interface ChainBalance {
  chain_id: number;
  chain_name: string;
  eth: string;
  eth_raw: string;
  tokens: { symbol: string; balance: string; balance_raw: string; address: string }[];
}

export async function balance(
  options?: BalanceOptions,
): Promise<ChainBalance[] | ChainBalance> {
  const account = getAccount();
  const owner = account.address;

  if (options?.token) {
    const chainId = resolveChainId(options.chain);
    const client = getPublicClient(chainId);
    const info = CHAINS[chainId];
    const token = options.token as `0x${string}`;
    const [ethBal, tokenInfo] = await Promise.all([
      getEthBalance(client, owner),
      getTokenBalance(client, token, owner),
    ]);
    return {
      chain_id: chainId,
      chain_name: info.name,
      eth: formatEther(ethBal),
      eth_raw: ethBal.toString(),
      tokens: [
        {
          symbol: tokenInfo.symbol,
          balance: formatUnits(tokenInfo.balance, tokenInfo.decimals),
          balance_raw: tokenInfo.balance.toString(),
          address: token,
        },
      ],
    };
  }

  if (options?.chain) {
    const chainId = resolveChainId(options.chain);
    const client = getPublicClient(chainId);
    const info = CHAINS[chainId];
    const ethBal = await getEthBalance(client, owner);
    const usdc = info.usdc;
    const tokenInfo = await getTokenBalance(client, usdc, owner);
    return {
      chain_id: chainId,
      chain_name: info.name,
      eth: formatEther(ethBal),
      eth_raw: ethBal.toString(),
      tokens: [
        {
          symbol: tokenInfo.symbol,
          balance: formatUnits(tokenInfo.balance, tokenInfo.decimals),
          balance_raw: tokenInfo.balance.toString(),
          address: usdc,
        },
      ],
    };
  }

  const chainIds = Object.keys(CHAINS).map(Number);
  const results = await Promise.all(
    chainIds.map(async (chainId) => {
      const client = getPublicClient(chainId);
      const info = CHAINS[chainId];
      const [ethBal, tokenInfo] = await Promise.all([
        getEthBalance(client, owner),
        getTokenBalance(client, info.usdc, owner),
      ]);
      return {
        chain_id: chainId,
        chain_name: info.name,
        eth: formatEther(ethBal),
        eth_raw: ethBal.toString(),
        tokens: [
          {
            symbol: tokenInfo.symbol,
            balance: formatUnits(tokenInfo.balance, tokenInfo.decimals),
            balance_raw: tokenInfo.balance.toString(),
            address: info.usdc,
          },
        ],
      } satisfies ChainBalance;
    }),
  );

  return results;
}

// ---------------------------------------------------------------------------
// read() — generic contract read
// ---------------------------------------------------------------------------

export interface ReadOptions {
  chain?: number;
  from?: string;
}

export async function read(
  contract: string,
  sig: string,
  args?: string[],
  options?: ReadOptions,
): Promise<unknown> {
  const chainId = resolveChainId(options?.chain);
  const client = getPublicClient(chainId);
  const calldata = encodeCalldata(sig, args);
  const from = options?.from as `0x${string}` | undefined;

  const result = await client.call({
    to: contract as `0x${string}`,
    data: calldata,
    account: from,
  });

  if (!result.data) {
    throw new Error("Empty response from contract call");
  }

  const decoded = decodeResult(sig, result.data);
  return serialize(decoded);
}
