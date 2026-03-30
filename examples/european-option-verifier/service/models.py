"""Data models for the European option verifier service."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional


@dataclass
class OptionVerificationSpec:
    underlying: str
    quote_token: str
    expiry: int
    settlement_window: int


@dataclass
class SettlementResult:
    result_code: int
    reason: str
    settlement_price: Optional[int] = None
    source_label: Optional[str] = None

    @staticmethod
    def success(settlement_price: int, source_label: str) -> "SettlementResult":
        return SettlementResult(
            result_code=1,
            reason=f"settlement price available from {source_label}",
            settlement_price=settlement_price,
            source_label=source_label,
        )

    @staticmethod
    def inconclusive(reason: str) -> "SettlementResult":
        return SettlementResult(result_code=0, reason=reason)

    @staticmethod
    def failure(reason: str) -> "SettlementResult":
        return SettlementResult(result_code=-1, reason=reason)
