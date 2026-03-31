"""On-chain interaction — reportResult submission + verificationParams read."""

from __future__ import annotations

import logging

from web3 import Web3

from config import settings

logger = logging.getLogger(__name__)

# VerifierBase.reportResult(address dealContract, uint256 dealIndex, uint256 verificationIndex, int8 result, string reason, uint256 expectedFee)
VERIFIER_ABI = [
    {
        "inputs": [
            {"name": "dealContract", "type": "address"},
            {"name": "dealIndex", "type": "uint256"},
            {"name": "verificationIndex", "type": "uint256"},
            {"name": "result", "type": "int8"},
            {"name": "reason", "type": "string"},
            {"name": "expectedFee", "type": "uint256"},
        ],
        "name": "reportResult",
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function",
    },
]

# IDeal.verificationParams(uint256 dealIndex, uint256 verificationIndex)
DEAL_CONTRACT_ABI = [
    {
        "inputs": [
            {"name": "dealIndex", "type": "uint256"},
            {"name": "verificationIndex", "type": "uint256"},
        ],
        "name": "verificationParams",
        "outputs": [
            {"name": "verifier", "type": "address"},
            {"name": "fee", "type": "uint256"},
            {"name": "deadline", "type": "uint256"},
            {"name": "sig", "type": "bytes"},
            {"name": "specParams", "type": "bytes"},
        ],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "inputs": [{"name": "dealIndex", "type": "uint256"}],
        "name": "dealStatus",
        "outputs": [{"name": "", "type": "uint8"}],
        "stateMutability": "view",
        "type": "function",
    },
]

_w3 = None
_account = None
_contract = None


def _init():
    """Lazily initialize the Web3 connection and contract instance."""
    global _w3, _account, _contract
    if _w3 is None:
        _w3 = Web3(Web3.HTTPProvider(settings.rpc_url))
        _account = _w3.eth.account.from_key(settings.private_key)
        _contract = _w3.eth.contract(
            address=Web3.to_checksum_address(settings.contract_address),
            abi=VERIFIER_ABI,
        )
    return _w3, _account, _contract


def report_result(deal_contract: str, deal_index: int, verification_index: int, result: int, reason: str, expected_fee: int) -> str:
    """Call contract reportResult, which callbacks DealContract.onVerificationResult. Returns tx hash.

    expected_fee: the agreed verification fee read from on-chain (USDC raw value); the contract verifies that DealContract has paid this amount.
    """
    w3, account, contract = _init()
    deal_contract_addr = Web3.to_checksum_address(deal_contract)

    call_params = {
        "from": account.address,
        "nonce": w3.eth.get_transaction_count(account.address),
    }
    estimated_gas = contract.functions.reportResult(
        deal_contract_addr, deal_index, verification_index, result, reason, expected_fee,
    ).estimate_gas(call_params)

    latest = w3.eth.get_block("latest")
    base_fee = latest.get("baseFeePerGas", w3.eth.gas_price)
    priority_fee = w3.to_wei(0.5, "gwei")

    tx = contract.functions.reportResult(
        deal_contract_addr, deal_index, verification_index, result, reason, expected_fee,
    ).build_transaction({
        **call_params,
        "gas": int(estimated_gas * 1.2),
        "maxFeePerGas": base_fee * 2 + priority_fee,
        "maxPriorityFeePerGas": priority_fee,
    })

    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    logger.info("reportResult tx sent: %s", tx_hash.hex())

    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
    if receipt["status"] != 1:
        raise RuntimeError(f"reportResult tx failed: {tx_hash.hex()}")

    logger.info("reportResult tx confirmed: %s (gas used: %d)", tx_hash.hex(), receipt["gasUsed"])
    return tx_hash.hex()


# ---------------------------------------------------------------------------
# Read DealContract's verificationParams (on-chain view call, authoritative source)
# ---------------------------------------------------------------------------

def read_verification_params(deal_contract_addr: str, deal_index: int, verification_index: int) -> dict:
    """Read verification parameters via verificationParams (authoritative source).

    Returns common fields; specParams remains as raw bytes for the caller to decode per spec definition.

    Returns: {
        "verifier": str,
        "fee": int,
        "deadline": int,
        "sig": bytes,
        "spec_params": bytes,
    }
    """
    w3, _, _ = _init()
    addr = Web3.to_checksum_address(deal_contract_addr)
    deal_obj = w3.eth.contract(address=addr, abi=DEAL_CONTRACT_ABI)

    verifier, fee, deadline, sig, spec_params = deal_obj.functions.verificationParams(
        deal_index, verification_index
    ).call()

    return {
        "verifier": verifier,
        "fee": fee,
        "deadline": deadline,
        "sig": sig,
        "spec_params": spec_params,
    }


def read_deal_status(deal_contract_addr: str, deal_index: int) -> int:
    """Read dealStatus from the DealContract (on-chain view call)."""
    w3, _, _ = _init()
    addr = Web3.to_checksum_address(deal_contract_addr)
    deal_obj = w3.eth.contract(address=addr, abi=DEAL_CONTRACT_ABI)
    return deal_obj.functions.dealStatus(deal_index).call()


# ---------------------------------------------------------------------------
# TwitterRegistry — check if a username has a verified on-chain binding
# ---------------------------------------------------------------------------

TWITTER_REGISTRY_ABI = [
    {
        "inputs": [{"name": "username", "type": "string"}],
        "name": "getAddressByUsername",
        "outputs": [{"name": "", "type": "address"}],
        "stateMutability": "view",
        "type": "function",
    },
]


def is_twitter_verified(username: str) -> bool:
    """Check if a Twitter username has a verified binding in TwitterRegistry.

    Returns True if the username is bound to a non-zero address.
    Returns False if the registry is not configured or the username is not bound.
    """
    if not settings.twitter_registry_address:
        return False
    w3, _, _ = _init()
    addr = Web3.to_checksum_address(settings.twitter_registry_address)
    registry = w3.eth.contract(address=addr, abi=TWITTER_REGISTRY_ABI)
    bound_addr = registry.functions.getAddressByUsername(username).call()
    return bound_addr != "0x" + "0" * 40
