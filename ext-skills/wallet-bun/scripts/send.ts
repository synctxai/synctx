import { formatUnits } from "viem";
import { decodeRevert } from "./decode.ts";
import { encodeCalldata, parseSig, serialize } from "./abi.ts";
import { DEFAULT_CHAIN_ID, getAccount, getPublicClient, getWalletClient, resolveChainId } from "./config.ts";

const ERC20_ABI = [
  {
    type: "function" as const,
    name: "allowance",
    stateMutability: "view" as const,
    inputs: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
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
] as const;

function extractErrorData(error: unknown): string | null {
  if (!error || typeof error !== "object") {
    const match = String(error).match(/0x[0-9a-fA-F]{8,}/);
    return match?.[0] ?? null;
  }

  const candidate = error as Record<string, unknown>;
  for (const key of ["data", "details", "shortMessage", "message"]) {
    const value = candidate[key];
    if (typeof value === "string") {
      const match = value.match(/0x[0-9a-fA-F]{8,}/);
      if (match) return match[0];
    }
  }

  if (candidate.cause) {
    const nested = extractErrorData(candidate.cause);
    if (nested) return nested;
  }

  const match = String(error).match(/0x[0-9a-fA-F]{8,}/);
  return match?.[0] ?? null;
}

async function estimateOrThrow(
  to: string,
  data: `0x${string}`,
  chainId: number,
  value: bigint,
): Promise<bigint> {
  const client = getPublicClient(chainId);
  const account = getAccount();
  try {
    return await client.estimateGas({
      account: account.address,
      to: to as `0x${string}`,
      data,
      value,
    });
  } catch (error) {
    const errorData = extractErrorData(error);
    if (errorData) {
      const decoded = await decodeRevert(errorData, to, chainId);
      throw new Error(`Transaction would revert: ${decoded}`);
    }
    throw error;
  }
}

async function sendTransaction(
  to: string,
  data: `0x${string}`,
  chainId: number,
  value: bigint,
): Promise<Record<string, unknown>> {
  const gas = await estimateOrThrow(to, data, chainId, value);
  const walletClient = getWalletClient(chainId);
  const publicClient = getPublicClient(chainId);
  const account = getAccount();
  const hash = await walletClient.sendTransaction({
    account,
    to: to as `0x${string}`,
    data,
    value,
    gas,
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  return serialize(receipt) as Record<string, unknown>;
}

export async function invoke(
  contract: string,
  sig: string,
  args?: unknown[],
  options?: { chainId?: number; value?: bigint; dryRun?: boolean },
): Promise<Record<string, unknown>> {
  const chainId = resolveChainId(options?.chainId);
  const value = options?.value ?? 0n;
  const data = encodeCalldata(sig, args);

  if (options?.dryRun) {
    const gas = await estimateOrThrow(contract, data, chainId, value);
    return {
      status: "ok",
      from: getAccount().address,
      to: contract,
      function: sig,
      args: serialize(args ?? []),
      chain_id: chainId,
      value_wei: value.toString(),
      estimated_gas: gas.toString(),
    };
  }

  return sendTransaction(contract, data, chainId, value);
}

export async function approve(
  token: string,
  spender: string,
  amount: string | bigint,
  chainId: number = DEFAULT_CHAIN_ID,
): Promise<Record<string, unknown> | null> {
  const resolvedChainId = resolveChainId(chainId);
  const client = getPublicClient(resolvedChainId);
  const owner = getAccount().address;
  const allowance = await client.readContract({
    address: token as `0x${string}`,
    abi: ERC20_ABI,
    functionName: "allowance",
    args: [owner, spender as `0x${string}`],
  });

  if (allowance >= BigInt(amount)) {
    return null;
  }

  return sendTransaction(
    token,
    encodeCalldata("approve(address,uint256)", [spender, String(amount)]),
    resolvedChainId,
    0n,
  );
}

export async function approveAndInvoke(
  token: string,
  contract: string,
  amount: string | bigint,
  sig: string,
  args?: unknown[],
  options?: { chainId?: number; value?: bigint },
): Promise<Record<string, unknown>> {
  await approve(token, contract, amount, options?.chainId ?? DEFAULT_CHAIN_ID);
  return invoke(contract, sig, args, {
    chainId: options?.chainId ?? DEFAULT_CHAIN_ID,
    value: options?.value ?? 0n,
  });
}

export async function approvePreview(
  token: string,
  owner: string,
  amount: bigint,
  chainId: number,
): Promise<Record<string, unknown>> {
  const client = getPublicClient(chainId);
  const [balance, decimals] = await Promise.all([
    client.readContract({
      address: token as `0x${string}`,
      abi: ERC20_ABI,
      functionName: "balanceOf",
      args: [owner as `0x${string}`],
    }),
    client.readContract({
      address: token as `0x${string}`,
      abi: ERC20_ABI,
      functionName: "decimals",
    }),
  ]);

  return {
    token,
    amount: amount.toString(),
    amount_formatted: formatUnits(amount, decimals),
    current_balance: balance.toString(),
    current_balance_formatted: formatUnits(balance, decimals),
    sufficient: balance >= amount,
  };
}
