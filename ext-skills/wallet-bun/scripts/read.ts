import { formatEther, formatUnits } from "viem";
import { decodeCallResult, encodeCalldata, serialize } from "./abi.ts";
import { CHAINS, DEFAULT_CHAIN_ID, USDC, getAccount, getPublicClient, resolveChainId } from "./config.ts";

const ERC20_ABI = [
  {
    type: "function" as const,
    name: "balanceOf",
    stateMutability: "view" as const,
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    type: "function" as const,
    name: "decimals",
    stateMutability: "view" as const,
    inputs: [],
    outputs: [{ name: "", type: "uint8" }],
  },
  {
    type: "function" as const,
    name: "symbol",
    stateMutability: "view" as const,
    inputs: [],
    outputs: [{ name: "", type: "string" }],
  },
] as const;

export async function ethBalance(chainId: number = DEFAULT_CHAIN_ID): Promise<Record<string, unknown>> {
  const resolvedChainId = resolveChainId(chainId);
  const client = getPublicClient(resolvedChainId);
  const account = getAccount();
  const balanceRaw = await client.getBalance({ address: account.address });
  return {
    address: account.address,
    chain_id: resolvedChainId,
    balance_raw: balanceRaw.toString(),
    balance: `${formatEther(balanceRaw)} ${CHAINS[resolvedChainId].symbol}`,
  };
}

export async function tokenBalance(
  token: string,
  owner?: string,
  chainId: number = DEFAULT_CHAIN_ID,
): Promise<Record<string, unknown>> {
  const resolvedChainId = resolveChainId(chainId);
  const client = getPublicClient(resolvedChainId);
  const holder = (owner || getAccount().address) as `0x${string}`;

  const [raw, decimals, symbol] = await Promise.all([
    client.readContract({
      address: token as `0x${string}`,
      abi: ERC20_ABI,
      functionName: "balanceOf",
      args: [holder],
    }),
    client.readContract({
      address: token as `0x${string}`,
      abi: ERC20_ABI,
      functionName: "decimals",
    }),
    client.readContract({
      address: token as `0x${string}`,
      abi: ERC20_ABI,
      functionName: "symbol",
    }),
  ]);

  return {
    raw: raw.toString(),
    formatted: `${formatUnits(raw, decimals)} ${symbol}`.trim(),
    symbol,
    decimals,
  };
}

export async function allBalances(): Promise<Record<string, unknown>> {
  const account = getAccount();
  const entries = await Promise.all(
    Object.keys(CHAINS).map(async (chainKey) => {
      const chainId = Number(chainKey) as keyof typeof CHAINS;
      const client = getPublicClient(chainId);
      const [ethRaw, usdcRaw, usdcDecimals, usdcSymbol] = await Promise.all([
        client.getBalance({ address: account.address }),
        client.readContract({
          address: USDC[chainId],
          abi: ERC20_ABI,
          functionName: "balanceOf",
          args: [account.address],
        }),
        client.readContract({
          address: USDC[chainId],
          abi: ERC20_ABI,
          functionName: "decimals",
        }),
        client.readContract({
          address: USDC[chainId],
          abi: ERC20_ABI,
          functionName: "symbol",
        }),
      ]);

      return [
        CHAINS[chainId].name,
        {
          chain_id: chainId,
          eth: {
            raw: ethRaw.toString(),
            formatted: `${formatEther(ethRaw)} ${CHAINS[chainId].symbol}`,
          },
          usdc: {
            raw: usdcRaw.toString(),
            formatted: `${formatUnits(usdcRaw, usdcDecimals)} ${usdcSymbol}`,
          },
        },
      ] as const;
    }),
  );

  return {
    address: account.address,
    chains: Object.fromEntries(entries),
  };
}

export async function callContract(
  contract: string,
  sig: string,
  args?: unknown[],
  options?: { chainId?: number; from?: string },
): Promise<unknown> {
  const chainId = resolveChainId(options?.chainId);
  const client = getPublicClient(chainId);
  const data = encodeCalldata(sig, args);
  const result = await client.call({
    to: contract as `0x${string}`,
    data,
    account: options?.from as `0x${string}` | undefined,
  });

  if (!result.data) return null;
  return serialize(decodeCallResult(sig, result.data));
}
