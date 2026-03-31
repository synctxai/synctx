import asyncio
import importlib
import sys
import types
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch


SERVICE_DIR = Path(__file__).resolve().parents[1] / "service"
if str(SERVICE_DIR) not in sys.path:
    sys.path.insert(0, str(SERVICE_DIR))


def load_handlers_module():
    for name in [
        "handlers",
        "config",
        "signer",
        "chain",
        "mcp_client",
        "x_follow_spec",
        "verification",
        "providers",
        "providers.base",
    ]:
        sys.modules.pop(name, None)

    config_mod = types.ModuleType("config")
    config_mod.SIGN_DEADLINE_SECONDS = 3600
    config_mod.settings = SimpleNamespace(
        chain_id=10,
        contract_address="0xverifier",
        verify_fee=10_000,
    )

    signer_mod = types.ModuleType("signer")
    signer_mod.sign_verify_request = lambda **kwargs: SimpleNamespace(
        signature="0xsig",
        deadline=kwargs["deadline"],
    )

    chain_mod = types.ModuleType("chain")
    chain_mod.report_result = lambda **kwargs: "0xtx"
    chain_mod.read_verification_params = lambda *args, **kwargs: {}
    chain_mod.read_deal_status = lambda *args, **kwargs: 0

    mcp_client_mod = types.ModuleType("mcp_client")

    class PlatformClient:
        pass

    mcp_client_mod.PlatformClient = PlatformClient

    x_follow_spec_mod = types.ModuleType("x_follow_spec")
    x_follow_spec_mod.decode_spec_params = lambda data: SimpleNamespace(
        follower_user_id=111,
        target_user_id=222,
    )

    verification_mod = types.ModuleType("verification")

    async def is_following_by_user_ids(*args, **kwargs):
        return None

    verification_mod.is_following_by_user_ids = is_following_by_user_ids

    providers_mod = types.ModuleType("providers")
    providers_mod.__path__ = []
    providers_base_mod = types.ModuleType("providers.base")
    providers_base_mod.normalise_user_id = (
        lambda value: str(value) if str(value).isdigit() and str(value) != "0" else ""
    )

    sys.modules["config"] = config_mod
    sys.modules["signer"] = signer_mod
    sys.modules["chain"] = chain_mod
    sys.modules["mcp_client"] = mcp_client_mod
    sys.modules["x_follow_spec"] = x_follow_spec_mod
    sys.modules["verification"] = verification_mod
    sys.modules["providers"] = providers_mod
    sys.modules["providers.base"] = providers_base_mod

    return importlib.import_module("handlers")


class FakeClient:
    def __init__(self):
        self.sent_messages = []
        self.reported_transactions = []

    async def send_message(self, sender, payload):
        self.sent_messages.append((sender, payload))

    async def report_transaction(self, tx_hash, chain_id):
        self.reported_transactions.append((tx_hash, chain_id))


class HandleNotifyVerifyTests(unittest.TestCase):
    def setUp(self):
        self.handlers = load_handlers_module()
        self.client = FakeClient()
        self.content = {
            "dealContract": "0xdeal",
            "dealIndex": 7,
            "verificationIndex": 0,
        }
        self.on_chain_params = {
            "verifier": "0xverifier",
            "fee": 10_000,
            "deadline": 1_700_000_000,
            "sig": b"\x12\x34",
            "spec_params": b"dummy",
        }
        self.spec = SimpleNamespace(follower_user_id=111, target_user_id=222)

    def test_notify_verify_rechecks_status_before_report_result(self):
        with patch.object(
            self.handlers,
            "read_deal_status",
            side_effect=[0, 1],
        ), patch.object(
            self.handlers,
            "read_verification_params",
            return_value=self.on_chain_params,
        ), patch.object(
            self.handlers,
            "decode_spec_params",
            return_value=self.spec,
        ), patch.object(
            self.handlers,
            "_check_follow_with_result",
            new=AsyncMock(return_value=(1, "follow verified")),
        ), patch.object(
            self.handlers,
            "report_result",
        ) as report_result:
            asyncio.run(
                self.handlers.handle_notify_verify(
                    self.client,
                    "0xsender",
                    self.content,
                    "tag-1",
                )
            )

        report_result.assert_not_called()
        self.assertEqual(self.client.reported_transactions, [])
        self.assertEqual(len(self.client.sent_messages), 1)
        sender, payload = self.client.sent_messages[0]
        self.assertEqual(sender, "0xsender")
        self.assertEqual(payload["tag"], "tag-1")
        self.assertIn("current status=1", payload["error"])

    def test_notify_verify_reports_when_status_stays_verifying(self):
        with patch.object(
            self.handlers,
            "read_deal_status",
            side_effect=[0, 0],
        ), patch.object(
            self.handlers,
            "read_verification_params",
            return_value=self.on_chain_params,
        ), patch.object(
            self.handlers,
            "decode_spec_params",
            return_value=self.spec,
        ), patch.object(
            self.handlers,
            "_check_follow_with_result",
            new=AsyncMock(return_value=(1, "follow verified")),
        ), patch.object(
            self.handlers,
            "report_result",
            return_value="0xtx",
        ) as report_result:
            asyncio.run(
                self.handlers.handle_notify_verify(
                    self.client,
                    "0xsender",
                    self.content,
                )
            )

        report_result.assert_called_once()
        self.assertEqual(self.client.reported_transactions, [("0xtx", 10)])
        self.assertEqual(len(self.client.sent_messages), 1)
        _, payload = self.client.sent_messages[0]
        self.assertEqual(payload["result"], 1)
        self.assertEqual(payload["txHash"], "0xtx")


if __name__ == "__main__":
    unittest.main()
