"""Verifier entry point — registration + message polling loop."""

from __future__ import annotations

import asyncio
import logging
import signal

from config import settings
from handlers import handle_message
from mcp_client import PlatformClient

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("mcp").setLevel(logging.WARNING)
logger = logging.getLogger("verifier")

running = True


def _shutdown(sig, frame):
    global running
    logger.info("Received signal %s, shutting down...", sig)
    running = False


async def main() -> None:
    signal.signal(signal.SIGINT, _shutdown)
    signal.signal(signal.SIGTERM, _shutdown)

    client = PlatformClient()

    logger.info("European option verifier starting...")
    logger.info("  owner:    %s", client.owner_address)
    logger.info("  contract: %s", client.contract_address)
    logger.info("  chain:    %d", settings.chain_id)
    logger.info("  platform: %s", settings.platform_url)

    auth_errors = 0
    while running:
        try:
            await client.ensure_authenticated()
            break
        except Exception as e:
            auth_errors += 1
            backoff = min(settings.poll_interval * (2 ** auth_errors), 60)
            if isinstance(e, ExceptionGroup):
                for i, sub in enumerate(e.exceptions):
                    logger.error(
                        "Authentication failed (attempt %d) [%d/%d]: %s",
                        auth_errors,
                        i + 1,
                        len(e.exceptions),
                        sub,
                        exc_info=sub,
                    )
            else:
                logger.error("Authentication failed (attempt %d): %s", auth_errors, e, exc_info=True)
            logger.info("Retrying authentication in %ds...", backoff)
            await asyncio.sleep(backoff)

    if not running:
        logger.info("Received shutdown signal during authentication, stopping")
        return

    logger.info("Authentication complete, starting message polling (interval %ds)...", settings.poll_interval)

    consecutive_errors = 0
    while running:
        try:
            messages = await client.get_messages()
            consecutive_errors = 0

            if messages:
                logger.info("Received %d new message(s)", len(messages))

            for msg in messages:
                try:
                    await handle_message(client, msg)
                except Exception as e:
                    logger.error("Failed to process message: %s", e, exc_info=True)

        except Exception as e:
            consecutive_errors += 1
            logger.error("Polling failed (consecutive attempt %d): %s", consecutive_errors, e, exc_info=True)
            backoff = min(settings.poll_interval * (2 ** consecutive_errors), 60)
            logger.info("Retrying in %ds...", backoff)
            await asyncio.sleep(backoff)
            continue

        await asyncio.sleep(settings.poll_interval)

    logger.info("Verifier has stopped")


if __name__ == "__main__":
    asyncio.run(main())
