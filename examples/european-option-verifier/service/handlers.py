"""Message handling logic — European option settlement price verifier."""

from __future__ import annotations

import json
import logging
import time
from typing import Any

from web3 import Web3

from chain import (
    read_verification_params,
    report_failure,
    report_inconclusive,
    report_settlement_price,
)
from config import SIGN_DEADLINE_SECONDS, settings
from mcp_client import PlatformClient
from option_spec import decode_spec_params
from settlement_price import resolve_settlement_price
from signer import sign_verify_request

logger = logging.getLogger(__name__)


async def handle_message(client: PlatformClient, msg: dict) -> None:
    sender = msg.get("from_address", "")
    raw_content = msg.get("content", "")

    try:
        content = json.loads(raw_content)
    except (json.JSONDecodeError, TypeError):
        logger.warning("Received non-JSON message, ignoring: %s", raw_content[:100])
        return

    if not isinstance(content, dict):
        logger.warning("Message content is not an object, ignoring: %s", raw_content[:100])
        return

    action = content.get("action")
    if action == "request_sign":
        await handle_request_sign(client, sender, content)
    elif action == "notify_verify":
        await handle_notify_verify(client, sender, content)
    else:
        logger.info("Unknown action '%s', ignoring", action)


async def handle_request_sign(client: PlatformClient, sender: str, content: dict) -> None:
    raw_params = content.get("params", {})
    params = json.loads(raw_params) if isinstance(raw_params, str) else raw_params
    deadline = content.get("deadline")

    underlying = params.get("underlying")
    quote_token = params.get("quoteToken") or params.get("quote_token")
    expiry = params.get("expiry")
    settlement_window = params.get("settlementWindow") or params.get("settlement_window")

    if not all([underlying, quote_token, expiry, settlement_window]):
        await client.send_message(sender, {
            "accepted": False,
            "reason": "Incomplete params, requires underlying, quoteToken, expiry, settlementWindow",
        })
        return

    if not deadline:
        await client.send_message(sender, {"accepted": False, "reason": "Missing deadline"})
        return

    if not Web3.is_address(underlying) or not Web3.is_address(quote_token):
        await client.send_message(sender, {"accepted": False, "reason": "Invalid address params"})
        return

    deadline = int(deadline)
    expiry = int(expiry)
    settlement_window = int(settlement_window)

    now = int(time.time())
    max_deadline = now + SIGN_DEADLINE_SECONDS
    if deadline > max_deadline:
        await client.send_message(sender, {
            "accepted": False,
            "reason": f"Deadline exceeds acceptable range, maximum accepted is within {SIGN_DEADLINE_SECONDS} seconds",
        })
        return
    if deadline <= now:
        await client.send_message(sender, {"accepted": False, "reason": "Deadline has expired"})
        return

    fee = settings.verify_fee

    try:
        sign_result = sign_verify_request(
            underlying=Web3.to_checksum_address(underlying),
            quote_token=Web3.to_checksum_address(quote_token),
            expiry=expiry,
            settlement_window=settlement_window,
            fee=fee,
            deadline=deadline,
        )
        sig = sign_result.signature if sign_result.signature.startswith("0x") else f"0x{sign_result.signature}"
        await client.send_message(sender, {"accepted": True, "fee": fee, "sig": sig})
    except Exception as e:
        logger.error("Signature failed: %s", e, exc_info=True)
        await client.send_message(sender, {"accepted": False, "reason": f"Internal signing error: {e}"})


async def handle_notify_verify(client: PlatformClient, sender: str, content: dict) -> None:
    deal_contract = content.get("dealContract")
    deal_index = content.get("dealIndex")
    verification_index = content.get("verificationIndex")

    if deal_contract is None or deal_index is None or verification_index is None:
        logger.warning("notify_verify missing dealContract / dealIndex / verificationIndex: %s", content)
        return

    try:
        on_chain = read_verification_params(deal_contract, int(deal_index), int(verification_index))
        on_chain_verifier = on_chain["verifier"].lower()
        if on_chain_verifier != settings.contract_address.lower():
            logger.warning(
                "Notification not for this verifier, ignoring: on_chain=%s, self=%s",
                on_chain_verifier,
                settings.contract_address,
            )
            return

        spec = decode_spec_params(on_chain["spec_params"])
        settlement = resolve_settlement_price(spec)

        if settlement.result_code > 0 and settlement.settlement_price is not None:
            tx_hash = report_settlement_price(
                deal_contract=deal_contract,
                deal_index=int(deal_index),
                verification_index=int(verification_index),
                settlement_price=settlement.settlement_price,
                reason=settlement.reason,
                expected_fee=on_chain["fee"],
            )
        elif settlement.result_code == 0:
            tx_hash = report_inconclusive(
                deal_contract=deal_contract,
                deal_index=int(deal_index),
                verification_index=int(verification_index),
                reason=settlement.reason,
                expected_fee=on_chain["fee"],
            )
        else:
            tx_hash = report_failure(
                deal_contract=deal_contract,
                deal_index=int(deal_index),
                verification_index=int(verification_index),
                reason=settlement.reason,
                expected_fee=on_chain["fee"],
            )

        await client.report_transaction(tx_hash, settings.chain_id)
        response: dict[str, Any] = {
            "action": "result",
            "dealIndex": deal_index,
            "verificationIndex": verification_index,
            "result": settlement.result_code,
            "txHash": tx_hash,
            "reason": settlement.reason,
        }
        if settlement.settlement_price is not None:
            response["settlementPrice"] = settlement.settlement_price
        if settlement.source_label is not None:
            response["source"] = settlement.source_label
        await client.send_message(sender, response)
        logger.info(
            "Verification complete: dealIndex=%s, result=%d, tx=%s, settlementPrice=%s",
            deal_index,
            settlement.result_code,
            tx_hash,
            settlement.settlement_price,
        )

    except Exception as e:
        logger.error("Verification failed: dealIndex=%s, error=%s", deal_index, e, exc_info=True)
        await client.send_message(sender, {
            "action": "result",
            "dealIndex": deal_index,
            "verificationIndex": verification_index,
            "error": str(e),
        })
