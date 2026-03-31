import os
import sys
import unittest
from pathlib import Path
import types
from unittest.mock import patch


os.environ.setdefault("private_key", "0x" + "11" * 32)
os.environ.setdefault("contract_address", "0x" + "22" * 20)
os.environ.setdefault("chain_id", "11155111")
os.environ.setdefault("platform_url", "https://platform.example.com/mcp")
os.environ.setdefault("rpc_url", "https://rpc.example.com")
os.environ.setdefault("verify_fee", "10000")

SERVICE_DIR = Path(__file__).resolve().parents[1] / "service"
if str(SERVICE_DIR) not in sys.path:
    sys.path.insert(0, str(SERVICE_DIR))

if "pydantic_settings" not in sys.modules:
    fake_pydantic_settings = types.ModuleType("pydantic_settings")

    class FakeBaseSettings:
        def __init__(self, **kwargs):
            annotations = getattr(self.__class__, "__annotations__", {})
            for name, annotation in annotations.items():
                if name in kwargs:
                    value = kwargs[name]
                elif name in os.environ:
                    raw_value = os.environ[name]
                    value = int(raw_value) if annotation is int else raw_value
                elif hasattr(self.__class__, name):
                    value = getattr(self.__class__, name)
                else:
                    raise TypeError(f"missing setting: {name}")
                setattr(self, name, value)

    fake_pydantic_settings.BaseSettings = FakeBaseSettings
    sys.modules["pydantic_settings"] = fake_pydantic_settings

if "web3" not in sys.modules:
    fake_web3 = types.ModuleType("web3")

    class FakeWeb3:
        @staticmethod
        def is_address(value):
            return isinstance(value, str) and value.startswith("0x") and len(value) == 42

        @staticmethod
        def to_checksum_address(value):
            return value.lower()

    fake_web3.Web3 = FakeWeb3
    sys.modules["web3"] = fake_web3

from models import OptionVerificationSpec
from settlement_price import resolve_settlement_price


def addr(seed: int) -> str:
    return f"0x{seed:040x}"


class FakeCall:
    def __init__(self, fn):
        self._fn = fn

    def call(self):
        return self._fn()


class FakeFunctions:
    def __init__(self, contract):
        self._contract = contract

    def decimals(self):
        return FakeCall(lambda: self._contract.decimals)

    def latestRoundData(self):
        return FakeCall(self._contract.latest_round_data)

    def getRoundData(self, round_id):
        return FakeCall(lambda: self._contract.get_round_data(round_id))

    def phaseId(self):
        return FakeCall(self._contract.phase_id)

    def phaseAggregators(self, phase_id):
        return FakeCall(lambda: self._contract.phase_aggregator(phase_id))


class DirectFeed:
    def __init__(self, rounds: dict[int, tuple[int, int]], *, decimals: int = 8):
        self.rounds = rounds
        self.decimals = decimals
        self.functions = FakeFunctions(self)

    def latest_round_data(self):
        latest_round_id = max(self.rounds)
        answer, updated_at = self.rounds[latest_round_id]
        return (latest_round_id, answer, 0, updated_at, latest_round_id)

    def get_round_data(self, round_id):
        if round_id not in self.rounds:
            raise RuntimeError(f"round {round_id} not found")
        answer, updated_at = self.rounds[round_id]
        return (round_id, answer, 0, updated_at, round_id)

    def phase_id(self):
        raise RuntimeError("not a proxy")

    def phase_aggregator(self, phase_id):
        raise RuntimeError("not a proxy")


class ProxyFeed:
    PHASE_OFFSET = 64

    def __init__(self, phase_feeds: dict[int, DirectFeed], phase_addresses: dict[int, str], *, decimals: int = 8):
        self.phase_feeds = phase_feeds
        self.phase_addresses = phase_addresses
        self.decimals = decimals
        self.functions = FakeFunctions(self)

    def latest_round_data(self):
        phase_id = max(self.phase_feeds)
        local = self.phase_feeds[phase_id].latest_round_data()
        round_id = self._compose_round_id(phase_id, local[0])
        return (round_id, local[1], local[2], local[3], round_id)

    def get_round_data(self, round_id):
        phase_id = round_id >> self.PHASE_OFFSET
        local_round_id = round_id & ((1 << self.PHASE_OFFSET) - 1)
        if phase_id not in self.phase_feeds:
            raise RuntimeError(f"phase {phase_id} not found")
        local = self.phase_feeds[phase_id].get_round_data(local_round_id)
        composed_round_id = self._compose_round_id(phase_id, local[0])
        return (composed_round_id, local[1], local[2], local[3], composed_round_id)

    def phase_id(self):
        return max(self.phase_feeds)

    def phase_aggregator(self, phase_id):
        return self.phase_addresses[phase_id]

    @staticmethod
    def _compose_round_id(phase_id: int, local_round_id: int) -> int:
        return (phase_id << ProxyFeed.PHASE_OFFSET) | local_round_id


class SettlementPriceResolverTests(unittest.TestCase):
    def setUp(self):
        self.underlying = addr(0xAAA)
        self.quote = addr(0xBBB)

    def _pair_feeds(self, feed_address: str) -> dict[str, dict]:
        return {
            f"{self.underlying.lower()}:{self.quote.lower()}": {
                "feed": feed_address,
                "label": "test-feed",
            }
        }

    def test_resolves_round_outside_old_64_round_limit(self):
        feed_address = addr(0x100)
        rounds = {
            round_id: (round_id * 100_000_000, round_id * 10)
            for round_id in range(1, 201)
        }
        feed = DirectFeed(rounds)

        with patch("settlement_price.build_feed_contract", return_value=feed), \
             patch("settlement_price.read_token_decimals", return_value=6), \
             patch("settlement_price.settings.pair_feeds", return_value=self._pair_feeds(feed_address)):
            result = resolve_settlement_price(
                OptionVerificationSpec(
                    underlying=self.underlying,
                    quote_token=self.quote,
                    expiry=1000,
                    settlement_window=10,
                )
            )

        self.assertEqual(result.result_code, 1)
        self.assertEqual(result.settlement_price, 100_000_000)

    def test_resolves_across_proxy_phase_boundary(self):
        proxy_address = addr(0x200)
        phase1_address = addr(0x201)
        phase2_address = addr(0x202)

        phase1_feed = DirectFeed({
            1: (100_000_000, 100),
            2: (200_000_000, 200),
            3: (300_000_000, 300),
        })
        phase2_feed = DirectFeed({
            1: (400_000_000, 400),
            2: (500_000_000, 500),
        })
        proxy_feed = ProxyFeed(
            {1: phase1_feed, 2: phase2_feed},
            {1: phase1_address, 2: phase2_address},
        )
        feeds = {
            proxy_address.lower(): proxy_feed,
            phase1_address.lower(): phase1_feed,
            phase2_address.lower(): phase2_feed,
        }

        with patch("settlement_price.build_feed_contract", side_effect=lambda address: feeds[address.lower()]), \
             patch("settlement_price.read_token_decimals", return_value=6), \
             patch("settlement_price.settings.pair_feeds", return_value=self._pair_feeds(proxy_address)):
            result = resolve_settlement_price(
                OptionVerificationSpec(
                    underlying=self.underlying,
                    quote_token=self.quote,
                    expiry=250,
                    settlement_window=200,
                )
            )

        self.assertEqual(result.result_code, 1)
        self.assertEqual(result.settlement_price, 3_000_000)


if __name__ == "__main__":
    unittest.main()
