"""XFollow Spec adapter module — centralized management of XFollow EIP-712 type definitions and specParams encoding/decoding.

Campaign model: signature is per-campaign (target_user_id only, no follower_user_id).
specParams is per-claim (follower_user_id + target_user_id).
"""

from __future__ import annotations

from typing import NamedTuple

from eth_abi import decode as abi_decode
from web3 import Web3

from config import settings


# ---------------------------------------------------------------------------
# Complete EIP-712 type definitions (consistent with XFollowVerifierSpec.VERIFY_TYPEHASH)
# TypeHash: keccak256("Verify(uint64 targetUserId,uint256 fee,uint256 deadline)")
# ---------------------------------------------------------------------------

EIP712_FULL_TYPES = {
    "EIP712Domain": [
        {"name": "name", "type": "string"},
        {"name": "version", "type": "string"},
        {"name": "chainId", "type": "uint256"},
        {"name": "verifyingContract", "type": "address"},
    ],
    "Verify": [
        {"name": "targetUserId", "type": "uint64"},
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
# specParams encoding/decoding (per-claim)
# specParams = abi.encode(uint64 follower_user_id, uint64 target_user_id)
# ---------------------------------------------------------------------------

SPEC_PARAMS_TYPES = ["uint64", "uint64"]


class SpecParams(NamedTuple):
    follower_user_id: int
    target_user_id: int


def decode_spec_params(spec_params: bytes) -> SpecParams:
    """Decode specParams per the XFollowVerifierSpec definition."""
    follower_user_id, target_user_id = abi_decode(
        SPEC_PARAMS_TYPES, spec_params
    )
    return SpecParams(
        follower_user_id=follower_user_id,
        target_user_id=target_user_id,
    )
