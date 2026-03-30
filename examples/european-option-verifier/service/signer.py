"""EIP-712 signatures for SettlementPriceVerifierSpec."""

from __future__ import annotations

from typing import NamedTuple

from eth_account import Account
from eth_account.messages import encode_defunct

from config import settings

EIP712_FULL_TYPES = {
    "EIP712Domain": [
        {"name": "name", "type": "string"},
        {"name": "version", "type": "string"},
        {"name": "chainId", "type": "uint256"},
        {"name": "verifyingContract", "type": "address"},
    ],
    "Verify": [
        {"name": "underlying", "type": "address"},
        {"name": "quoteToken", "type": "address"},
        {"name": "expiry", "type": "uint256"},
        {"name": "settlementWindow", "type": "uint256"},
        {"name": "fee", "type": "uint256"},
        {"name": "deadline", "type": "uint256"},
    ],
}

DOMAIN = {
    "name": "SettlementPriceVerifier",
    "version": "1",
    "chainId": settings.chain_id,
    "verifyingContract": settings.contract_address,
}


class SignResult(NamedTuple):
    signature: str
    deadline: int


def get_owner_address() -> str:
    acct = Account.from_key(settings.private_key)
    return acct.address.lower()


def sign_platform_message(message: str) -> str:
    acct = Account.from_key(settings.private_key)
    msg = encode_defunct(text=message)
    signed = acct.sign_message(msg)
    return signed.signature.hex()


def sign_verify_request(
    underlying: str,
    quote_token: str,
    expiry: int,
    settlement_window: int,
    fee: int,
    deadline: int,
) -> SignResult:
    typed_data = {
        "types": EIP712_FULL_TYPES,
        "primaryType": "Verify",
        "domain": DOMAIN,
        "message": {
            "underlying": underlying,
            "quoteToken": quote_token,
            "expiry": expiry,
            "settlementWindow": settlement_window,
            "fee": fee,
            "deadline": deadline,
        },
    }

    acct = Account.from_key(settings.private_key)
    signed = acct.sign_typed_data(full_message=typed_data)

    return SignResult(signature=signed.signature.hex(), deadline=deadline)
