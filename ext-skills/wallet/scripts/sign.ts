import { getAccount } from "./config.ts";

// ---------------------------------------------------------------------------
// EIP-191 personal sign
// ---------------------------------------------------------------------------

export async function signMessage(
  message: string,
): Promise<{ address: string; message: string; signature: string }> {
  const account = getAccount();
  const signature = await account.signMessage({ message });
  return {
    address: account.address,
    message,
    signature,
  };
}

// ---------------------------------------------------------------------------
// EIP-712 typed data
// ---------------------------------------------------------------------------

export interface TypedDataInput {
  domain: Record<string, unknown>;
  types: Record<string, { name: string; type: string }[]>;
  primaryType: string;
  message: Record<string, unknown>;
}

export async function signTypedData(
  data: TypedDataInput,
): Promise<{
  address: string;
  signature: string;
}> {
  const account = getAccount();
  const signature = await account.signTypedData({
    domain: data.domain as Record<string, unknown>,
    types: data.types,
    primaryType: data.primaryType,
    message: data.message,
  });
  return {
    address: account.address,
    signature,
  };
}
