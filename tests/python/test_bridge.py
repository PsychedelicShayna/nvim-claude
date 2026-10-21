from __future__ import annotations

import asyncio
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("nvim_claude_bridge", ROOT / "python" / "nvim_claude_bridge.py")
bridge_module = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(bridge_module)


class FakeRpc:
    def __init__(self) -> None:
        self.notifications = []

    async def notify(self, method, params):
        self.notifications.append((method, params))


class StoreTests(unittest.TestCase):
    def test_abandoned_instance_removes_only_its_unsaved_transcript(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary) / "home"
            state = Path(temporary) / "state"
            projects = home / ".claude" / "projects" / "project"
            instances = state / "instances"
            projects.mkdir(parents=True)
            instances.mkdir(parents=True)
            abandoned = "11111111-1111-1111-1111-111111111111"
            unrelated = "22222222-2222-2222-2222-222222222222"
            (projects / f"{abandoned}.jsonl").write_text("owned")
            (projects / f"{unrelated}.jsonl").write_text("unrelated")
            (instances / "old.json").write_text(json.dumps({"pid": 99999999, "unsaved_sessions": [abandoned]}))
            with mock.patch.dict(os.environ, {"HOME": str(home)}), mock.patch.object(Path, "home", return_value=home):
                store = bridge_module.Store(state, "current")
                self.assertFalse((projects / f"{abandoned}.jsonl").exists())
                self.assertTrue((projects / f"{unrelated}.jsonl").exists())
                store.close()


class BridgePolicyTests(unittest.IsolatedAsyncioTestCase):
    async def test_budget_refuses_mandatory_input_above_limit(self):
        instance = object.__new__(bridge_module.Bridge)
        instance.default_prompt = "system"
        params = {
            "request_id": "r1",
            "config": {
                "context_limit_tokens": 100,
                "runtime_overhead_tokens": 50,
                "output_reserve_tokens": 25,
            },
        }
        with self.assertRaisesRegex(bridge_module.RpcFailure, "Mandatory input"):
            await instance._budget(object(), params, "x" * 30)

    async def test_budget_compacts_before_dispatch(self):
        instance = object.__new__(bridge_module.Bridge)
        instance.default_prompt = "s"
        usages = iter(({"totalTokens": 70}, {"totalTokens": 10}))
        compacted = []

        async def context_usage(_client):
            return next(usages)

        async def compact(_client, request_id, automatic):
            compacted.append((request_id, automatic))
            return {}

        instance._context_usage = context_usage
        instance._compact = compact
        params = {
            "request_id": "r2",
            "config": {
                "context_limit_tokens": 100,
                "runtime_overhead_tokens": 10,
                "output_reserve_tokens": 5,
            },
        }
        usage = await instance._budget(object(), params, "x" * 20)
        self.assertEqual(compacted, [("r2", True)])
        self.assertEqual(usage["totalTokens"], 10)

    def test_options_disable_runtime_tools_and_settings(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            resource = root / "prompt.txt"
            resource.write_text("prompt")
            instance = bridge_module.Bridge(FakeRpc(), root / "state", resource, "test")
            options = instance._options({
                "config": {"model": "claude-haiku-5-5", "effort": "low", "context_limit_tokens": 100000},
                "system_prompt": "prompt",
            })
            self.assertEqual(options.tools, [])
            self.assertEqual(options.allowed_tools, [])
            self.assertEqual(options.mcp_servers, {})
            self.assertTrue(options.strict_mcp_config)
            self.assertEqual(options.setting_sources, [])
            self.assertEqual(options.skills, [])
            self.assertEqual(options.plugins, [])
            self.assertEqual(options.system_prompt, { "type": "custom", "prompt": "prompt", "snapshot": False })
            instance.store.close()

    def test_model_discovery_uses_runtime_metadata(self):
        found = {}
        bridge_module.Bridge._walk_models({
            "availableModels": [
                {"id": "claude-haiku-5-5", "displayName": "Haiku 5.5", "supportedEfforts": ["low", "high"]}
            ]
        }, found)
        self.assertEqual(found["claude-haiku-5-5"]["efforts"], ["low", "high"])
        self.assertNotIn("claude-opus-4-6", found)


if __name__ == "__main__":
    unittest.main()
