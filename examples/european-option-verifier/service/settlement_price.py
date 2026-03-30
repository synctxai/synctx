"""Settlement price resolution for European options."""

from __future__ import annotations

import logging

from web3 import Web3

from chain import build_feed_contract, read_token_decimals
from config import settings
from models import OptionVerificationSpec, SettlementResult

logger = logging.getLogger(__name__)


def resolve_settlement_price(spec: OptionVerificationSpec) -> SettlementResult:
    pair_key = f"{spec.underlying.lower()}:{spec.quote_token.lower()}"
    pair_feeds = settings.pair_feeds()
    feed_cfg = pair_feeds.get(pair_key)
    if not isinstance(feed_cfg, dict):
        return SettlementResult.failure(f"unsupported pair: {pair_key}")

    feed_address = feed_cfg.get("feed")
    source_label = str(feed_cfg.get("label", feed_address))
    if not isinstance(feed_address, str) or not Web3.is_address(feed_address):
        return SettlementResult.failure(f"invalid feed config for pair: {pair_key}")

    try:
        feed = build_feed_contract(feed_address)
        quote_decimals = read_token_decimals(spec.quote_token)
        feed_decimals = int(feed.functions.decimals().call())

        latest = feed.functions.latestRoundData().call()
        latest_round_id = int(latest[0])
        if latest_round_id <= 0:
            return SettlementResult.inconclusive("feed has no rounds")

        window_start = spec.expiry
        window_end = spec.expiry + spec.settlement_window

        selected_answer = None
        selected_updated_at = None

        for offset in range(settings.max_round_scan):
            round_id = latest_round_id - offset
            if round_id <= 0:
                break

            try:
                round_data = feed.functions.getRoundData(round_id).call()
            except Exception as e:
                logger.warning("getRoundData failed: round_id=%s, error=%s", round_id, e)
                break

            answer = int(round_data[1])
            updated_at = int(round_data[3])
            answered_in_round = int(round_data[4])

            if updated_at == 0 or answer <= 0 or answered_in_round < round_id:
                continue

            if updated_at > window_end:
                continue

            if updated_at < window_start:
                break

            selected_answer = answer
            selected_updated_at = updated_at

        if selected_answer is None:
            return SettlementResult.inconclusive(
                f"no valid round found in settlement window [{window_start}, {window_end}] from {source_label}"
            )

        settlement_price = _convert_feed_answer_to_quote_raw(selected_answer, feed_decimals, quote_decimals)
        if settlement_price <= 0:
            return SettlementResult.inconclusive("converted settlement price is zero")

        logger.info(
            "Resolved settlement price: pair=%s, source=%s, updated_at=%d, answer=%d, settlement_price=%d",
            pair_key,
            source_label,
            selected_updated_at,
            selected_answer,
            settlement_price,
        )
        return SettlementResult.success(settlement_price, source_label)

    except Exception as e:
        logger.warning("Settlement price resolution inconclusive: pair=%s, error=%s", pair_key, e, exc_info=True)
        return SettlementResult.inconclusive(f"settlement price resolution failed: {e}")


def _convert_feed_answer_to_quote_raw(answer: int, feed_decimals: int, quote_decimals: int) -> int:
    if feed_decimals == quote_decimals:
        return answer
    if feed_decimals > quote_decimals:
        return answer // (10 ** (feed_decimals - quote_decimals))
    return answer * (10 ** (quote_decimals - feed_decimals))
