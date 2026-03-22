"""Wrapper for communication with the platform MCP Server.

The platform uses Streamable HTTP transport + Bearer token authentication.
On first startup, obtains a token via get_nonce -> sign -> register_verifier.
Subsequent requests include Authorization: Bearer <token> in the HTTP header.
"""

from __future__ import annotations

import json
import logging
from pathlib import Path
from typing import Any

from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client as streamable_http_client

from config import settings
from signer import get_owner_address, sign_platform_message

TOKEN_FILE = Path(__file__).parent / "auth_token.txt"

logger = logging.getLogger(__name__)


class PlatformClient:
    """MCP communication client for the SyncTx platform."""

    def __init__(self) -> None:
        self.auth_token: str | None = None
        self.contract_address: str = settings.contract_address.lower()
        self.owner_address: str = get_owner_address()
        self._load_token()

    # ------------------------------------------------------------------
    # Token persistence
    # ------------------------------------------------------------------

    def _load_token(self) -> None:
        """Load token from local file."""
        try:
            token = TOKEN_FILE.read_text().strip()
            if token:
                self.auth_token = token
                logger.info("Loaded local token from %s", TOKEN_FILE.name)
        except FileNotFoundError:
            pass

    def _save_token(self) -> None:
        """Write token to local file."""
        if self.auth_token:
            TOKEN_FILE.write_text(self.auth_token)
            logger.info("Token saved to %s", TOKEN_FILE.name)

    # ------------------------------------------------------------------
    # Internal: establish MCP session and execute a single tool call
    # ------------------------------------------------------------------

    async def _call_tool(self, tool_name: str, arguments: dict[str, Any]) -> dict:
        """Establish an MCP connection and call a tool, returning the parsed JSON result."""
        headers = {}
        if self.auth_token:
            headers["Authorization"] = f"Bearer {self.auth_token}"

        async with streamable_http_client(
            settings.platform_url,
            headers=headers,
        ) as (read_stream, write_stream, _):
                async with ClientSession(read_stream, write_stream) as session:
                    await session.initialize()
                    result = await session.call_tool(tool_name, arguments)

                    if result.isError:
                        text = result.content[0].text if result.content else "Unknown error"
                        raise RuntimeError(f"MCP tool {tool_name} error: {text}")

                    text = result.content[0].text if result.content else "{}"
                    return json.loads(text)

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    async def register(self) -> dict:
        """Register as a verifier on the platform: get_nonce(contract_address) -> sign -> register_verifier."""
        # 1. Get nonce (Verifier uses contract_address)
        nonce_result = await self._call_tool("get_nonce", {
            "address": self.contract_address,
        })
        nonce = nonce_result["nonce"]
        message_to_sign = nonce_result["message_to_sign"]
        logger.info("Got nonce successfully: %s", nonce)

        # 2. Sign
        signature = sign_platform_message(message_to_sign)

        # 3. Register (name/description are read from the on-chain contract by the platform, no need to pass them)
        reg_result = await self._call_tool("register_verifier", {
            "contract_address": self.contract_address,
            "signature": f"0x{signature}" if not signature.startswith("0x") else signature,
            "chain_id": settings.chain_id,
        })

        self.auth_token = reg_result.get("auth_token")
        self._save_token()
        logger.info("Registration successful: address=%s, token=%s", reg_result.get("address"), self.auth_token)
        return reg_result

    async def recover_token(self) -> dict:
        """Already registered; recover token using signature (Verifier passes contract_address)."""
        nonce_result = await self._call_tool("get_nonce", {
            "address": self.contract_address,
        })
        message_to_sign = nonce_result["message_to_sign"]
        signature = sign_platform_message(message_to_sign)

        result = await self._call_tool("recover_token", {
            "address": self.contract_address,
            "signature": f"0x{signature}" if not signature.startswith("0x") else signature,
        })

        self.auth_token = result.get("auth_token")
        self._save_token()
        logger.info("Token recovered successfully: %s", self.auth_token)
        return result

    async def ensure_authenticated(self) -> None:
        """Ensure authenticated: local token -> recover_token -> new registration."""
        # 1. If local token exists, try using it directly (call get_messages once to verify validity)
        if self.auth_token:
            try:
                await self._call_tool("get_messages", {
                    "auth_token": self.auth_token,
                    "address": self.contract_address,
                    "include_read": True,
                    "limit": 1,
                })
                logger.info("Local token is valid, skipping signature authentication")
                return
            except Exception:
                logger.info("Local token is invalid, attempting recovery...")
                self.auth_token = None

        # 2. Recover via signature
        try:
            recover_result = await self.recover_token()
            if recover_result.get("address", "").lower() == self.contract_address:
                logger.info("Already registered, token recovered successfully")
                return
            logger.info("Token recovery succeeded but returned address=%s, does not match current contract %s, registering new contract...",
                        recover_result.get("address"), self.contract_address)
        except Exception:
            logger.info("Token recovery failed, attempting new registration...")

        # 3. New registration
        await self.register()

    async def get_messages(self, from_addr: str | None = None) -> list[dict]:
        """Get unread messages."""
        args: dict[str, Any] = {
            "auth_token": self.auth_token,
            "address": self.contract_address,
        }
        if from_addr:
            args["from"] = from_addr

        result = await self._call_tool("get_messages", args)
        return result.get("messages", [])

    async def report_transaction(self, tx_hash: str, chain_id: int) -> dict:
        """Report a transaction record to the platform."""
        return await self._call_tool("report_transaction", {
            "auth_token": self.auth_token,
            "address": self.contract_address,
            "tx_hash": tx_hash,
            "chain_id": chain_id,
        })

    async def send_message(self, to: str, content: dict | str) -> dict:
        """Send a message. content can be a dict (auto-serialized to JSON) or str."""
        text = json.dumps(content) if isinstance(content, dict) else content
        return await self._call_tool("send_message", {
            "auth_token": self.auth_token,
            "address": self.contract_address,
            "to": to,
            "content": text,
        })
