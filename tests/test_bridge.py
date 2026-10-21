import asyncio
import os
from pathlib import Path
import tempfile
import unittest

from python.nvim_claude_bridge import Engine, OUTPUT_RESERVE_TOKENS, RUNTIME_OVERHEAD_TOKENS


class Writer:
    def __init__(self):
        self.messages = []

    async def send(self, message):
        self.messages.append(message)


class BudgetEngine(Engine):
    async def _ensure_client(self):
        return None

    async def _usage(self):
        return {"totalTokens": 1000, "maxTokens": 1_000_000}

    async def _compact(self, request_id):
        return await self._usage()


class BridgeBudgetTests(unittest.TestCase):
    def make_engine(self):
        runtime = Path(os.environ.get("XDG_RUNTIME_DIR", "/run/user/%d" % os.getuid()))
        temporary = tempfile.TemporaryDirectory(dir=runtime)
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        prompt = root / "prompt.txt"
        prompt.write_text("system", encoding="utf-8")
        engine = BudgetEngine(root / "state", prompt, Writer())
        engine.client = object()
        return engine

    def test_upper_bound_counts_utf8_bytes_and_reserves(self):
        engine = self.make_engine()
        expected = len("é".encode()) + len("system".encode()) + RUNTIME_OVERHEAD_TOKENS + OUTPUT_RESERVE_TOKENS
        self.assertEqual(engine._request_upper_bound("é"), expected)

    def test_oversized_request_is_refused_before_dispatch(self):
        engine = self.make_engine()
        engine.context_limit_tokens = 30_000
        params = {
            "envelope": {"operation": "ask", "instruction": "x" * 10_000},
            "contextLimitTokens": 30_000,
        }
        with self.assertRaisesRegex(RuntimeError, "Request refused"):
            asyncio.run(engine.request(1, params))


if __name__ == "__main__":
    unittest.main()
