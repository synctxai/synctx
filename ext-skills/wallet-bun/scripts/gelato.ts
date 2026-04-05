import { concat, encodeAbiParameters, encodeFunctionData, toHex, type Address, type Hex } from "viem";
import { encodeCalldata, serialize } from "./abi.ts";
import { DEFAULT_CHAIN_ID, getAccount, getPublicClient, relayUrl, resolveChainId } from "./config.ts";

export const GELATO_DELEGATION = "0x5aF42746a8Af42d8a4708dF238C53F1F71abF0E0" as const;
const GELATO_DELEGATION_NAME = "GelatoDelegation";
const GELATO_DELEGATION_VERSION = "0.0.1";
const EXECUTE_MODE =
  "0x0100000000007821000100000000000000000000000000000000000000000000" as const;

const EXECUTE_TYPES = {
  Call: [
    { name: "to", type: "address" },
    { name: "value", type: "uint256" },
    { name: "data", type: "bytes" },
  ],
  Execute: [
    { name: "mode", type: "bytes32" },
    { name: "calls", type: "Call[]" },
    { name: "nonce", type: "uint256" },
  ],
} as const;

const NONCE_ABI = [
  {
    type: "function" as const,
    name: "getNonce",
    stateMutability: "view" as const,
    inputs: [{ name: "key", type: "uint192" }],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;

export interface Call {
  to: Address;
  value: bigint;
  data: Hex;
}

function delegationCode(): Hex {
  return `0xef0100${GELATO_DELEGATION.slice(2).toLowerCase()}` as Hex;
}

function safeNumber(value: bigint, label: string): number {
  if (value > BigInt(Number.MAX_SAFE_INTEGER)) {
    throw new Error(`${label} is too large to serialize safely`);
  }
  return Number(value);
}

export async function isDelegated(address: Address, chainId: number): Promise<boolean> {
  const code = await getPublicClient(chainId).getCode({ address });
  return (code ?? "0x").toLowerCase() === delegationCode().toLowerCase();
}

export async function getGelatoNonce(address: Address, chainId: number): Promise<bigint> {
  return getPublicClient(chainId).readContract({
    address,
    abi: NONCE_ABI,
    functionName: "getNonce",
    args: [0n],
  });
}

async function signExecute(chainId: number, calls: Call[], nonce: bigint): Promise<Hex> {
  const account = getAccount();
  return account.signTypedData({
    domain: {
      name: GELATO_DELEGATION_NAME,
      version: GELATO_DELEGATION_VERSION,
      chainId,
      verifyingContract: account.address,
    },
    types: EXECUTE_TYPES,
    primaryType: "Execute",
    message: {
      mode: EXECUTE_MODE,
      calls,
      nonce,
    },
  });
}

async function sign7702Authorization(chainId: number): Promise<{
  address: Address;
  chainId: number;
  nonce: bigint;
  r: Hex;
  s: Hex;
  yParity: number;
}> {
  const account = getAccount();
  const txNonce = await getPublicClient(chainId).getTransactionCount({ address: account.address });
  const authorization = await account.signAuthorization({
    contractAddress: GELATO_DELEGATION,
    chainId,
    nonce: txNonce,
  });
  return {
    address: authorization.address,
    chainId: authorization.chainId,
    nonce: BigInt(authorization.nonce),
    r: authorization.r,
    s: authorization.s,
    yParity: authorization.yParity ?? Number((authorization.v ?? 27n) - 27n),
  };
}

function encodeApproveCalldata(spender: Address, amount: bigint): Hex {
  return encodeFunctionData({
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
    args: [spender, amount],
  });
}

function encodeExecuteCalldata(calls: Call[], nonce: bigint, signature: Hex): Hex {
  const nonceKey = nonce >> 64n;
  if (nonceKey >= (1n << 192n)) {
    throw new Error(`nonce key out of range for uint192: ${nonceKey.toString()}`);
  }

  const opData = concat([toHex(nonceKey, { size: 24 }), signature]);
  const executionData = encodeAbiParameters(
    [
      {
        type: "tuple[]",
        components: [
          { name: "to", type: "address" },
          { name: "value", type: "uint256" },
          { name: "data", type: "bytes" },
        ],
      },
      { type: "bytes" },
    ],
    [calls, opData],
  );

  return encodeFunctionData({
    abi: [
      {
        type: "function",
        name: "execute",
        inputs: [
          { name: "mode", type: "bytes32" },
          { name: "executionData", type: "bytes" },
        ],
        outputs: [],
      },
    ],
    functionName: "execute",
    args: [EXECUTE_MODE, executionData],
  });
}

async function submitRelay(params: {
  chainId: number;
  userAddress: Address;
  executeData: Hex;
  authorizationList?: Array<{
    address: Address;
    chainId: number;
    nonce: bigint;
    r: Hex;
    s: Hex;
    yParity: number;
  }>;
  sync?: boolean;
  timeoutMs?: number;
}): Promise<Record<string, unknown>> {
  const body: Record<string, unknown> = {
    jsonrpc: "2.0",
    method: params.sync ? "relayer_sendTransactionSync" : "relayer_sendTransaction",
    params: {
      chainId: String(params.chainId),
      to: params.userAddress,
      data: params.executeData,
      payment: { type: "sponsored" },
    },
    id: 1,
  };

  if (params.authorizationList?.length) {
    (body.params as Record<string, unknown>).authorizationList = params.authorizationList.map((item) => ({
      address: item.address,
      chainId: item.chainId,
      nonce: safeNumber(item.nonce, "authorization nonce"),
      r: item.r,
      s: item.s,
      yParity: item.yParity,
    }));
  }

  if (params.sync) {
    (body.params as Record<string, unknown>).timeout = params.timeoutMs ?? 30_000;
  }

  const response = await fetch(`${relayUrl()}/relay`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const json = await response.json() as { error?: unknown; result?: unknown };

  if (!response.ok) {
    throw new Error(`Gelato relay failed (${response.status}): ${JSON.stringify(json)}`);
  }

  if (json.error) {
    throw new Error(`Gelato relay failed: ${JSON.stringify(json.error)}`);
  }

  if (params.sync) {
    if (!json.result || typeof json.result !== "object") {
      throw new Error(`Unexpected sync relay result: ${JSON.stringify(json.result)}`);
    }
    return { status: "included", receipt: serialize(json.result) };
  }

  return { status: "pending", taskId: json.result };
}

export async function getRelayStatus(taskId: string): Promise<Record<string, unknown>> {
  const response = await fetch(`${relayUrl()}/relay`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      method: "relayer_getStatus",
      params: { id: taskId },
      id: 1,
    }),
  });
  const json = await response.json() as { error?: unknown; result?: Record<string, unknown> };

  if (!response.ok) {
    throw new Error(`Status query failed (${response.status}): ${JSON.stringify(json)}`);
  }
  if (json.error) {
    throw new Error(`Status query failed: ${JSON.stringify(json.error)}`);
  }

  const result = json.result ?? {};
  const receipt = (result.receipt ?? {}) as Record<string, unknown>;
  return {
    taskId,
    status: result.status,
    message: result.message,
    txHash: receipt.transactionHash ?? result.hash,
    blockNumber: receipt.blockNumber,
  };
}

export async function gelatoRelay(
  contract: string,
  sig: string,
  args?: unknown[],
  options?: {
    chainId?: number;
    approveToken?: string;
    approveAmount?: bigint;
    sync?: boolean;
    timeoutMs?: number;
  },
): Promise<Record<string, unknown>> {
  const chainId = resolveChainId(options?.chainId ?? DEFAULT_CHAIN_ID);
  const account = getAccount();
  const contractAddress = contract as Address;

  const calls: Call[] = [];
  if (options?.approveToken) {
    calls.push({
      to: options.approveToken as Address,
      value: 0n,
      data: encodeApproveCalldata(contractAddress, options.approveAmount ?? 0n),
    });
  }
  calls.push({
    to: contractAddress,
    value: 0n,
    data: encodeCalldata(sig, args),
  });

  const delegated = await isDelegated(account.address, chainId);
  const nonce = delegated ? await getGelatoNonce(account.address, chainId) : 0n;
  const signature = await signExecute(chainId, calls, nonce);
  const executeData = encodeExecuteCalldata(calls, nonce, signature);
  const authorizationList = delegated ? undefined : [await sign7702Authorization(chainId)];

  const result = await submitRelay({
    chainId,
    userAddress: account.address,
    executeData,
    authorizationList,
    sync: options?.sync,
    timeoutMs: options?.timeoutMs,
  });

  const response: Record<string, unknown> = {
    status: options?.sync ? "included" : "relayed",
    signer: account.address,
    contract: contractAddress,
    function: sig,
    chain_id: chainId,
    gasless: true,
  };

  if (options?.approveToken) {
    response.approve = {
      token: options.approveToken,
      amount: String(options.approveAmount ?? 0n),
    };
  }

  if (options?.sync) {
    const receipt = (result.receipt ?? {}) as Record<string, unknown>;
    response.receipt = receipt;
    response.txHash = receipt.transactionHash;
    response.blockNumber = receipt.blockNumber;
  } else {
    response.taskId = result.taskId;
  }

  return response;
}
