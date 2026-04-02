# Gasless meta-transaction relay — EIP-712 signing + relayer API submission
# Replaces direct on-chain tx (invoke) with signed meta-tx routed through the relayer.
# User pays zero gas; relayer pays gas on behalf of the user.
from __future__ import annotations

import json, os, time
from typing import Any

import httpx
from web3 import Web3
from eth_account.messages import encode_typed_data

try:
    from .chains import get_w3, get_account
    from .abi import _invoke as _encode_calldata
except ImportError:
    from chains import get_w3, get_account
    from abi import _invoke as _encode_calldata


# ── Config (auto-discovered, zero user configuration) ──

_relayer_url_cache: str | None = None

def _relayer_url() -> str:
    """Get relayer URL from platform /api/config (cached)."""
    global _relayer_url_cache
    if _relayer_url_cache is not None:
        return _relayer_url_cache

    server = os.environ.get("SYNCTX_SERVER", "http://localhost:3000")
    try:
        resp = httpx.get(f"{server.rstrip('/')}/api/config", timeout=5)
        resp.raise_for_status()
        url = resp.json().get("relayerUrl")
        if url:
            _relayer_url_cache = url.rstrip("/")
            return _relayer_url_cache
    except Exception:
        pass
    raise RuntimeError("Cannot discover relayer URL from platform /api/config")


_forwarder_cache: dict[str, str] = {}

def _forwarder_address(chain_id: int, contract: str) -> str:
    """Read trustedForwarder from the target contract (cached per contract address)."""
    key = f"{chain_id}:{contract.lower()}"
    if key in _forwarder_cache:
        return _forwarder_cache[key]
    w3 = get_w3(chain_id)
    contract_addr = Web3.to_checksum_address(contract)
    tf = w3.eth.contract(address=contract_addr, abi=[
        {"inputs": [], "name": "trustedForwarder", "outputs": [{"type": "address"}], "stateMutability": "view", "type": "function"},
    ])
    addr = tf.functions.trustedForwarder().call()
    if addr == "0x0000000000000000000000000000000000000000":
        raise RuntimeError(f"trustedForwarder not set on contract {contract}")
    addr = Web3.to_checksum_address(addr)
    _forwarder_cache[key] = addr
    return addr


# ── Forwarder EIP-712 domain ──

FORWARD_REQUEST_TYPES = {
    "EIP712Domain": [
        {"name": "name", "type": "string"},
        {"name": "version", "type": "string"},
        {"name": "chainId", "type": "uint256"},
        {"name": "verifyingContract", "type": "address"},
    ],
    "ForwardRequest": [
        {"name": "from", "type": "address"},
        {"name": "to", "type": "address"},
        {"name": "nonce", "type": "uint256"},
        {"name": "deadline", "type": "uint256"},
        {"name": "data", "type": "bytes"},
    ],
}


def _build_domain(chain_id: int, contract: str) -> dict:
    return {
        "name": "SyncTxForwarder",
        "version": "1",
        "chainId": chain_id,
        "verifyingContract": _forwarder_address(chain_id, contract),
    }


# ── Nonce ──

def _get_nonce(chain_id: int) -> int:
    """Fetch user's current nonce from the relayer API."""
    account = get_account()
    url = f"{_relayer_url()}/relay/nonce"
    resp = httpx.get(url, params={"address": account.address, "chainId": chain_id}, timeout=10)
    resp.raise_for_status()
    return resp.json()["nonce"]


# ── Sign ForwardRequest ──

def _sign_forward_request(chain_id: int, to: str, calldata: str, deadline: int | None = None) -> tuple[dict, str]:
    """Build and sign a ForwardRequest. Returns (request_dict, signature_hex)."""
    account = get_account()
    nonce = _get_nonce(chain_id)
    if deadline is None:
        deadline = int(time.time()) + 600  # 10 minutes

    message = {
        "from": account.address,
        "to": Web3.to_checksum_address(to),
        "nonce": nonce,
        "deadline": deadline,
        "data": calldata,
    }

    typed_data = {
        "types": FORWARD_REQUEST_TYPES,
        "primaryType": "ForwardRequest",
        "domain": _build_domain(chain_id, to),
        "message": message,
    }

    signed = account.sign_message(encode_typed_data(full_message=typed_data))
    return message, "0x" + signed.signature.hex()


# ── Permit signing (EIP-2612) ──

PERMIT_TYPES = {
    "EIP712Domain": [
        {"name": "name", "type": "string"},
        {"name": "version", "type": "string"},
        {"name": "chainId", "type": "uint256"},
        {"name": "verifyingContract", "type": "address"},
    ],
    "Permit": [
        {"name": "owner", "type": "address"},
        {"name": "spender", "type": "address"},
        {"name": "value", "type": "uint256"},
        {"name": "nonce", "type": "uint256"},
        {"name": "deadline", "type": "uint256"},
    ],
}


def _sign_permit(token: str, spender: str, value: int, chain_id: int, deadline: int | None = None) -> dict:
    """Sign an EIP-2612 permit for the given token. Returns PermitData dict for the relayer."""
    account = get_account()
    w3 = get_w3(chain_id)
    token_addr = Web3.to_checksum_address(token)

    if deadline is None:
        deadline = int(time.time()) + 600

    # Read token's EIP-2612 domain (name, version) and nonce
    token_contract = w3.eth.contract(address=token_addr, abi=[
        {"inputs": [], "name": "name", "outputs": [{"type": "string"}], "stateMutability": "view", "type": "function"},
        {"inputs": [], "name": "version", "outputs": [{"type": "string"}], "stateMutability": "view", "type": "function"},
        {"inputs": [{"name": "owner", "type": "address"}], "name": "nonces", "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    ])

    token_name = token_contract.functions.name().call()
    try:
        token_version = token_contract.functions.version().call()
    except Exception:
        token_version = "1"
    permit_nonce = token_contract.functions.nonces(account.address).call()

    domain = {
        "name": token_name,
        "version": token_version,
        "chainId": chain_id,
        "verifyingContract": token_addr,
    }

    message = {
        "owner": account.address,
        "spender": Web3.to_checksum_address(spender),
        "value": value,
        "nonce": permit_nonce,
        "deadline": deadline,
    }

    typed_data = {
        "types": PERMIT_TYPES,
        "primaryType": "Permit",
        "domain": domain,
        "message": message,
    }

    signed = account.sign_message(encode_typed_data(full_message=typed_data))

    return {
        "token": token_addr,
        "spender": Web3.to_checksum_address(spender),
        "value": str(value),
        "deadline": deadline,
        "v": signed.v,
        "r": "0x" + signed.r.to_bytes(32).hex(),
        "s": "0x" + signed.s.to_bytes(32).hex(),
    }


# ── Submit to relayer ──

def _submit_relay(chain_id: int, request: dict, signature: str, permit: dict | None = None) -> dict:
    """Submit signed ForwardRequest to the relayer API."""
    body: dict[str, Any] = {
        "chainId": chain_id,
        "request": request,
        "signature": signature,
    }
    if permit:
        body["permit"] = permit

    resp = httpx.post(f"{_relayer_url()}/relay", json=body, timeout=30)
    data = resp.json()
    if resp.status_code != 200:
        error = data.get("error", "unknown_error")
        message = data.get("message", "")
        raise RuntimeError(f"Relay failed: {error}" + (f" — {message}" if message else ""))
    return data


# ── Public API ──

def relay(contract: str, sig: str, args: list | None, *, chain_id: int = 10) -> dict:
    """Gasless contract write: sign ForwardRequest + submit to relayer.
    Equivalent to `invoke` but user pays zero gas."""
    calldata = "0x" + _encode_calldata(sig, args).hex()
    request, signature = _sign_forward_request(chain_id, contract, calldata)
    result = _submit_relay(chain_id, request, signature)
    return {
        "status": "relayed",
        "txHash": result.get("txHash"),
        "from": request["from"],
        "to": request["to"],
        "function": sig,
        "args": args,
        "gasless": True,
    }


def relay_with_permit(token: str, contract: str, amount: int,
                      sig: str, args: list | None, *, chain_id: int = 10) -> dict:
    """Gasless approve + contract write: sign Permit + ForwardRequest, submit both to relayer.
    Equivalent to `approve-and-invoke` but user pays zero gas and signs zero on-chain txs."""
    calldata = "0x" + _encode_calldata(sig, args).hex()
    permit = _sign_permit(token, contract, amount, chain_id)
    request, signature = _sign_forward_request(chain_id, contract, calldata)
    result = _submit_relay(chain_id, request, signature, permit=permit)
    return {
        "status": "relayed",
        "txHash": result.get("txHash"),
        "from": request["from"],
        "to": request["to"],
        "function": sig,
        "args": args,
        "permit": {"token": token, "amount": str(amount)},
        "gasless": True,
    }


def relay_check(contract: str, *, chain_id: int = 10) -> dict:
    """Check if gasless relay is available for a contract."""
    try:
        forwarder = _forwarder_address(chain_id, contract)
    except Exception as e:
        return {"available": False, "reason": str(e)}

    try:
        resp = httpx.get(f"{_relayer_url()}/relay/health", timeout=5)
        if resp.status_code != 200:
            return {"available": False, "reason": "relayer unhealthy"}
    except Exception:
        return {"available": False, "reason": "relayer unreachable"}

    # Check if the Vault has budget for this contract (sponsor has funded it)
    try:
        resp = httpx.get(
            f"{_relayer_url()}/relay/vault-budget",
            params={"contract": Web3.to_checksum_address(contract)},
            timeout=5,
        )
        if resp.status_code == 200:
            data = resp.json()
            budget = data.get("budget")
            if budget is None:
                return {"available": False, "reason": "gas sponsor vault not configured"}
            if int(budget) <= 0:
                return {"available": False, "reason": "no sponsor budget for this contract"}
    except Exception:
        return {"available": False, "reason": "cannot query vault budget"}

    return {
        "available": True,
        "forwarder": forwarder,
        "relayer": _relayer_url(),
        "contract": contract,
        "chain_id": chain_id,
        "budget": budget,
    }
