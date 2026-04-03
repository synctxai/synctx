"""Gasless meta-transaction relay — BySig architecture (MetaTxMixin embedded in each contract).

Architecture overview
---------------------
Each target contract embeds MetaTxMixin which provides:
  - Its own EIP-712 domain (name, version "1", chainId, verifyingContract)
  - Per-action *BySig functions (e.g. createDealBySig, updateDealBySig)
  - nonces(address) for replay protection

There is NO external SyncTxForwarder.  The relayer accepts pre-encoded BySig
calldata and submits the on-chain transaction on behalf of the user.

Typical flow
~~~~~~~~~~~~
1. Caller builds action-specific EIP-712 types + message (business params).
2. relay_bysig() fills in signer / relayer / nonce / deadline, signs the typed
   data, optionally signs an EIP-2612 permit, encodes the full BySig calldata,
   and submits it to the relayer.
3. The relayer verifies the signature and submits the transaction on-chain.

Relayer API contract
~~~~~~~~~~~~~~~~~~~~
POST /relay  -> { chainId, contract, calldata, signer, nonce }
GET  /relay/nonce?address=&contract=&chainId=
GET  /relay/relayer-address
GET  /relay/health
GET  /relay/vault-budget?contract=
"""
from __future__ import annotations

import os, time
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


# ── Relayer URL discovery (auto-discovered, zero user configuration) ──

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
    except Exception as e:
        raise RuntimeError(f"Cannot discover relayer URL from platform /api/config: {e}") from e
    raise RuntimeError("Cannot discover relayer URL: relayerUrl not found in /api/config response")


# ── Relayer address (the EOA that submits on-chain txs) ──

_relayer_address_cache: str | None = None


def _get_relayer_address() -> str:
    """Get the official relayer submitter address (cached)."""
    global _relayer_address_cache
    if _relayer_address_cache is not None:
        return _relayer_address_cache
    resp = httpx.get(f"{_relayer_url()}/relay/relayer-address", timeout=5)
    resp.raise_for_status()
    addr = resp.json()["relayer"]
    _relayer_address_cache = Web3.to_checksum_address(addr)
    return _relayer_address_cache


# ── Nonce (per-contract, from MetaTxMixin) ──

def _get_nonce(chain_id: int, contract: str) -> int:
    """Fetch user's current meta-tx nonce from the target contract via relayer API."""
    account = get_account()
    url = f"{_relayer_url()}/relay/nonce"
    resp = httpx.get(url, params={
        "address": account.address,
        "contract": Web3.to_checksum_address(contract),
        "chainId": chain_id,
    }, timeout=10)
    resp.raise_for_status()
    return resp.json()["nonce"]


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

_ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"
_ZERO_BYTES32 = "0x" + "00" * 32


def _sign_permit(token: str, spender: str, value: int, chain_id: int, deadline: int | None = None) -> dict:
    """Sign an EIP-2612 permit for the given token. Returns PermitData dict."""
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
        "value": value,
        "deadline": deadline,
        "v": signed.v,
        "r": "0x" + signed.r.to_bytes(32).hex(),
        "s": "0x" + signed.s.to_bytes(32).hex(),
    }


# ── Submit to relayer ──

def _submit_relay(chain_id: int, contract: str, calldata: str, signer: str, nonce: int) -> dict:
    """Submit pre-encoded BySig calldata to the relayer."""
    body = {
        "chainId": chain_id,
        "contract": Web3.to_checksum_address(contract),
        "calldata": calldata,
        "signer": signer,
        "nonce": nonce,
    }
    resp = httpx.post(f"{_relayer_url()}/relay", json=body, timeout=30)
    data = resp.json()
    if resp.status_code != 200:
        error = data.get("error", "unknown_error")
        message = data.get("message", "")
        raise RuntimeError(f"Relay failed: {error}" + (f" — {message}" if message else ""))
    return data


# ── Helpers for tuple encoding ──

def _build_zero_permit_tuple() -> tuple:
    """Build a zero PermitData tuple (no permit)."""
    return (_ZERO_ADDRESS, 0, 0, 0, bytes.fromhex("00" * 32), bytes.fromhex("00" * 32))


def _build_permit_tuple(permit: dict) -> tuple:
    """Build a PermitData tuple from a signed permit dict."""
    return (
        permit["token"],
        permit["value"],
        permit["deadline"],
        permit["v"],
        bytes.fromhex(permit["r"].removeprefix("0x")),
        bytes.fromhex(permit["s"].removeprefix("0x")),
    )


def _build_proof_tuple(signer: str, relayer: str, nonce: int, deadline: int, signature: bytes) -> tuple:
    """Build a MetaTxProof tuple."""
    return (
        Web3.to_checksum_address(signer),
        Web3.to_checksum_address(relayer),
        nonce,
        deadline,
        signature,
    )


# ── Public API: relay_bysig ──

def relay_bysig(
    contract: str,
    domain_name: str,
    eip712_types: dict,
    primary_type: str,
    business_message: dict,
    bysig_sig: str,
    business_args: list,
    *,
    chain_id: int = 10,
    permit_token: str | None = None,
    permit_amount: int = 0,
    deadline: int | None = None,
    has_permit: bool = True,
) -> dict:
    """Gasless BySig meta-transaction: sign action-specific EIP-712 message + submit to relayer.

    Parameters
    ----------
    contract : str
        Target contract address (has MetaTxMixin embedded).
    domain_name : str
        EIP-712 domain name for the target contract (e.g. "SyncTxEscrow").
    eip712_types : dict
        Action-specific EIP-712 types (WITHOUT EIP712Domain).
        Example: {"CreateDealBySig": [{"name": "maker", "type": "address"}, ...]}
    primary_type : str
        Primary type name, e.g. "CreateDealBySig".
    business_message : dict
        Business parameters for the EIP-712 message.  The fields ``signer``,
        ``relayer``, ``nonce``, and ``deadline`` are auto-filled by this function.
    bysig_sig : str
        Full BySig function ABI signature for calldata encoding, e.g.
        "createDealBySig(address,uint256,...,(address,uint256,uint256,uint8,bytes32,bytes32),(address,address,uint256,uint256,bytes))".
    business_args : list
        Positional arguments for the business portion of the BySig call.
        The permit tuple and proof tuple are appended automatically.
    chain_id : int
        Target chain ID (default: 10 / Optimism).
    permit_token : str | None
        If set, sign an EIP-2612 permit for this token (spender = contract).
    permit_amount : int
        Amount to approve via permit (ignored if permit_token is None).
    deadline : int | None
        Unix timestamp deadline; defaults to now + 600 seconds (10 minutes).
    has_permit : bool
        Whether the BySig function takes a PermitData parameter before MetaTxProof.
        True for createDealBySig, acceptBySig (EuropeanOption), requestVerificationBySig.
        False for acceptBySig (XQuote), claimDoneBySig, confirmAndPayBySig,
        proposeSettlementBySig, confirmSettlementBySig, claimBySig.

    Returns
    -------
    dict
        Relay result with status, txHash, etc.
    """
    account = get_account()
    contract = Web3.to_checksum_address(contract)
    nonce = _get_nonce(chain_id, contract)
    relayer_address = _get_relayer_address()

    if deadline is None:
        deadline = int(time.time()) + 600

    # Fill protocol fields into the business message
    business_message["signer"] = account.address
    business_message["relayer"] = relayer_address
    business_message["nonce"] = nonce
    business_message["deadline"] = deadline

    # Build full EIP-712 typed data
    full_types = {
        "EIP712Domain": [
            {"name": "name", "type": "string"},
            {"name": "version", "type": "string"},
            {"name": "chainId", "type": "uint256"},
            {"name": "verifyingContract", "type": "address"},
        ],
        **eip712_types,
    }

    domain = {
        "name": domain_name,
        "version": "1",
        "chainId": chain_id,
        "verifyingContract": contract,
    }

    typed_data = {
        "types": full_types,
        "primaryType": primary_type,
        "domain": domain,
        "message": business_message,
    }

    signed = account.sign_message(encode_typed_data(full_message=typed_data))
    signature_bytes = signed.signature

    # Build permit tuple (only if function takes PermitData)
    if has_permit:
        if permit_token:
            permit = _sign_permit(permit_token, contract, permit_amount, chain_id, deadline)
            permit_tuple = _build_permit_tuple(permit)
        else:
            permit_tuple = _build_zero_permit_tuple()

    # Build proof tuple
    proof_tuple = _build_proof_tuple(
        signer=account.address,
        relayer=relayer_address,
        nonce=nonce,
        deadline=deadline,
        signature=signature_bytes,
    )

    # Assemble full args
    if has_permit:
        full_args = list(business_args) + [permit_tuple, proof_tuple]
    else:
        full_args = list(business_args) + [proof_tuple]

    # Encode BySig calldata
    calldata = "0x" + _encode_calldata(bysig_sig, full_args).hex()

    # Submit to relayer
    result = _submit_relay(chain_id, contract, calldata, account.address, nonce)

    return {
        "status": "relayed",
        "txHash": result.get("txHash"),
        "signer": account.address,
        "contract": contract,
        "primaryType": primary_type,
        "nonce": nonce,
        "gasless": True,
        **({"permit": {"token": permit_token, "amount": str(permit_amount)}} if permit_token else {}),
    }


# ── Deprecated public API (clear error messages) ──

def relay(*args: Any, **kwargs: Any) -> dict:
    """DEPRECATED — the SyncTxForwarder architecture has been removed."""
    raise RuntimeError(
        "relay() is deprecated. Use relay_bysig() with per-action EIP-712 types. "
        "See relay.py module docstring for the new BySig architecture."
    )


def relay_with_permit(*args: Any, **kwargs: Any) -> dict:
    """DEPRECATED — the SyncTxForwarder architecture has been removed."""
    raise RuntimeError(
        "relay_with_permit() is deprecated. Use relay_bysig() with "
        "permit_token/permit_amount params."
    )


# ── Relay availability check ──

def relay_check(contract: str, *, chain_id: int = 10) -> dict:
    """Check if gasless relay is available for a contract.

    Verifies:
    - Relayer is reachable and healthy
    - Gas sponsor vault has budget for the contract
    - Contract supports MetaTxMixin (has nonces() function)
    """
    contract = Web3.to_checksum_address(contract)

    # Check relayer discovery
    try:
        relayer = _relayer_url()
    except Exception as e:
        return {"available": False, "reason": f"relayer discovery failed: {e}"}

    # Check relayer health
    try:
        resp = httpx.get(f"{relayer}/relay/health", timeout=5)
        if resp.status_code != 200:
            return {"available": False, "reason": "relayer unhealthy"}
    except Exception:
        return {"available": False, "reason": "relayer unreachable"}

    # Check vault budget
    try:
        resp = httpx.get(
            f"{relayer}/relay/vault-budget",
            params={"contract": contract},
            timeout=5,
        )
        if resp.status_code != 200:
            return {"available": False, "reason": f"vault-budget endpoint returned {resp.status_code}"}
        data = resp.json()
        budget = data.get("budget")
        if budget is None:
            return {"available": False, "reason": "gas sponsor vault not configured"}
        if int(budget) <= 0:
            return {"available": False, "reason": "no sponsor budget for this contract"}
    except Exception:
        return {"available": False, "reason": "cannot query vault budget"}

    # Check contract supports MetaTxMixin by calling nonces(address(0))
    try:
        w3 = get_w3(chain_id)
        nonces_contract = w3.eth.contract(address=contract, abi=[
            {"inputs": [{"name": "owner", "type": "address"}], "name": "nonces",
             "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
        ])
        nonces_contract.functions.nonces(_ZERO_ADDRESS).call()
    except Exception:
        return {"available": False, "reason": "contract does not support MetaTxMixin (nonces() call failed)"}

    return {
        "available": True,
        "relayer": relayer,
        "contract": contract,
        "chain_id": chain_id,
        "budget": budget,
    }
