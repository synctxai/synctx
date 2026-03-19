"""Message handling logic — X-Quote Verifier."""

from __future__ import annotations

import asyncio
import json
import logging
import os
import time
from typing import Any

from config import SIGN_DEADLINE_SECONDS, settings
from signer import sign_verify_request
from chain import report_result, read_verification_params
from mcp_client import PlatformClient
from x_quote_spec import decode_spec_params
from verification import has_quote
from providers.base import normalise_username

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

    Received: {"action": "request_sign", "params": {"tweet_id": "123", "quoter_username": "user"}, "deadline": 1700000000}
    Response: {"accepted": true, "fee": 10000, "sig": "0x..."} or {"accepted": false, "reason": "..."}
    """
    raw_params = content.get("params", {})
    params = json.loads(raw_params) if isinstance(raw_params, str) else raw_params
    deadline = content.get("deadline")

    tweet_id = params.get("tweet_id")
    quoter_username = normalise_username(params.get("quoter_username", ""))

    if not tweet_id or not quoter_username:
        logger.warning("request_sign params incomplete: %s", content)
        await client.send_message(sender, {"accepted": False, "reason": "Incomplete params, requires tweet_id and quoter_username"})
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
    nonce = "0x" + os.urandom(32).hex()

    try:
        result = sign_verify_request(
            tweet_id=str(tweet_id),
            quoter_username=quoter_username,
            fee=fee,
            deadline=deadline,
            nonce=nonce,
        )

        sig = result.signature if result.signature.startswith("0x") else f"0x{result.signature}"

        response = {
            "accepted": True,
            "fee": fee,
            "verifierNonce": nonce,
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
    Flow: Read authoritative params from on-chain getVerificationParams -> off-chain verification -> on-chain reportResult
    Response: {"action": "result", "dealIndex": 5, "verificationIndex": 0, "result": 1/-1, "txHash": "0x..."}
    """
    deal_contract = content.get("dealContract")
    deal_index = content.get("dealIndex")
    verification_index = content.get("verificationIndex")

    if deal_contract is None or deal_index is None or verification_index is None:
        logger.warning("notify_verify missing dealContract / dealIndex / verificationIndex: %s", content)
        return

    try:
        # 1. Read authoritative verification params from on-chain getVerificationParams
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
        username = spec.quoter_username
        quote_tweet_id = spec.quote_tweet_id
        logger.info("On-chain params: tweet_id=%s, username=%s, quote_tweet_id=%s", tweet_id, username, quote_tweet_id)

        # 2. Off-chain verification
        result_code, reason = await _check_tweet_with_result(username, tweet_id, quote_tweet_id)
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


async def _check_tweet_with_result(username: str, target_tweet_id: str, new_tweet_id: str) -> tuple[int, str]:
    """Off-chain tweet quote verification, returns (result_code, reason).

    result_code: 1=pass, -1=fail, 0=inconclusive
    """
    quote_tweet_id = new_tweet_id.strip()
    if not quote_tweet_id:
        return -1, "quote tweet id missing"

    try:
        result = await has_quote(username, target_tweet_id, quote_tweet_id)
    except Exception as e:
        logger.warning("Tweet verification API exception, returning inconclusive: %s", e)
        return 0, f"verification inconclusive: {e}"

    if result.error is not None:
        logger.warning("Tweet verification returned error, inconclusive: %s", result.error)
        return 0, f"verification inconclusive: {result.error}"

    if result.verified:
        return 1, "quote tweet verified"

    # Tweet not found — may be due to third-party API propagation delay.
    # Wait and retry once before concluding it truly doesn't exist.
    logger.info("Tweet %s not found on first attempt, retrying after 5s...", quote_tweet_id)
    await asyncio.sleep(5)

    try:
        result = await has_quote(username, target_tweet_id, quote_tweet_id)
    except Exception as e:
        logger.warning("Tweet verification retry API exception, returning inconclusive: %s", e)
        return 0, f"verification inconclusive: {e}"

    if result.error is not None:
        logger.warning("Tweet verification retry returned error, inconclusive: %s", result.error)
        return 0, f"verification inconclusive: {result.error}"

    if result.verified:
        logger.info("Tweet %s found on retry", quote_tweet_id)
        return 1, "quote tweet verified"
    return -1, "quote tweet not found"
