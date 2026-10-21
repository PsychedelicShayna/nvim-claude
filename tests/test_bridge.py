import asyncio
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("nvim_claude_bridge", ROOT / "python" / "nvim_claude_bridge.py")
bridge_module = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(bridge_module)


class SilentProtocol:
    def __init__(self):
        self.notifications = []

    async def notify(self, method, params):
        self.notifications.append((method, params))


class BridgeTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        cache = Path(os.environ.get("NVIM_CLAUDE_TEST_TMP", Path.home() / ".cache" / "nvim-claude-tests"))
        cache.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=cache)
        self.bridge = bridge_module.Bridge(SilentProtocol())
        self.bridge.state_dir = Path(self.temporary.name)
        self.bridge.manifest_path = self.bridge.state_dir / "conversations.json"

    def tearDown(self):
        self.temporary.cleanup()

    def test_no_tool_options_are_explicit(self):
        options = self.bridge._options()
        self.assertEqual(options.tools, [])
        self.assertEqual(options.allowed_tools, [])
        self.assertEqual(options.mcp_servers, {})
        self.assertTrue(options.strict_mcp_config)
        self.assertEqual(options.setting_sources, [])
        self.assertIsNone(options.fallback_model)

    async def test_budget_refuses_mandatory_input_over_limit(self):
        self.bridge.limit = 25_000
        allowed, reason, compacted = await self.bridge._budget("x" * 6_000)
        self.assertFalse(allowed)
        self.assertFalse(compacted)
        self.assertIn("25,000-token", reason)

    def test_runtime_context_total_is_counted(self):
        self.assertEqual(self.bridge._occupancy({"totalTokens": 1391}), 1391)

    def test_model_metadata_is_not_invented(self):
        self.bridge.server_info = {}
        self.assertEqual(self.bridge.models(), {"models": [], "source": "unavailable"})
        self.bridge.server_info = {"capabilities": {"models": [{"id": "runtime-model"}]}}
        self.assertEqual(self.bridge.models()["models"], [{"id": "runtime-model"}])

    def test_saved_list_is_newest_first(self):
        self.bridge.saved = {
            "old": {"id": "old", "created": 1, "first_prompt": "first"},
            "new": {"id": "new", "created": 2, "first_prompt": "second"},
        }
        self.assertEqual([item["id"] for item in self.bridge.list_saved()], ["new", "old"])


if __name__ == "__main__":
    unittest.main()
