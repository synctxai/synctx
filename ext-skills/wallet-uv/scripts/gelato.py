"""Gelato 7702 Turbo Relay — gasless transactions via EIP-7702 Smart Account.

Architecture
------------
EIP-7702 lets an EOA temporarily delegate to GelatoDelegation contract.
The user signs an EIP-712 Execute message, and a Gelato relayer submits
the tx on-chain. msg.sender remains the user's EOA address.

Flow
~~~~
1. Check if EOA is delegated (code at user address == GelatoDelegation)
2. If not, sign a 7702 authorization (one-time)
3. Build calls[] array (optional approve + business call)
4. Sign EIP-712 Execute typed data
5. POST to relay proxy (relayer.synctx.ai) which injects API key and forwards to Gelato

The relay proxy address is configurable via RELAY_URL env var.
Agent does NOT hold any Gelato API key.
"""
from __future__ import annotations

import os, time
from typing import Any

import httpx
from web3 import Web3
from eth_abi import encode as abi_encode
from eth_account.messages import encode_typed_data

try:
    from .chains import get_w3, get_account
except ImportError:
    from chains import get_w3, get_account

# ── Constants ──

GELATO_DELEGATION_ADDRESS = "0x5aF42746a8Af42d8a4708dF238C53F1F71abF0E0"
GELATO_DELEGATION_NAME = "GelatoDelegation"
GELATO_DELEGATION_VERSION = "0.0.1"

# Execute mode for single/batch calls via GelatoDelegation
EXECUTE_MODE = bytes.fromhex(
    "0100000000007821000100000000000000000000000000000000000000000000"
)

# Default relay proxy URL (no API key needed — injected server-side)
DEFAULT_RELAY_URL = "https://relayer.synctx.ai"
DEFAULT_CHAIN_ID = 8453

# EIP-712 types for GelatoDelegation.execute
EXECUTE_TYPES = {
    "EIP712Domain": [
        {"name": "name", "type": "string"},
        {"name": "version", "type": "string"},
        {"name": "chainId", "type": "uint256"},
        {"name": "verifyingContract", "type": "address"},
    ],
    "Call": [
        {"name": "to", "type": "address"},
        {"name": "value", "type": "uint256"},
        {"name": "data", "type": "bytes"},
    ],
    "Execute": [
        {"name": "mode", "type": "bytes32"},
        {"name": "calls", "type": "Call[]"},
        {"name": "nonce", "type": "uint256"},
    ],
}

# Minimal ABI for GelatoDelegation nonce query
_NONCE_ABI = [
    {
        "inputs": [{"name": "key", "type": "uint192"}],
        "name": "getNonce",
        "outputs": [{"type": "uint256"}],
        "stateMutability": "view",
        "type": "function",
    }
]


def _relay_url() -> str:
    """Get relay proxy URL from env or default."""
    return os.environ.get("RELAY_URL", DEFAULT_RELAY_URL).rstrip("/")


def _delegation_code() -> bytes:
    """Return the exact EIP-7702 delegation designator Gelato deploys to the EOA."""
    return b"\xef\x01\x00" + bytes.fromhex(GELATO_DELEGATION_ADDRESS.removeprefix("0x"))


# ── Delegation check ──

def is_delegated(address: str, chain_id: int) -> bool:
    """Check if the EOA is delegated specifically to GelatoDelegation."""
    w3 = get_w3(chain_id)
    code = w3.eth.get_code(Web3.to_checksum_address(address))
    return bytes(code) == _delegation_code()


# ── Nonce ──

def get_gelato_nonce(address: str, chain_id: int) -> int:
    """Query the GelatoDelegation nonce for this account.

    For 7702, the delegation contract code lives at the user's EOA address,
    so we call getNonce on the user's own address.
    """
    w3 = get_w3(chain_id)
    addr = Web3.to_checksum_address(address)
    contract = w3.eth.contract(address=addr, abi=_NONCE_ABI)
    # key=0 for standard sequential nonce
    return contract.functions.getNonce(0).call()


# ── EIP-712 Execute signing ──

def sign_execute(
    chain_id: int,
    calls: list[dict],
    nonce: int,
) -> bytes:
    """Sign EIP-712 Execute typed data for GelatoDelegation.

    Parameters
    ----------
    chain_id : int
        Target chain ID.
    calls : list[dict]
        List of {to, value, data} call objects.
    nonce : int
        GelatoDelegation nonce.

    Returns
    -------
    bytes
        65-byte ECDSA signature.
    """
    account = get_account()

    domain = {
        "name": GELATO_DELEGATION_NAME,
        "version": GELATO_DELEGATION_VERSION,
        "chainId": chain_id,
        "verifyingContract": account.address,  # 7702: verifyingContract = user's own EOA
    }

    # Convert call data to proper format
    formatted_calls = []
    for c in calls:
        formatted_calls.append({
            "to": Web3.to_checksum_address(c["to"]),
            "value": c.get("value", 0),
            "data": bytes.fromhex(c["data"].removeprefix("0x")) if isinstance(c["data"], str) else c["data"],
        })

    message = {
        "mode": EXECUTE_MODE,
        "calls": formatted_calls,
        "nonce": nonce,
    }

    typed_data = {
        "types": EXECUTE_TYPES,
        "primaryType": "Execute",
        "domain": domain,
        "message": message,
    }

    signed = account.sign_message(encode_typed_data(full_message=typed_data))
    return signed.signature


# ── 7702 Authorization signing ──

def sign_7702_authorization(chain_id: int) -> dict:
    """Sign EIP-7702 authorization to delegate EOA to GelatoDelegation.

    EIP-7702 authorization = sign(keccak256(0x05 || rlp([chainId, address, nonce])))
    Returns a fully signed authorization object for the Gelato API's authorizationList.
    """
    import rlp
    from eth_utils import keccak

    account = get_account()
    w3 = get_w3(chain_id)
    nonce = w3.eth.get_transaction_count(account.address)

    # EIP-7702 authorization tuple: (chainId, address, nonce)
    delegation_addr = bytes.fromhex(GELATO_DELEGATION_ADDRESS[2:])

    # RLP encode: [chainId, contractAddress, nonce]
    encoded = rlp.encode([chain_id, delegation_addr, nonce])

    # Hash: keccak256(0x05 || rlp_encoded)
    digest = keccak(b'\x05' + encoded)

    # Sign with user's private key
    signed = account.unsafe_sign_hash(digest)

    return {
        "address": GELATO_DELEGATION_ADDRESS,
        "chainId": chain_id,
        "nonce": nonce,
        "r": "0x" + signed.r.to_bytes(32, "big").hex(),
        "s": "0x" + signed.s.to_bytes(32, "big").hex(),
        "yParity": signed.v - 27,  # EIP-7702 uses yParity (0 or 1)
    }


# ── Calldata encoding helpers ──

def _encode_approve(spender: str, amount: int) -> str:
    """Encode ERC20 approve(address,uint256) calldata."""
    selector = bytes.fromhex("095ea7b3")  # approve(address,uint256)
    data = selector + abi_encode(["address", "uint256"], [Web3.to_checksum_address(spender), amount])
    return "0x" + data.hex()


def _encode_function_call(sig: str, args: list | None) -> str:
    """Encode arbitrary function calldata from signature + args.

    Uses the abi module's _invoke helper for encoding.
    """
    try:
        from .abi import _invoke as _encode
    except ImportError:
        from abi import _invoke as _encode
    return "0x" + _encode(sig, args or []).hex()


# ── Execute calldata encoding ──

def _encode_execute_calldata(calls: list[dict], nonce: int, signature: bytes) -> str:
    """Encode GelatoDelegation.execute(mode, executionData) calldata.

    The execute function takes (bytes32 mode, bytes executionData).
    executionData = abi.encode(Call[], opData).
    opData = abi.encodePacked(uint192 nonceKey, bytes signature), where
    nonceKey = nonce >> 64 for the standard sequential nonce lane.
    """
    # Encode calls as array of (address, uint256, bytes) tuples
    encoded_calls = []
    for c in calls:
        to = Web3.to_checksum_address(c["to"])
        value = c.get("value", 0)
        data = bytes.fromhex(c["data"].removeprefix("0x")) if isinstance(c["data"], str) else c["data"]
        encoded_calls.append((to, value, data))

    nonce_key = nonce >> 64
    if nonce_key >= (1 << 192):
        raise ValueError(f"nonce key out of range for uint192: {nonce_key}")
    op_data = nonce_key.to_bytes(24, "big") + signature

    execution_data = abi_encode(
        ["(address,uint256,bytes)[]", "bytes"],
        [encoded_calls, op_data]
    )

    # execute(bytes32 mode, bytes executionData)
    selector = Web3.keccak(text="execute(bytes32,bytes)")[:4]
    calldata = selector + abi_encode(["bytes32", "bytes"], [EXECUTE_MODE, execution_data])
    return "0x" + calldata.hex()


# ── Submit to relay proxy ──

def _submit_relay(
    chain_id: int,
    user_address: str,
    execute_data: str,
    authorization_list: list | None = None,
    *,
    sync: bool = False,
    timeout_ms: int = 30000,
) -> dict:
    """Submit transaction to relay proxy (relayer.synctx.ai → Gelato).

    The proxy injects the Gelato API key and forwards the JSON-RPC call.
    """
    params: dict[str, Any] = {
        "chainId": str(chain_id),
        "to": Web3.to_checksum_address(user_address),  # 7702: to = user's own EOA
        "data": execute_data,
        "payment": {"type": "sponsored"},
    }

    if authorization_list:
        params["authorizationList"] = authorization_list
    if sync:
        params["timeout"] = timeout_ms

    body = {
        "jsonrpc": "2.0",
        "method": "relayer_sendTransactionSync" if sync else "relayer_sendTransaction",
        "params": params,
        "id": 1,
    }

    http_timeout = max(30, timeout_ms / 1000 + 5) if sync else 30
    resp = httpx.post(
        f"{_relay_url()}/relay",
        json=body,
        timeout=http_timeout,
    )
    data = resp.json()

    if "error" in data:
        error = data["error"]
        msg = error.get("message", str(error)) if isinstance(error, dict) else str(error)
        raise RuntimeError(f"Gelato relay failed: {msg}")

    result = data.get("result")
    if sync:
        if not isinstance(result, dict):
            raise RuntimeError(f"Unexpected sync relay result: {result!r}")
        return {"receipt": result, "status": "included"}
    return {"taskId": result, "status": "pending"}


# ── Get relay status ──

def get_relay_status(task_id: str) -> dict:
    """Query Gelato relay task status via relay proxy.

    Status codes: 100=Pending, 110=Submitted, 200=Included, 400=Rejected, 500=Reverted
    """
    body = {
        "jsonrpc": "2.0",
        "method": "relayer_getStatus",
        "params": {"id": task_id},
        "id": 1,
    }

    resp = httpx.post(f"{_relay_url()}/relay", json=body, timeout=10)
    data = resp.json()

    if "error" in data:
        error = data["error"]
        msg = error.get("message", str(error)) if isinstance(error, dict) else str(error)
        raise RuntimeError(f"Status query failed: {msg}")

    result = data.get("result", {})
    receipt = result.get("receipt") or {}
    return {
        "taskId": task_id,
        "status": result.get("status"),
        "message": result.get("message"),
        "txHash": receipt.get("transactionHash") or result.get("hash"),
        "blockNumber": receipt.get("blockNumber"),
    }


# ── Public API ──

def gelato_relay(
    contract: str,
    sig: str,
    args: list | None = None,
    *,
    chain_id: int = DEFAULT_CHAIN_ID,
    approve_token: str | None = None,
    approve_amount: int = 0,
    sync: bool = False,
    timeout_ms: int = 30000,
) -> dict:
    """Send a gasless transaction via Gelato 7702 Turbo.

    Always uses EIP-7702 smart account path so that msg.sender = user EOA.
    If approve_token is set, batches approve + business call atomically.

    Parameters
    ----------
    contract : str
        Target contract address.
    sig : str
        Function signature, e.g. "accept(uint256)".
    args : list | None
        Function arguments.
    chain_id : int
        Target chain ID (default: 8453 / Base).
    approve_token : str | None
        If set, batch an ERC20 approve before the business call.
    approve_amount : int
        Amount to approve (ignored if approve_token is None).
    sync : bool
        If true, wait for the final receipt via relayer_sendTransactionSync.
    timeout_ms : int
        Maximum wait time for sync mode in milliseconds.

    Returns
    -------
    dict
        Relay result with taskId, status, etc.
    """
    account = get_account()
    contract_addr = Web3.to_checksum_address(contract)

    # 1. Build calls list
    calls = []
    if approve_token:
        calls.append({
            "to": Web3.to_checksum_address(approve_token),
            "value": 0,
            "data": _encode_approve(contract_addr, approve_amount),
        })
    calls.append({
        "to": contract_addr,
        "value": 0,
        "data": _encode_function_call(sig, args),
    })

    # 2. Get nonce (from GelatoDelegation at user's EOA)
    delegated = is_delegated(account.address, chain_id)
    nonce = get_gelato_nonce(account.address, chain_id) if delegated else 0

    # 3. Sign EIP-712 Execute
    execute_sig = sign_execute(chain_id, calls, nonce)

    # 4. Encode execute calldata
    execute_data = _encode_execute_calldata(calls, nonce, execute_sig)

    # 5. 7702 authorization (if not yet delegated)
    auth_list = None
    if not delegated:
        auth_list = [sign_7702_authorization(chain_id)]

    # 6. Submit to relay proxy (to = user's own EOA for 7702)
    result = _submit_relay(
        chain_id,
        account.address,
        execute_data,
        auth_list,
        sync=sync,
        timeout_ms=timeout_ms,
    )

    response = {
        "status": "relayed",
        "signer": account.address,
        "contract": contract_addr,
        "function": sig,
        "chain_id": chain_id,
        "gasless": True,
        **({"approve": {"token": approve_token, "amount": str(approve_amount)}} if approve_token else {}),
    }
    if sync:
        receipt = result.get("receipt", {})
        response.update({
            "status": "included",
            "receipt": receipt,
            "txHash": receipt.get("transactionHash"),
            "blockNumber": receipt.get("blockNumber"),
        })
    else:
        response["taskId"] = result.get("taskId")
    return response
