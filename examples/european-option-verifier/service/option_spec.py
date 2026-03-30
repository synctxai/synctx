"""Decode settlement price verifier specParams."""

from __future__ import annotations

from eth_abi import decode
from web3 import Web3

from models import OptionVerificationSpec


def decode_spec_params(raw: bytes) -> OptionVerificationSpec:
    underlying, quote_token, expiry, settlement_window = decode(
        ["address", "address", "uint256", "uint256"],
        raw,
    )
    return OptionVerificationSpec(
        underlying=Web3.to_checksum_address(underlying),
        quote_token=Web3.to_checksum_address(quote_token),
        expiry=int(expiry),
        settlement_window=int(settlement_window),
    )
