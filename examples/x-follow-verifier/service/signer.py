"""EIP-712 signature generation — corresponds to the XFollowVerifierSpec Verify struct (campaign model).

Per-campaign signature: signs target_user_id + fee + deadline.
No follower_user_id in signature (each claim has a different follower).
"""

from __future__ import annotations

from typing import NamedTuple

from eth_account import Account
from eth_account.messages import encode_defunct

from config import settings
from x_follow_spec import EIP712_FULL_TYPES, DOMAIN


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
    target_user_id: int,
    fee: int,
    deadline: int,
) -> SignResult:
    """Generate an EIP-712 signature corresponding to XFollowVerifierSpec.check's VERIFY_TYPEHASH.

    Per-campaign signature: target_user_id + fee + deadline.
    """

    typed_data = {
        "types": EIP712_FULL_TYPES,
        "primaryType": "Verify",
        "domain": DOMAIN,
        "message": {
            "targetUserId": target_user_id,
            "fee": fee,
            "deadline": deadline,
        },
    }

    acct = Account.from_key(settings.private_key)
    signed = acct.sign_typed_data(full_message=typed_data)

    return SignResult(
        signature=signed.signature.hex(),
        deadline=deadline,
    )
