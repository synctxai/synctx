"""Settlement price resolution for European options."""

from __future__ import annotations

from dataclasses import dataclass
import logging

from web3 import Web3

from chain import build_feed_contract, read_token_decimals
from config import settings
from models import OptionVerificationSpec, SettlementResult

logger = logging.getLogger(__name__)

PHASE_OFFSET = 64
ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"


@dataclass(frozen=True)
class FeedPhase:
    proxy_phase_id: int | None
    latest_round_id: int


@dataclass(frozen=True)
class RoundSnapshot:
    round_id: int
    answer: int
    updated_at: int
    answered_in_round: int


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

        latest = _snapshot_from_round_data(feed.functions.latestRoundData().call())
        if latest.round_id <= 0:
            return SettlementResult.inconclusive("feed has no rounds")

        window_start = spec.expiry
        window_end = spec.expiry + spec.settlement_window

        selected_round = _find_first_round_in_window(feed, window_start, window_end)
        if selected_round is None:
            return SettlementResult.inconclusive(
                f"no valid round found in settlement window [{window_start}, {window_end}] from {source_label}"
            )

        settlement_price = _convert_feed_answer_to_quote_raw(selected_round.answer, feed_decimals, quote_decimals)
        if settlement_price <= 0:
            return SettlementResult.inconclusive("converted settlement price is zero")

        logger.info(
            "Resolved settlement price: pair=%s, source=%s, round_id=%d, updated_at=%d, answer=%d, settlement_price=%d",
            pair_key,
            source_label,
            selected_round.round_id,
            selected_round.updated_at,
            selected_round.answer,
            settlement_price,
        )
        return SettlementResult.success(settlement_price, source_label)

    except Exception as e:
        logger.warning("Settlement price resolution inconclusive: pair=%s, error=%s", pair_key, e, exc_info=True)
        return SettlementResult.inconclusive(f"settlement price resolution failed: {e}")


def _find_first_round_in_window(feed, window_start: int, window_end: int) -> RoundSnapshot | None:
    for phase in _load_feed_phases(feed):
        candidate = _find_first_round_in_phase(feed, phase, window_start, window_end)
        if candidate is not None:
            return candidate
    return None


def _load_feed_phases(feed) -> list[FeedPhase]:
    current_phase_id = _read_proxy_phase_id(feed)
    if current_phase_id is None:
        latest_round = _snapshot_from_round_data(feed.functions.latestRoundData().call())
        return [FeedPhase(proxy_phase_id=None, latest_round_id=latest_round.round_id)] if latest_round.round_id > 0 else []

    phases: list[FeedPhase] = []
    for phase_id in range(1, current_phase_id + 1):
        aggregator = _read_phase_aggregator(feed, phase_id)
        if aggregator is None:
            continue
        latest_round = _snapshot_from_round_data(build_feed_contract(aggregator).functions.latestRoundData().call())
        if latest_round.round_id <= 0:
            continue
        phases.append(FeedPhase(proxy_phase_id=phase_id, latest_round_id=latest_round.round_id))
    return phases


def _read_proxy_phase_id(feed) -> int | None:
    try:
        phase_id = int(feed.functions.phaseId().call())
    except Exception:
        return None
    return phase_id if phase_id > 0 else None


def _read_phase_aggregator(feed, phase_id: int) -> str | None:
    try:
        aggregator = str(feed.functions.phaseAggregators(phase_id).call())
    except Exception:
        return None
    if not Web3.is_address(aggregator) or aggregator.lower() == ZERO_ADDRESS:
        return None
    return Web3.to_checksum_address(aggregator)


def _find_first_round_in_phase(feed, phase: FeedPhase, window_start: int, window_end: int) -> RoundSnapshot | None:
    first_round = _read_round(feed, phase, 1)
    if first_round.updated_at > window_end:
        return None

    latest_round = _read_round(feed, phase, phase.latest_round_id)
    if latest_round.updated_at < window_start:
        return None

    candidate_round_id = _binary_search_first_round_at_or_after(feed, phase, window_start)
    for local_round_id in range(candidate_round_id, phase.latest_round_id + 1):
        round_snapshot = _read_round(feed, phase, local_round_id)
        if round_snapshot.updated_at > window_end:
            return None
        if _is_valid_round(round_snapshot):
            return round_snapshot
    return None


def _binary_search_first_round_at_or_after(feed, phase: FeedPhase, target_updated_at: int) -> int:
    low = 1
    high = phase.latest_round_id
    while low < high:
        mid = (low + high) // 2
        round_snapshot = _read_round(feed, phase, mid)
        if round_snapshot.updated_at >= target_updated_at:
            high = mid
        else:
            low = mid + 1
    return low


def _read_round(feed, phase: FeedPhase, local_round_id: int) -> RoundSnapshot:
    proxy_round_id = _compose_round_id(phase.proxy_phase_id, local_round_id)
    return _snapshot_from_round_data(feed.functions.getRoundData(proxy_round_id).call())


def _compose_round_id(proxy_phase_id: int | None, local_round_id: int) -> int:
    if proxy_phase_id is None:
        return int(local_round_id)
    return (int(proxy_phase_id) << PHASE_OFFSET) | int(local_round_id)


def _snapshot_from_round_data(round_data) -> RoundSnapshot:
    return RoundSnapshot(
        round_id=int(round_data[0]),
        answer=int(round_data[1]),
        updated_at=int(round_data[3]),
        answered_in_round=int(round_data[4]),
    )


def _is_valid_round(round_snapshot: RoundSnapshot) -> bool:
    return (
        round_snapshot.updated_at != 0
        and round_snapshot.answer > 0
        and round_snapshot.answered_in_round >= round_snapshot.round_id
    )


def _convert_feed_answer_to_quote_raw(answer: int, feed_decimals: int, quote_decimals: int) -> int:
    if feed_decimals == quote_decimals:
        return answer
    if feed_decimals > quote_decimals:
        return answer // (10 ** (feed_decimals - quote_decimals))
    return answer * (10 ** (quote_decimals - feed_decimals))
