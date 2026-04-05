from __future__ import annotations

from web3 import Web3
from eth_abi import decode
from eth_abi.exceptions import DecodingError
from chains import get_w3
from abi import _load, _serialize

def decode_revert(error_data: str, contract_address: str | None = None, *, chain_id: int = 8453) -> str:
    data = bytes.fromhex(error_data.removeprefix("0x"))
    # Error(string)
    if data[:4] == bytes.fromhex("08c379a2"):
        try:
            (reason,) = decode(["string"], data[4:])
            return f"Error: {reason}"
        except DecodingError: pass
    # Panic(uint256)
    if data[:4] == bytes.fromhex("4e487b71"):
        try:
            (code,) = decode(["uint256"], data[4:])
            reasons = {0x01:"assertion failed", 0x11:"overflow", 0x12:"div by zero",
                       0x21:"invalid enum", 0x32:"out of bounds", 0x41:"out of memory"}
            return f"Panic: {reasons.get(code, f'code {code}')}"
        except DecodingError: pass
    # Custom errors via ABI
    if contract_address:
        try:
            abi = _load(contract_address, chain_id=chain_id)
            for item in abi:
                if item.get("type") != "error": continue
                types = [inp["type"] for inp in item.get("inputs", [])]
                sig = f"{item['name']}({','.join(types)})"
                if Web3.keccak(text=sig)[:4] == data[:4]:
                    if types:
                        values = decode(types, data[4:])
                        params = ", ".join(f"{t}={_serialize(v)}" for t, v in zip(types, values))
                        return f"{item['name']}({params})"
                    return f"{item['name']}()"
        except Exception: pass
    return f"Unknown error: 0x{data.hex()}"

def decode_logs(tx_hash: str, contract_address: str, *, chain_id: int = 8453) -> list[dict]:
    w3 = get_w3(chain_id)
    receipt = w3.eth.get_transaction_receipt(tx_hash)
    abi = _load(contract_address, chain_id=chain_id)
    event_map = {}
    for item in abi:
        if item.get("type") != "event": continue
        types = [inp["type"] for inp in item.get("inputs", [])]
        sig = f"{item['name']}({','.join(types)})"
        event_map[Web3.keccak(text=sig)] = {
            "name": item["name"], "types": types,
            "indexed": [inp.get("indexed", False) for inp in item.get("inputs", [])],
            "names": [inp["name"] for inp in item.get("inputs", [])],
        }
    results = []
    for log in receipt.get("logs", []):
        topics = log.get("topics", [])
        if not topics: continue
        t0 = topics[0] if isinstance(topics[0], bytes) else bytes.fromhex(
            topics[0].hex() if hasattr(topics[0], 'hex') else topics[0].removeprefix("0x"))
        ev = event_map.get(t0)
        if not ev: continue
        decoded, ti = {}, 1
        non_idx_types, non_idx_names = [], []
        for name, typ, indexed in zip(ev["names"], ev["types"], ev["indexed"]):
            if indexed and ti < len(topics):
                raw = topics[ti]
                try: (val,) = decode([typ], raw if isinstance(raw, bytes) else bytes.fromhex(raw.hex())); decoded[name] = _serialize(val)
                except: decoded[name] = "0x" + (raw.hex() if isinstance(raw, bytes) else raw.hex())
                ti += 1
            elif not indexed:
                non_idx_types.append(typ); non_idx_names.append(name)
        if non_idx_types:
            d = log.get("data", b"")
            if isinstance(d, str): d = bytes.fromhex(d.removeprefix("0x"))
            elif hasattr(d, 'hex'): d = bytes.fromhex(d.hex())
            try:
                for n, v in zip(non_idx_names, decode(non_idx_types, d)): decoded[n] = _serialize(v)
            except: decoded["_raw_data"] = "0x" + d.hex()
        results.append({"event": ev["name"], **decoded})
    return results
