"""EIP-712 signature generation — corresponds to the XQuoteVerifierSpec Verify struct."""

from __future__ import annotations

from typing import NamedTuple

from eth_account import Account
from eth_account.messages import encode_defunct

from config import settings
from x_quote_spec import EIP712_FULL_TYPES, DOMAIN


class SignResult(NamedTuple):
    signature: str
    deadline: int


def get_owner_address() -> str:
    """Derive the owner EOA address from the private key."""
    acct = Account.from_key(settings.private_key)
    return acct.address.lower()


def sign_platform_message(message: str) -> str:
    """Sign a platform authentication message (personal_sign), used for verifier registration."""
    acct = Account.from_key(settings.private_key)
    msg = encode_defunct(text=message)
    signed = acct.sign_message(msg)
    return signed.signature.hex()


def sign_verify_request(
    tweet_id: str,
    quoter_username: str,
    fee: int,
    deadline: int,
    nonce: str,
) -> SignResult:
    """Generate an EIP-712 signature corresponding to XQuoteVerifierSpec.check's VERIFY_TYPEHASH."""

    typed_data = {
        "types": EIP712_FULL_TYPES,
        "primaryType": "Verify",
        "domain": DOMAIN,
        "message": {
            "tweetId": tweet_id,
            "quoterUsername": quoter_username,
            "fee": fee,
            "deadline": deadline,
            "nonce": nonce,
        },
    }

    acct = Account.from_key(settings.private_key)
    signed = acct.sign_typed_data(full_message=typed_data)

    return SignResult(
        signature=signed.signature.hex(),
        deadline=deadline,
    )
