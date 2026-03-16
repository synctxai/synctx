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
            f"Copy .env.example to .env and fill in your private key:\n"
            f"  cp {env_path.parent / '.env.example'} {env_path}"
        )
    return Web3().eth.account.from_key(key)
