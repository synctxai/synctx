import {
  encodeFunctionData,
  encodeAbiParameters,
  concat,
  numberToHex,
  type Hex,
  type Address,
} from "viem";
import { getPublicClient, getAccount } from "./config.ts";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

export const GELATO_DELEGATION: Address =
  "0x5aF42746a8Af42d8a4708dF238C53F1F71abF0E0";

const EXECUTE_MODE: Hex =
  "0x0100000000007821000100000000000000000000000000000000000000000000";

const DEFAULT_RELAY_URL = "https://relayer.synctx.ai";

function relayUrl(): string {
  return Deno.env.get("RELAY_URL") || DEFAULT_RELAY_URL;
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface Call {
  to: Address;
  value: bigint;
  data: Hex;
}

export interface RelayResult {
  status: "included" | "pending" | "rejected" | "reverted";
  taskId: string;
  txHash?: string;
  blockNumber?: number;
}

// ---------------------------------------------------------------------------
// Delegation check
// ---------------------------------------------------------------------------

export async function isDelegated(
  address: Address,
  chainId: number,
): Promise<boolean> {
  const client = getPublicClient(chainId);
  const code = await client.getCode({ address });
  return !!code && code.startsWith("0xef0100");
}

// ---------------------------------------------------------------------------
// GelatoDelegation nonce
// ---------------------------------------------------------------------------

const GET_NONCE_ABI = [
  {
    type: "function" as const,
    name: "getNonce",
    stateMutability: "view" as const,
    inputs: [{ name: "key", type: "uint192" }],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;

export async function getGelatoNonce(
  address: Address,
  chainId: number,
): Promise<bigint> {
  const client = getPublicClient(chainId);
  // For 7702, delegation contract code lives at the user's EOA address
  const nonce = await client.readContract({
    address,
    abi: GET_NONCE_ABI,
    functionName: "getNonce",
    args: [0n],
  });
  return nonce;
}

// ---------------------------------------------------------------------------
// EIP-712 Execute signature
// ---------------------------------------------------------------------------

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

export async function signExecute(
  chainId: number,
  calls: Call[],
  nonce: bigint,
): Promise<Hex> {
  const account = getAccount();
  const signature = await account.signTypedData({
    domain: {
      name: "GelatoDelegation",
      version: "0.0.1",
      chainId: BigInt(chainId),
      verifyingContract: account.address,
    },
    types: EXECUTE_TYPES,
    primaryType: "Execute",
    message: {
      mode: EXECUTE_MODE,
      calls: calls.map((c) => ({
        to: c.to,
        value: c.value,
        data: c.data,
      })),
      nonce,
    },
  });
  return signature;
}

// ---------------------------------------------------------------------------
// EIP-7702 Authorization
// ---------------------------------------------------------------------------

export async function sign7702Authorization(
  chainId: number,
): Promise<{
  chainId: number;
  address: Address;
  nonce: bigint;
  r: Hex;
  s: Hex;
  yParity: number;
}> {
  const account = getAccount();
  const client = getPublicClient(chainId);

  const txNonce = await client.getTransactionCount({
    address: account.address,
  });

  const authorization = await account.signAuthorization({
    contractAddress: GELATO_DELEGATION,
    chainId,
    nonce: txNonce,
  });

  return {
    chainId: authorization.chainId,
    address: authorization.contractAddress,
    nonce: BigInt(authorization.nonce),
    r: authorization.r,
    s: authorization.s,
    yParity: authorization.yParity,
  };
}

// ---------------------------------------------------------------------------
// Encode execute calldata
// ---------------------------------------------------------------------------

export function encodeExecuteCalldata(
  calls: Call[],
  nonce: bigint,
  signature: Hex,
): Hex {
  // opData = abi.encodePacked(uint192 nonceKey, bytes signature)
  // nonceKey = nonce >> 64 for standard sequential nonce lane
  const nonceKey = nonce >> 64n;
  const opData = concat([
    numberToHex(nonceKey, { size: 24 }), // uint192 = 24 bytes
    signature,
  ]);

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
    [
      calls.map((c) => ({
        to: c.to,
        value: c.value,
        data: c.data,
      })),
      opData,
    ],
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

// ---------------------------------------------------------------------------
// Submit to relay proxy
// ---------------------------------------------------------------------------

export async function submitRelay(params: {
  chainId: number;
  to: Address;
  data: Hex;
  authorizationList?: {
    chainId: number;
    address: Address;
    nonce: bigint;
    r: Hex;
    s: Hex;
    yParity: number;
  }[];
}): Promise<string> {
  const url = `${relayUrl()}/relay`;
  const body: Record<string, unknown> = {
    jsonrpc: "2.0",
    method: "relayer_sendTransaction",
    params: {
      chainId: String(params.chainId),
      to: params.to,
      data: params.data,
      payment: { type: "sponsored" },
    },
    id: 1,
  };

  if (params.authorizationList?.length) {
    (body.params as Record<string, unknown>).authorizationList =
      params.authorizationList.map((a) => ({
        chainId: `0x${a.chainId.toString(16)}`,
        address: a.address,
        nonce: `0x${a.nonce.toString(16)}`,
        r: a.r,
        s: a.s,
        yParity: `0x${a.yParity.toString(16)}`,
      }));
  }

  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });

  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Relay request failed (${res.status}): ${text}`);
  }

  const json = await res.json();
  if (json.error) {
    throw new Error(
      `Relay RPC error: ${json.error.message || JSON.stringify(json.error)}`,
    );
  }

  return json.result as string;
}

// ---------------------------------------------------------------------------
// Relay status polling
// ---------------------------------------------------------------------------

export async function getRelayStatus(
  taskId: string,
): Promise<RelayResult> {
  const url = `${relayUrl()}/relay`;
  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      method: "relayer_getStatus",
      params: { id: taskId },
      id: 1,
    }),
  });

  if (!res.ok) {
    throw new Error(`Relay status request failed (${res.status})`);
  }

  const json = await res.json();
  if (json.error) {
    throw new Error(
      `Relay status RPC error: ${json.error.message || JSON.stringify(json.error)}`,
    );
  }

  const result = json.result;
  const statusCode = result?.status;

  let status: RelayResult["status"];
  if (statusCode === 200) status = "included";
  else if (statusCode === 400) status = "rejected";
  else if (statusCode === 500) status = "reverted";
  else status = "pending";

  return {
    status,
    taskId,
    txHash: result?.receipt?.transactionHash,
    blockNumber: result?.receipt?.blockNumber
      ? Number(result.receipt.blockNumber)
      : undefined,
  };
}

// ---------------------------------------------------------------------------
// High-level: relayBatch
// ---------------------------------------------------------------------------

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export async function relayBatch(
  calls: Call[],
  chainId: number,
): Promise<RelayResult> {
  const account = getAccount();
  const address = account.address;

  const delegated = await isDelegated(address, chainId);
  let authorizationList:
    | Awaited<ReturnType<typeof sign7702Authorization>>[]
    | undefined;
  if (!delegated) {
    const auth = await sign7702Authorization(chainId);
    authorizationList = [auth];
  }

  let nonce: bigint;
  if (delegated) {
    nonce = await getGelatoNonce(address, chainId);
  } else {
    nonce = 0n;
  }

  const signature = await signExecute(chainId, calls, nonce);
  const executeData = encodeExecuteCalldata(calls, nonce, signature);

  const taskId = await submitRelay({
    chainId,
    to: address,
    data: executeData,
    authorizationList,
  });

  const deadline = Date.now() + 60_000;
  while (Date.now() < deadline) {
    await sleep(2000);
    const result = await getRelayStatus(taskId);
    if (result.status !== "pending") {
      return result;
    }
  }

  return {
    status: "pending",
    taskId,
  };
}
