"""On-chain interaction for the settlement price verifier."""

from __future__ import annotations

import logging

from web3 import Web3

from config import settings

logger = logging.getLogger(__name__)

VERIFIER_ABI = [
    {
        "inputs": [
            {"name": "dealContract", "type": "address"},
            {"name": "dealIndex", "type": "uint256"},
            {"name": "verificationIndex", "type": "uint256"},
            {"name": "settlementPrice", "type": "uint256"},
            {"name": "reason", "type": "string"},
            {"name": "expectedFee", "type": "uint256"},
        ],
        "name": "reportSettlementPrice",
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function",
    },
    {
        "inputs": [
            {"name": "dealContract", "type": "address"},
            {"name": "dealIndex", "type": "uint256"},
            {"name": "verificationIndex", "type": "uint256"},
            {"name": "reason", "type": "string"},
            {"name": "expectedFee", "type": "uint256"},
        ],
        "name": "reportInconclusive",
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function",
    },
    {
        "inputs": [
            {"name": "dealContract", "type": "address"},
            {"name": "dealIndex", "type": "uint256"},
            {"name": "verificationIndex", "type": "uint256"},
            {"name": "reason", "type": "string"},
            {"name": "expectedFee", "type": "uint256"},
        ],
        "name": "reportFailure",
        "outputs": [],
        "stateMutability": "nonpayable",
        "type": "function",
    },
]

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
]

CHAINLINK_FEED_ABI = [
    {
        "inputs": [],
        "name": "latestRoundData",
        "outputs": [
            {"name": "roundId", "type": "uint80"},
            {"name": "answer", "type": "int256"},
            {"name": "startedAt", "type": "uint256"},
            {"name": "updatedAt", "type": "uint256"},
            {"name": "answeredInRound", "type": "uint80"},
        ],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "inputs": [{"name": "_roundId", "type": "uint80"}],
        "name": "getRoundData",
        "outputs": [
            {"name": "roundId", "type": "uint80"},
            {"name": "answer", "type": "int256"},
            {"name": "startedAt", "type": "uint256"},
            {"name": "updatedAt", "type": "uint256"},
            {"name": "answeredInRound", "type": "uint80"},
        ],
        "stateMutability": "view",
        "type": "function",
    },
    {
        "inputs": [],
        "name": "decimals",
        "outputs": [{"name": "", "type": "uint8"}],
        "stateMutability": "view",
        "type": "function",
    },
]

ERC20_METADATA_ABI = [
    {
        "inputs": [],
        "name": "decimals",
        "outputs": [{"name": "", "type": "uint8"}],
        "stateMutability": "view",
        "type": "function",
    },
]

_w3 = None
_account = None
_verifier_contract = None


def _init():
    global _w3, _account, _verifier_contract
    if _w3 is None:
        _w3 = Web3(Web3.HTTPProvider(settings.rpc_url, request_kwargs={"timeout": settings.request_timeout}))
        _account = _w3.eth.account.from_key(settings.private_key)
        _verifier_contract = _w3.eth.contract(
            address=Web3.to_checksum_address(settings.contract_address),
            abi=VERIFIER_ABI,
        )
    return _w3, _account, _verifier_contract


def get_web3() -> Web3:
    w3, _, _ = _init()
    return w3


def build_feed_contract(feed_address: str):
    w3 = get_web3()
    return w3.eth.contract(address=Web3.to_checksum_address(feed_address), abi=CHAINLINK_FEED_ABI)


def read_token_decimals(token_address: str) -> int:
    w3 = get_web3()
    token = w3.eth.contract(address=Web3.to_checksum_address(token_address), abi=ERC20_METADATA_ABI)
    return int(token.functions.decimals().call())


def read_verification_params(deal_contract_addr: str, deal_index: int, verification_index: int) -> dict:
    w3 = get_web3()
    deal_obj = w3.eth.contract(address=Web3.to_checksum_address(deal_contract_addr), abi=DEAL_CONTRACT_ABI)
    verifier, fee, deadline, sig, spec_params = deal_obj.functions.verificationParams(
        deal_index, verification_index
    ).call()
    return {
        "verifier": verifier,
        "fee": int(fee),
        "deadline": int(deadline),
        "sig": sig,
        "spec_params": spec_params,
    }


def _send_verifier_tx(fn_name: str, args: tuple) -> str:
    w3, account, contract = _init()
    fn = getattr(contract.functions, fn_name)(*args)

    call_params = {"from": account.address, "nonce": w3.eth.get_transaction_count(account.address)}
    estimated_gas = fn.estimate_gas(call_params)
    latest = w3.eth.get_block("latest")
    base_fee = latest.get("baseFeePerGas", w3.eth.gas_price)
    priority_fee = w3.to_wei(0.5, "gwei")

    tx = fn.build_transaction({
        **call_params,
        "gas": int(estimated_gas * 1.2),
        "maxFeePerGas": base_fee * 2 + priority_fee,
        "maxPriorityFeePerGas": priority_fee,
    })

    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
    if receipt["status"] != 1:
        raise RuntimeError(f"{fn_name} tx failed: {tx_hash.hex()}")

    logger.info("%s confirmed: %s (gas=%d)", fn_name, tx_hash.hex(), receipt["gasUsed"])
    return tx_hash.hex()


def report_settlement_price(
    deal_contract: str,
    deal_index: int,
    verification_index: int,
    settlement_price: int,
    reason: str,
    expected_fee: int,
) -> str:
    return _send_verifier_tx(
        "reportSettlementPrice",
        (Web3.to_checksum_address(deal_contract), deal_index, verification_index, settlement_price, reason, expected_fee),
    )


def report_inconclusive(
    deal_contract: str,
    deal_index: int,
    verification_index: int,
    reason: str,
    expected_fee: int,
) -> str:
    return _send_verifier_tx(
        "reportInconclusive",
        (Web3.to_checksum_address(deal_contract), deal_index, verification_index, reason, expected_fee),
    )


def report_failure(
    deal_contract: str,
    deal_index: int,
    verification_index: int,
    reason: str,
    expected_fee: int,
) -> str:
    return _send_verifier_tx(
        "reportFailure",
        (Web3.to_checksum_address(deal_contract), deal_index, verification_index, reason, expected_fee),
    )
