"""XFollow Spec adapter module — centralized management of XFollow EIP-712 type definitions and specParams encoding/decoding.

chain.py only handles generic on-chain calls (returns raw bytes).
This module decodes specParams per XFollowVerifierSpec's definition and provides the typed-data structure needed for signing.
"""

from __future__ import annotations

from typing import NamedTuple

from eth_abi import decode as abi_decode
from web3 import Web3

from config import settings


# ---------------------------------------------------------------------------
# Complete EIP-712 type definitions (consistent with XFollowVerifierSpec.VERIFY_TYPEHASH)
# TypeHash: keccak256("Verify(string followerUsername,string targetUsername,uint256 fee,uint256 deadline)")
# ---------------------------------------------------------------------------

EIP712_FULL_TYPES = {
    "EIP712Domain": [
        {"name": "name", "type": "string"},
        {"name": "version", "type": "string"},
        {"name": "chainId", "type": "uint256"},
        {"name": "verifyingContract", "type": "address"},
    ],
    "Verify": [
        {"name": "followerUsername", "type": "string"},
        {"name": "targetUsername", "type": "string"},
        {"name": "fee", "type": "uint256"},
        {"name": "deadline", "type": "uint256"},
    ],
}

DOMAIN = {
    "name": "XFollowVerifier",
    "version": "1",
    "chainId": settings.chain_id,
    "verifyingContract": Web3.to_checksum_address(settings.contract_address),
}

# ---------------------------------------------------------------------------
# specParams encoding/decoding
# specParams = abi.encode(string follower_username, string target_username)
# ---------------------------------------------------------------------------

SPEC_PARAMS_TYPES = ["string", "string"]


class SpecParams(NamedTuple):
    follower_username: str
    target_username: str


def decode_spec_params(spec_params: bytes) -> SpecParams:
    """Decode specParams per the XFollowVerifierSpec definition."""
    follower_username, target_username = abi_decode(
        SPEC_PARAMS_TYPES, spec_params
    )
    return SpecParams(
        follower_username=follower_username,
        target_username=target_username,
    )
