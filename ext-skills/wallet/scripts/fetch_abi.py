# Fetch and cache contract ABI from Sourcify/Etherscan — ABI is immutable, cache never expires

import json
import os
from pathlib import Path
import httpx

ETHERSCAN_V2_BASE = "https://api.etherscan.io/v2/api"

_SKILL_DIR = Path(__file__).resolve().parent.parent

def _cache_path(address: str, chain_id: int) -> Path:
    return _SKILL_DIR / "abis" / f"{address.lower()}.json"

# (address, chain_id) -> str  Fetch ABI from Sourcify/Etherscan, cache locally, return path to ABI JSON file
def fetch_abi(address: str, chain_id: int = 8453) -> str:
    cached = _cache_path(address, chain_id)
    if cached.exists():
        return str(cached)

    abi = _fetch_from_abi_proxy(address, chain_id)
    if abi is None:
        abi = _fetch_from_sourcify(address, chain_id)
    if abi is None:
        abi = _fetch_from_etherscan(address, chain_id)
    if abi is None:
        raise RuntimeError(
            f"Cannot fetch ABI for {address} on chain {chain_id}: "
            "contract source not verified on Sourcify or Etherscan"
        )

    cached.parent.mkdir(parents=True, exist_ok=True)
    cached.write_text(json.dumps(abi, indent=2))
    return str(cached)

def _fetch_from_abi_proxy(address: str, chain_id: int) -> list[dict] | None:
    proxy_url = os.environ.get("ABI_PROXY_URL")
    if not proxy_url:
        return None
    url = f"{proxy_url}/abi/{chain_id}/{address}"
    try:
        r = httpx.get(url, timeout=10)
        if r.status_code != 200:
            return None
        data = r.json()
        if data.get("status") == "1" and data.get("result"):
            return json.loads(data["result"]) if isinstance(data["result"], str) else data["result"]
        return None
    except Exception:
        return None

def _fetch_from_sourcify(address: str, chain_id: int) -> list[dict] | None:
    url = f"https://sourcify.dev/server/files/any/{chain_id}/{address}"
    try:
        r = httpx.get(url, timeout=15)
        if r.status_code != 200:
            return None
        data = r.json()
        files = data.get("files", []) if isinstance(data, dict) else data
        for f in files:
            if f.get("name") == "metadata.json":
                metadata = json.loads(f["content"])
                return metadata["output"]["abi"]
        return None
    except Exception:
        return None

def _fetch_from_etherscan(address: str, chain_id: int) -> list[dict] | None:
    api_key = os.environ.get("ETHERSCAN_API_KEY")
    if not api_key:
        return None
    url = f"{ETHERSCAN_V2_BASE}?chainid={chain_id}&module=contract&action=getabi&address={address}&apikey={api_key}"
    try:
        r = httpx.get(url, timeout=15)
        if r.status_code != 200:
            return None
        data = r.json()
        if data.get("status") == "1" and data.get("result"):
            return json.loads(data["result"])
        return None
    except Exception:
        return None
