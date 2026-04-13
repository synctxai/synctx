import { encodeFunctionData, formatUnits, type Address, type Hex } from "viem";
import { getPublicClient, getAccount, getWalletClient, resolveChainId } from "./config.ts";
import { encodeCalldata, parseSig } from "./abi.ts";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface Call {
  to: Address;
  value: bigint;
  data: Hex;
}

export interface SendOptions {
  chain?: number;
  value?: string;
  approve?: string;
  dryRun?: boolean;
}

export interface SendResult {
  status: string;
  txHash?: string;
  blockNumber?: number;
  function: string;
  contract: string;
  chain_id: number;
  approve?: { token: string; amount: string };
}

// ---------------------------------------------------------------------------
// ERC20 ABIs
// ---------------------------------------------------------------------------

const ERC20_BALANCE_OF_ABI = [
  {
    type: "function" as const,
    name: "balanceOf",
    stateMutability: "view" as const,
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;

const ERC20_DECIMALS_ABI = [
  {
    type: "function" as const,
    name: "decimals",
    stateMutability: "view" as const,
    inputs: [],
    outputs: [{ name: "", type: "uint8" }],
  },
] as const;

// ---------------------------------------------------------------------------
// Parse --approve flag
// ---------------------------------------------------------------------------

function parseApprove(
  approve: string,
): { token: Address; amount: bigint } {
  const parts = approve.split(":");
  if (parts.length !== 2) {
    throw new Error(
      `Invalid --approve format: "${approve}". Expected TOKEN:AMOUNT (e.g. 0xUSDC:1000000)`,
    );
  }
  return {
    token: parts[0] as Address,
    amount: BigInt(parts[1]),
  };
}

// ---------------------------------------------------------------------------
// send()
// ---------------------------------------------------------------------------

export async function send(
  contract: string,
  sig: string,
  args?: string[],
  options?: SendOptions,
): Promise<SendResult> {
  const chainId = resolveChainId(options?.chain);
  const account = getAccount();
  const contractAddr = contract as Address;
  const parsed = parseSig(sig);

  const businessData = encodeCalldata(sig, args);
  const value = options?.value ? BigInt(options.value) : 0n;

  let approveInfo: { token: Address; amount: bigint } | undefined;
  if (options?.approve) {
    approveInfo = parseApprove(options.approve);
  }

  if (options?.dryRun) {
    const preview: Record<string, unknown> = {
      chain_id: chainId,
      contract: contractAddr,
      function: `${parsed.name}(${parsed.inputTypes.join(",")})`,
      business_calldata: businessData,
      value: value.toString(),
    };

    if (approveInfo) {
      const client = getPublicClient(chainId);
      const [tokenBalance, decimals] = await Promise.all([
        client.readContract({
          address: approveInfo.token,
          abi: ERC20_BALANCE_OF_ABI,
          functionName: "balanceOf",
          args: [account.address],
        }),
        client.readContract({
          address: approveInfo.token,
          abi: ERC20_DECIMALS_ABI,
          functionName: "decimals",
        }),
      ]);

      preview.approve = {
        token: approveInfo.token,
        amount: approveInfo.amount.toString(),
        amount_formatted: formatUnits(approveInfo.amount, decimals),
        current_balance: tokenBalance.toString(),
        current_balance_formatted: formatUnits(tokenBalance, decimals),
        sufficient: tokenBalance >= approveInfo.amount,
      };
    }

    preview.dry_run = true;
    return preview as unknown as SendResult;
  }

  const calls = buildCalls(contractAddr, businessData, value, approveInfo);
  const fnSig = `${parsed.name}(${parsed.inputTypes.join(",")})`;

  const result = await directSend(calls, chainId, approveInfo);
  const response: SendResult = {
    status: result.status,
    txHash: result.txHash,
    blockNumber: result.blockNumber,
    function: fnSig,
    contract: contractAddr,
    chain_id: chainId,
  };
  if (approveInfo) {
    response.approve = {
      token: approveInfo.token,
      amount: approveInfo.amount.toString(),
    };
  }
  return response;
}

// ---------------------------------------------------------------------------
// Direct send (self-pay gas)
// ---------------------------------------------------------------------------

async function directSend(
  calls: Call[],
  chainId: number,
  approveInfo?: { token: Address; amount: bigint },
): Promise<{ status: string; txHash: string; blockNumber?: number }> {
  const walletClient = getWalletClient(chainId);
  const publicClient = getPublicClient(chainId);

  // If there's an approve call, send it first and wait
  if (approveInfo && calls.length > 1) {
    const approveCall = calls[0];
    const approveTxHash = await walletClient.sendTransaction({
      to: approveCall.to,
      data: approveCall.data,
      value: approveCall.value,
    });
    await publicClient.waitForTransactionReceipt({ hash: approveTxHash });
  }

  // Send the business call (last in calls array)
  const businessCall = calls[calls.length - 1];
  const txHash = await walletClient.sendTransaction({
    to: businessCall.to,
    data: businessCall.data,
    value: businessCall.value,
  });
  const receipt = await publicClient.waitForTransactionReceipt({ hash: txHash });

  return {
    status: receipt.status === "success" ? "included" : "reverted",
    txHash,
    blockNumber: Number(receipt.blockNumber),
  };
}

// ---------------------------------------------------------------------------
// Build calls array (7702 batch: approve + business call)
// ---------------------------------------------------------------------------

function buildCalls(
  contract: Address,
  businessData: Hex,
  value: bigint,
  approveInfo?: { token: Address; amount: bigint },
): Call[] {
  const calls: Call[] = [];

  if (approveInfo) {
    const approveData = encodeFunctionData({
      abi: [
        {
          type: "function",
          name: "approve",
          inputs: [
            { name: "spender", type: "address" },
            { name: "amount", type: "uint256" },
          ],
          outputs: [{ name: "", type: "bool" }],
        },
      ],
      functionName: "approve",
      args: [contract, approveInfo.amount],
    });
    calls.push({
      to: approveInfo.token,
      value: 0n,
      data: approveData,
    });
  }

  calls.push({
    to: contract,
    value,
    data: businessData,
  });

  return calls;
}
