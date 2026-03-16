"""XQuote Spec adapter module — centralized management of XQuote EIP-712 type definitions and specParams encoding/decoding.

chain.py only handles generic on-chain calls (returns raw bytes).
This module decodes specParams per XQuoteVerifierSpec's definition and provides the typed-data structure needed for signing.
"""

from __future__ import annotations

from typing import NamedTuple

from eth_abi import decode as abi_decode
from web3 import Web3

from config import settings


# ---------------------------------------------------------------------------
# Complete EIP-712 type definitions (consistent with XQuoteVerifierSpec.VERIFY_TYPEHASH)
# TypeHash: keccak256("Verify(uint256 tweetId,string quoterUsername,uint256 fee,uint256 deadline)")
# ---------------------------------------------------------------------------

EIP712_FULL_TYPES = {
    "EIP712Domain": [
        {"name": "name", "type": "string"},
        {"name": "version", "type": "string"},
        {"name": "chainId", "type": "uint256"},
        {"name": "verifyingContract", "type": "address"},
    ],
    "Verify": [
        {"name": "tweetId", "type": "string"},
        {"name": "quoterUsername", "type": "string"},
        {"name": "fee", "type": "uint256"},
        {"name": "deadline", "type": "uint256"},
    ],
}

DOMAIN = {
    "name": "XQuoteVerifier",
    "version": "1",
    "chainId": settings.chain_id,
    "verifyingContract": Web3.to_checksum_address(settings.contract_address),
}

# ---------------------------------------------------------------------------
# specParams encoding/decoding
# specParams = abi.encode(string tweet_id, string quoter_username, string quote_tweet_id)
# ---------------------------------------------------------------------------

SPEC_PARAMS_TYPES = ["string", "string", "string"]


class SpecParams(NamedTuple):
    tweet_id: str
    quoter_username: str
    quote_tweet_id: str


def decode_spec_params(spec_params: bytes) -> SpecParams:
    """Decode specParams per the XQuoteVerifierSpec definition."""
    tweet_id, quoter_username, quote_tweet_id = abi_decode(
        SPEC_PARAMS_TYPES, spec_params
    )
    return SpecParams(
        tweet_id=tweet_id,
        quoter_username=quoter_username,
        quote_tweet_id=quote_tweet_id,
    )
