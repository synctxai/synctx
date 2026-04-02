"""Message handling logic — X-Quote Verifier."""

from __future__ import annotations

import asyncio
import json
import logging
import time
from typing import Any

from config import SIGN_DEADLINE_SECONDS, settings
from signer import sign_verify_request
from chain import report_result, read_verification_params
from mcp_client import PlatformClient
from x_quote_spec import decode_spec_params
from verification import has_quote
from providers.base import normalise_user_id

logger = logging.getLogger(__name__)


async def handle_message(client: PlatformClient, msg: dict) -> None:
    """Process a single message, dispatching based on the action in content."""
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


# ---------------------------------------------------------------------------
# request_sign: Trader requests an EIP-712 signature (quote)
# ---------------------------------------------------------------------------

async def handle_request_sign(client: PlatformClient, sender: str, content: dict) -> None:
    """Handle a signature request.

    Received: {"action": "request_sign", "params": {"tweet_id": "123", "quoter_user_id": "111"}, "deadline": 1700000000}
    Response: {"accepted": true, "fee": 10000, "sig": "0x..."} or {"accepted": false, "reason": "..."}
    """
    raw_params = content.get("params", {})
    params = json.loads(raw_params) if isinstance(raw_params, str) else raw_params
    deadline = content.get("deadline")

    tweet_id = params.get("tweet_id")
    quoter_user_id = normalise_user_id(params.get("quoter_user_id", ""))

    if not tweet_id or not quoter_user_id:
        logger.warning("request_sign params incomplete: %s", content)
        await client.send_message(sender, {"accepted": False, "reason": "Incomplete params, requires tweet_id and quoter_user_id"})
        return

    if not deadline:
        logger.warning("request_sign missing deadline: %s", content)
        await client.send_message(sender, {"accepted": False, "reason": "Missing deadline"})
        return

    deadline = int(deadline)

    # Check if deadline is within acceptable range
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
        result = sign_verify_request(
            tweet_id=str(tweet_id),
            quoter_user_id=int(quoter_user_id),
            fee=fee,
            deadline=deadline,
        )

        sig = result.signature if result.signature.startswith("0x") else f"0x{result.signature}"

        response = {
            "accepted": True,
            "fee": fee,
            "sig": sig,
        }
        logger.info("Signature successful: tweet_id=%s, fee=%d, deadline=%d", tweet_id, fee, deadline)
        await client.send_message(sender, response)

    except Exception as e:
        logger.error("Signature failed: %s", e, exc_info=True)
        await client.send_message(sender, {"accepted": False, "reason": f"Internal signing error: {e}"})


# ---------------------------------------------------------------------------
# notify_verify: Platform forwards verification notification; read authoritative params from chain then verify
# ---------------------------------------------------------------------------

async def handle_notify_verify(client: PlatformClient, sender: str, content: dict) -> None:
    """Handle a verification notification.

    Received: {"action": "notify_verify", "dealContract": "0x...", "dealIndex": 5, "verificationIndex": 0}
    Flow: Read authoritative params from on-chain verificationParams -> off-chain verification -> on-chain reportResult
    Response: {"action": "result", "dealIndex": 5, "verificationIndex": 0, "result": 1/-1, "txHash": "0x..."}
    """
    deal_contract = content.get("dealContract")
    deal_index = content.get("dealIndex")
    verification_index = content.get("verificationIndex")

    if deal_contract is None or deal_index is None or verification_index is None:
        logger.warning("notify_verify missing dealContract / dealIndex / verificationIndex: %s", content)
        return

    try:
        # 1. Read authoritative verification params from on-chain verificationParams
        on_chain = read_verification_params(deal_contract, int(deal_index), int(verification_index))
        on_chain_verifier = on_chain["verifier"].lower()
        if on_chain_verifier != settings.contract_address.lower():
            logger.warning("Notification not for this verifier, ignoring: on_chain=%s, self=%s", on_chain_verifier, settings.contract_address)
            return

        on_chain_fee = on_chain["fee"]
        if on_chain_fee <= 0:
            logger.warning("On-chain verification fee is 0, refusing to execute: dealIndex=%s", deal_index)
            return

        spec = decode_spec_params(on_chain["spec_params"])
        tweet_id = spec.tweet_id
        quoter_user_id = str(spec.quoter_user_id)
        quote_tweet_id = spec.quote_tweet_id
        logger.info("On-chain params: tweet_id=%s, quoter_user_id=%s, quote_tweet_id=%s", tweet_id, quoter_user_id, quote_tweet_id)

        # 2. Off-chain verification
        result_code, reason = await _check_tweet_with_result(quoter_user_id, tweet_id, quote_tweet_id)
        logger.info("Tweet verification result: dealIndex=%s, result=%d, reason=%s", deal_index, result_code, reason)

        # 3. On-chain reportResult (pass expectedFee; the contract verifies that DealContract paid the agreed amount)
        tx_hash = report_result(
            deal_contract=deal_contract,
            deal_index=int(deal_index),
            verification_index=int(verification_index),
            result=result_code,
            reason=reason,
            expected_fee=on_chain_fee,
        )

        # 4. Report transaction record to the platform
        await client.report_transaction(tx_hash, settings.chain_id)

        # 5. Notify the Trader
        response: dict[str, Any] = {
            "action": "result",
            "dealIndex": deal_index,
            "verificationIndex": verification_index,
            "result": result_code,
            "txHash": tx_hash,
        }
        await client.send_message(sender, response)
        logger.info("Verification complete: dealIndex=%s, result=%d, tx=%s", deal_index, result_code, tx_hash)

    except Exception as e:
        logger.error("Verification failed: dealIndex=%s, error=%s", deal_index, e, exc_info=True)
        await client.send_message(sender, {
            "action": "result",
            "dealIndex": deal_index,
            "verificationIndex": verification_index,
            "error": str(e),
        })


async def _check_tweet_with_result(quoter_user_id: str, target_tweet_id: str, new_tweet_id: str) -> tuple[int, str]:
    """Off-chain tweet quote verification, returns (result_code, reason).

    result_code: 1=pass, -1=fail, 0=inconclusive
    """
    quote_tweet_id = new_tweet_id.strip()
    if not quote_tweet_id:
        return -1, "quote tweet id missing"

    try:
        result = await has_quote(quoter_user_id, target_tweet_id, quote_tweet_id)
    except Exception as e:
        logger.warning("Tweet verification API exception, returning inconclusive: %s", e)
        return 0, f"verification inconclusive: {e}"

    if result.error is not None:
        logger.warning("Tweet verification returned error, inconclusive: %s", result.error)
        return 0, f"verification inconclusive: {result.error}"

    if result.verified:
        return 1, "quote tweet verified"

    first_reason = result.reason or "quote tweet not found"

    # Deterministic failures: the tweet was found but doesn't meet the criteria.
    # These won't change on retry, so return -1 immediately.
    _deterministic_reasons = {"wrong author", "not a quote tweet", "quoted wrong tweet"}
    if first_reason in _deterministic_reasons:
        return -1, first_reason

    # Third-party API may not have synced the tweet yet; retry once after 5s
    logger.info("Quote tweet verification failed (%s), retrying once after 5s...", first_reason)
    await asyncio.sleep(5)
    try:
        result = await has_quote(quoter_user_id, target_tweet_id, quote_tweet_id)
    except Exception as e:
        logger.warning("Retry API exception, returning inconclusive: %s", e)
        return 0, f"verification inconclusive on retry: {e}"

    if result.error is not None:
        return 0, f"verification inconclusive on retry: {result.error}"
    if result.verified:
        return 1, "quote tweet verified (retry)"
    return -1, result.reason or first_reason
