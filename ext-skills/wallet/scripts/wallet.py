# Core wallet operations — balance queries, amount conversion, message signing, transaction sending
from __future__ import annotations

import re, json
from decimal import Decimal
from web3 import Web3
from eth_account.messages import encode_defunct, encode_typed_data

try:
    from .chains import CHAINS, get_w3, get_account
except ImportError:
    from chains import CHAINS, get_w3, get_account


# (amount, decimals) -> int  Human-readable amount → on-chain raw integer. e.g. to_raw(1.5, 18) → 1500000000000000000
def to_raw(amount: int | float | str, decimals: int = 18) -> int:
    return int(Decimal(str(amount)) * Decimal(10 ** decimals))

# (raw, decimals, symbol) -> str  On-chain raw integer → human-readable string. e.g. fmt(10**18, 18, "ETH") → "1 ETH"
def fmt(raw: int | str, decimals: int = 18, symbol: str = "") -> str:
    s = f"{Decimal(raw) / Decimal(10 ** decimals):.{decimals}f}".rstrip("0").rstrip(".")
    return f"{s} {symbol}".strip()

# () -> str  Returns the current wallet address, purely local with no RPC connection
def address() -> str:
    return get_account().address

# (chain_id) -> {address, chain_id, balance_raw, balance}  Queries native token balance on the specified chain
def eth_balance(chain_id: int = 10) -> dict:
    w3, account = get_w3(chain_id), get_account()
    bal = w3.eth.get_balance(account.address)
    return {"address": account.address, "chain_id": chain_id,
            "balance_raw": str(bal), "balance": fmt(bal, 18, CHAINS[chain_id]["symbol"])}

# (message) -> {address, message, signature}  EIP-191 plain text signature
def sign_message(message: str) -> dict:
    account = get_account()
    signed = account.sign_message(encode_defunct(text=message))
    return {"address": account.address, "message": message, "signature": "0x" + signed.signature.hex()}

# (typed_data) -> {address, signature, v, r, s}  EIP-712 structured data signature; typed_data can be a dict or JSON file path
def sign_typed_data(typed_data: dict | str) -> dict:
    if isinstance(typed_data, str):
        with open(typed_data) as f:
            typed_data = json.load(f)
    account = get_account()
    signed = account.sign_message(encode_typed_data(full_message=typed_data))
    return {"address": account.address, "signature": "0x" + signed.signature.hex(),
            "v": signed.v, "r": hex(signed.r), "s": hex(signed.s)}

# USDC addresses per chain
USDC = {
    1:     "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    10:    "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85",
    8453:  "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    42161: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831",
}

def all_balances() -> dict:
    """Query ETH and USDC balances across all four chains in parallel."""
    from concurrent.futures import ThreadPoolExecutor, as_completed
    from abi import call as abi_call
    account = get_account()
    owner = account.address

    def _query_chain(chain_id, cfg):
        w3 = get_w3(chain_id)
        eth_bal = w3.eth.get_balance(owner)
        usdc_addr = USDC[chain_id]
        try:
            usdc_raw = abi_call(usdc_addr, "balanceOf(address)->(uint256)", [owner], chain_id=chain_id)
            usdc_formatted = fmt(usdc_raw, 6, "USDC")
        except Exception:
            usdc_raw, usdc_formatted = 0, "0 USDC"
        return cfg["name"], {
            "chain_id": chain_id,
            "eth": {"raw": str(eth_bal), "formatted": fmt(eth_bal, 18, cfg["symbol"])},
            "usdc": {"raw": str(usdc_raw), "formatted": usdc_formatted},
        }

    results = {"address": owner, "chains": {}}
    with ThreadPoolExecutor(max_workers=4) as pool:
        futures = [pool.submit(_query_chain, cid, cfg) for cid, cfg in CHAINS.items()]
        for f in as_completed(futures):
            name, data = f.result()
            results["chains"][name] = data
    return results


# --- Internal transaction helpers (not exposed to agent) ---

def _build_tx(to: str, chain_id: int = 10, value: int = 0, data: bytes | str = b"") -> dict:
    """Construct EIP-1559 transaction dict (without gas estimate)."""
    if isinstance(data, str):
        data = bytes.fromhex(data.removeprefix("0x"))
    w3, account = get_w3(chain_id), get_account()
    base_fee = w3.eth.get_block("latest")["baseFeePerGas"]
    max_priority = w3.eth.max_priority_fee
    return {
        "from": account.address, "to": Web3.to_checksum_address(to),
        "nonce": w3.eth.get_transaction_count(account.address),
        "maxFeePerGas": base_fee * 2 + max_priority,
        "maxPriorityFeePerGas": max_priority,
        "value": value, "data": data, "chainId": chain_id,
    }

def _estimate_gas(to: str, sig: str, args: list | None, *,
                  chain_id: int = 10, value: int = 0) -> dict:
    """Dry-run: estimate gas and return tx preview without sending."""
    from abi import _invoke as _encode
    calldata = _encode(sig, args)
    tx = _build_tx(to, chain_id=chain_id, value=value, data=calldata)
    w3 = get_w3(chain_id)
    try:
        gas = w3.eth.estimate_gas(tx)
    except Exception as e:
        error_data = getattr(e, 'data', None) or _extract_error_data(str(e))
        if error_data:
            from decoder import decode_revert
            reason = decode_revert(error_data, to, chain_id=chain_id)
            return {"status": "would_revert", "reason": reason}
        raise
    gas_price_gwei = tx["maxFeePerGas"] / 1e9
    return {
        "status": "ok",
        "from": tx["from"], "to": tx["to"],
        "function": sig, "args": args,
        "chain_id": chain_id, "value_wei": value,
        "estimated_gas": gas,
        "max_fee_gwei": round(gas_price_gwei, 4),
        "estimated_cost_eth": round(gas * tx["maxFeePerGas"] / 1e18, 8),
    }

def _send_tx(to: str, chain_id: int = 10, value: int = 0, data: bytes | str = b"") -> dict:
    """Send EIP-1559 transaction. Internal only — use abi.invoke()."""
    tx = _build_tx(to, chain_id=chain_id, value=value, data=data)
    w3, account = get_w3(chain_id), get_account()
    try:
        tx["gas"] = w3.eth.estimate_gas(tx)
    except Exception as e:
        error_data = getattr(e, 'data', None) or _extract_error_data(str(e))
        if error_data:
            from decoder import decode_revert
            reason = decode_revert(error_data, to, chain_id=chain_id)
            raise RuntimeError(f"Transaction would revert: {reason}") from e
        raise
    signed = account.sign_transaction(tx)
    receipt = w3.eth.wait_for_transaction_receipt(
        w3.eth.send_raw_transaction(signed.raw_transaction))
    return json.loads(Web3.to_json(receipt))

def _extract_error_data(error_str: str) -> str | None:
    match = re.search(r'0x[0-9a-fA-F]{8,}', error_str)
    return match.group(0) if match else None
