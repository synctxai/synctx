"""Verifier configuration, reads from .env."""

from pydantic_settings import BaseSettings

SIGN_DEADLINE_SECONDS = 7 * 24 * 3600


class Settings(BaseSettings):

    # --- Verifier Core ---

    # Verifier owner private key (used for platform signing and on-chain transactions)
    private_key: str

    # Verifier contract address
    contract_address: str

    # Chain ID where the contract is deployed
    chain_id: int

    # Platform MCP service URL
    platform_url: str

    # RPC URL
    rpc_url: str

    # Polling interval (seconds)
    poll_interval: int

    # Verification fee (USDC, 6 decimal precision, 10000 = 0.01 USDC)
    verify_fee: int

    # --- Twitter API (follow verification module) ---

    # RapidAPI key (used by twitter-api45)
    rapidapi_key: str = ""

    # twitterapi.io standalone API key
    twitterapi_io_key: str = ""

    # HTTP request timeout (seconds)
    request_timeout: int = 15

    # Provider host address
    twitter_api_host: str = "twitter-api45.p.rapidapi.com"
    twitterapi_io_base_url: str = "https://api.twitterapi.io"

    model_config = {"env_file": ".env", "env_file_encoding": "utf-8", "extra": "ignore"}


settings = Settings()
