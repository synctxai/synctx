# Chain configuration and connection management — multi-chain RPC endpoints, Web3 instances, account derivation

import os
from pathlib import Path
from dotenv import load_dotenv
from web3 import Web3

load_dotenv(Path(__file__).resolve().parent.parent / ".env")

# Chain config table: keys are chain_id, values contain rpc endpoint, display name, native token symbol
CHAINS = {
    10:    {"rpc": "https://mainnet.optimism.io",  "name": "Optimism",     "symbol": "ETH"},
    1:     {"rpc": "https://eth.llamarpc.com",     "name": "Ethereum",     "symbol": "ETH"},
    8453:  {"rpc": "https://mainnet.base.org",     "name": "Base",         "symbol": "ETH"},
    42161: {"rpc": "https://arb1.arbitrum.io/rpc", "name": "Arbitrum One", "symbol": "ETH"},
}

# (chain_id) -> Web3  Returns a Web3 instance for the specified chain, no private key required
def get_w3(chain_id: int = 10) -> Web3:
    return Web3(Web3.HTTPProvider(CHAINS[chain_id]["rpc"]))

# () -> LocalAccount  Derives local account from PRIVATE_KEY in .env, purely local with no RPC connection
def get_account():
    key = os.environ.get("PRIVATE_KEY")
    if not key:
        env_path = Path(__file__).resolve().parent.parent / ".env"
        raise RuntimeError(
            f"PRIVATE_KEY not found. "
            f"Run `generate-wallet` to create a new wallet, "
            f"or set PRIVATE_KEY in {env_path} to import an existing one."
        )
    return Web3().eth.account.from_key(key)


def check_wallet() -> dict:
    """Check wallet configuration status. Returns ready/missing/invalid state."""
    env_path = Path(__file__).resolve().parent.parent / ".env"
    if not env_path.exists():
        return {"status": "no_env", "env_path": str(env_path)}
    key = os.environ.get("PRIVATE_KEY", "")
    if not key:
        return {"status": "no_key", "env_path": str(env_path)}
    try:
        account = Web3().eth.account.from_key(key)
        return {"status": "ok", "address": account.address}
    except Exception as e:
        return {"status": "invalid_key", "error": str(e), "env_path": str(env_path)}


def generate_wallet() -> dict:
    """Generate a new wallet and save the private key to .env. Returns address and key path."""
    env_path = Path(__file__).resolve().parent.parent / ".env"
    account = Web3().eth.account.create()
    key_hex = account.key.hex().removeprefix("0x")

    # Build .env content preserving existing entries
    lines = []
    etherscan_found = False
    if env_path.exists():
        for line in env_path.read_text().splitlines():
            if line.startswith("PRIVATE_KEY"):
                continue
            if line.startswith("ETHERSCAN_API_KEY"):
                etherscan_found = True
            lines.append(line)

    # Insert PRIVATE_KEY at the top (after any leading comments)
    insert_idx = 0
    for i, line in enumerate(lines):
        if not line.startswith("#") and line.strip():
            insert_idx = i
            break
        insert_idx = i + 1
    lines.insert(insert_idx, f"PRIVATE_KEY={key_hex}")

    if not etherscan_found:
        lines.append("")
        lines.append("# (optional) Etherscan API key, used as fallback when Sourcify unavailable for fetch_abi")
        lines.append("ETHERSCAN_API_KEY=")

    env_path.write_text("\n".join(lines) + "\n")
    os.environ["PRIVATE_KEY"] = key_hex

    return {
        "address": account.address,
        "env_path": str(env_path),
        "message": f"Wallet created. Address: {account.address}. "
                   f"Private key saved to {env_path}. "
                   f"Fund this address before sending transactions."
    }
