"""Verifier configuration, reads from .env."""

from __future__ import annotations

import json

from pydantic_settings import BaseSettings

SIGN_DEADLINE_SECONDS = 3600


class Settings(BaseSettings):
    private_key: str
    contract_address: str
    chain_id: int
    platform_url: str
    rpc_url: str
    poll_interval: int = 5
    verify_fee: int
    request_timeout: int = 10

    # JSON object keyed by "<underlying_lowercase>:<quote_lowercase>"
    pair_feeds_json: str = "{}"

    model_config = {"env_file": ".env", "env_file_encoding": "utf-8", "extra": "ignore"}

    def pair_feeds(self) -> dict[str, dict]:
        raw = self.pair_feeds_json.strip() or "{}"
        loaded = json.loads(raw)
        if not isinstance(loaded, dict):
            raise ValueError("pair_feeds_json must decode to an object")
        return loaded


settings = Settings()
