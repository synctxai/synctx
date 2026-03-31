"""Message handling logic — X-Follow Verifier (Campaign Model).

Per-campaign signing: target_username only (no follower_username).
Per-claim verification: reads follower_username from specParams.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from typing import Any

from config import SIGN_DEADLINE_SECONDS, settings
from signer import sign_verify_request
from chain import report_result, read_verification_params, read_deal_status
from mcp_client import PlatformClient
from x_follow_spec import decode_spec_params
from verification import is_following
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
    tag = content.get("tag")

    if action == "request_sign":
        await handle_request_sign(client, sender, content, tag)
    elif action == "notify_verify":
        await handle_notify_verify(client, sender, content, tag)
    else:
        logger.info("Unknown action '%s', ignoring", action)


# ---------------------------------------------------------------------------
# request_sign: per-campaign signature (target_username only)
# ---------------------------------------------------------------------------

async def handle_request_sign(client: PlatformClient, sender: str, content: dict, tag: str | None = None) -> None:
    """Handle a signature request for a campaign.

    Received: {"action": "request_sign", "params": {"target_username": "target"}, "deadline": 1700000000, "tag": "..."}
    Response: {"accepted": true, "fee": 10000, "sig": "0x...", "tag": "..."} or {"accepted": false, "reason": "...", "tag": "..."}
    """
    raw_params = content.get("params", {})
    params = json.loads(raw_params) if isinstance(raw_params, str) else raw_params
    deadline = content.get("deadline")

    target_username = normalise_username(params.get("target_username", ""))

    async def _reply(resp: dict) -> None:
        if tag is not None:
            resp["tag"] = tag
        await client.send_message(sender, resp)

    if not target_username:
        logger.warning("request_sign params incomplete: %s", content)
        await _reply({"accepted": False, "reason": "Incomplete params, requires target_username"})
        return

    if not deadline:
        logger.warning("request_sign missing deadline: %s", content)
        await _reply({"accepted": False, "reason": "Missing deadline"})
        return

    deadline = int(deadline)

    now = int(time.time())
    max_deadline = now + SIGN_DEADLINE_SECONDS
    if deadline > max_deadline:
        await _reply({
            "accepted": False,
            "reason": f"Deadline exceeds acceptable range, maximum accepted is within {SIGN_DEADLINE_SECONDS} seconds",
        })
        return

    if deadline <= now:
        await _reply({"accepted": False, "reason": "Deadline has expired"})
        return

    fee = settings.verify_fee
    if fee <= 0:
        logger.error("verify_fee is configured as %d, refusing to sign", fee)
        await _reply({"accepted": False, "reason": "Verifier fee must be > 0"})
        return

    try:
        result = sign_verify_request(
            target_username=target_username,
            fee=fee,
            deadline=deadline,
        )

        sig = result.signature if result.signature.startswith("0x") else f"0x{result.signature}"

        response: dict[str, Any] = {
            "accepted": True,
            "fee": fee,
            "sig": sig,
        }
        logger.info("Signature successful: target=%s, fee=%d, deadline=%d", target_username, fee, deadline)
        await _reply(response)

    except Exception as e:
        logger.error("Signature failed: %s", e, exc_info=True)
        await _reply({"accepted": False, "reason": f"Internal signing error: {e}"})


# ---------------------------------------------------------------------------
# notify_verify: per-claim verification (reads follower from specParams)
# ---------------------------------------------------------------------------

async def handle_notify_verify(client: PlatformClient, sender: str, content: dict, tag: str | None = None) -> None:
    """Handle a verification notification for a claim.

    Received: {"action": "notify_verify", "dealContract": "0x...", "dealIndex": 5, "verificationIndex": 0, "tag": "..."}
    """
    VERIFYING_STATUS = 0

    deal_contract = content.get("dealContract")
    deal_index = content.get("dealIndex")
    verification_index = content.get("verificationIndex")

    if deal_contract is None or deal_index is None or verification_index is None:
        logger.warning("notify_verify missing dealContract / dealIndex / verificationIndex: %s", content)
        return

    async def _reply(resp: dict) -> None:
        if tag is not None:
            resp["tag"] = tag
        await client.send_message(sender, resp)

    async def _reply_not_verifying(status: int) -> None:
        logger.warning("Deal %s is not in VERIFYING state (status=%d), ignoring notification", deal_index, status)
        await _reply({
            "action": "result",
            "dealIndex": deal_index,
            "verificationIndex": verification_index,
            "error": f"Deal is not in VERIFYING state (current status={status})",
        })

    try:
        # 0. Check on-chain dealStatus — only proceed if VERIFYING
        status = read_deal_status(deal_contract, int(deal_index))
        if status != VERIFYING_STATUS:
            await _reply_not_verifying(status)
            return

        # 1. Read authoritative verification params from on-chain
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
        follower = spec.follower_username
        target = spec.target_username
        logger.info("On-chain params: follower=%s, target=%s", follower, target)

        # 2. Off-chain verification — dual-provider follow check
        result_code, reason = await _check_follow_with_result(follower, target)
        logger.info("Follow verification result: dealIndex=%s, result=%d, reason=%s", deal_index, result_code, reason)

        # Re-check status before reportResult so near-timeout claims do not waste a tx.
        status = read_deal_status(deal_contract, int(deal_index))
        if status != VERIFYING_STATUS:
            await _reply_not_verifying(status)
            return

        # 3. On-chain reportResult
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

        # 5. Notify the caller
        response: dict[str, Any] = {
            "action": "result",
            "dealIndex": deal_index,
            "verificationIndex": verification_index,
            "result": result_code,
            "txHash": tx_hash,
        }
        await _reply(response)
        logger.info("Verification complete: dealIndex=%s, result=%d, tx=%s", deal_index, result_code, tx_hash)

    except Exception as e:
        logger.error("Verification failed: dealIndex=%s, error=%s", deal_index, e, exc_info=True)
        await _reply({
            "action": "result",
            "dealIndex": deal_index,
            "verificationIndex": verification_index,
            "error": str(e),
        })


async def _check_follow_with_result(follower: str, target: str) -> tuple[int, str]:
    """Off-chain follow verification, returns (result_code, reason).

    result_code: 1=following, -1=not following, 0=inconclusive
    """
    try:
        result = await is_following(follower, target)
    except Exception as e:
        logger.warning("Follow verification API exception, returning inconclusive: %s", e)
        return 0, f"verification inconclusive: {e}"

    if result.error is not None:
        logger.warning("Follow verification returned error, inconclusive: %s", result.error)
        return 0, f"verification inconclusive: {result.error}"

    if result.following:
        return 1, "follow verified"

    # Follow status may not be immediately reflected; retry once after 5s
    logger.info("Follow not detected, retrying once after 5s...")
    await asyncio.sleep(5)
    try:
        result = await is_following(follower, target)
    except Exception as e:
        logger.warning("Retry API exception, returning inconclusive: %s", e)
        return 0, f"verification inconclusive on retry: {e}"

    if result.error is not None:
        return 0, f"verification inconclusive on retry: {result.error}"
    if result.following:
        return 1, "follow verified (retry)"
    return -1, "follow not detected"
