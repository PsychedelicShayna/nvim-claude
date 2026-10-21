"""Focused consumer-facing bridge rules; run with the plugin venv Python."""

import asyncio
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "python" / "nvim_claude_bridge.py"
spec = importlib.util.spec_from_file_location("nvim_claude_bridge", SOURCE)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)
TEST_TEMP = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "nvim-claude-tests"
TEST_TEMP.mkdir(parents=True, exist_ok=True)


class UsageClient:
    def __init__(self, count):
        self.count = count

    async def get_context_usage(self):
        return {"totalTokens": self.count, "maxTokens": 1000000}


class BridgeContract(unittest.TestCase):
    def test_native_variant_and_local_budget_are_distinct(self):
        current = {"model": "haiku", "effort": "low", "context_limit_tokens": 100000}
        self.assertEqual(
            bridge.expression("claude-opus-4-6[1m][500k]:high", current),
            {"model": "claude-opus-4-6[1m]", "effort": "high", "context_limit_tokens": 500000},
        )
        self.assertEqual(bridge.expression("claude-haiku-5-5[100k]:low", current)["model"], "claude-haiku-5-5")
        self.assertEqual(bridge.expression("provider:model", current)["model"], "provider:model")

    def test_edit_ids_and_block_rows_must_match_before_application(self):
        targets = [{"id": "a", "block": True}, {"id": "b", "block": True}]
        ok = '{"status":"ok","replacements":[{"id":"b","text":""},{"id":"a","text":"fine"}]}'
        self.assertEqual(bridge.edit_result(ok, targets)["replacements"][0]["text"], "")
        for reply in (
            '{"status":"ok","replacements":[{"id":"a","text":"one"}]}',
            '{"status":"ok","replacements":[{"id":"a","text":"one"},{"id":"a","text":"two"}]}',
            '{"status":"ok","replacements":[{"id":"a","text":"one\\ntwo"},{"id":"b","text":"x"}]}',
        ):
            with self.subTest(reply=reply), self.assertRaises(ValueError):
                bridge.edit_result(reply, targets)

    def test_budget_refuses_mandatory_input_and_stops_near_compaction_margin(self):
        with tempfile.TemporaryDirectory(dir=TEST_TEMP) as temp:
            session = bridge.Bridge(Path(temp))
            async def check():
                self.assertFalse(await session.budget(UsageClient(0), "small"))
                self.assertTrue(await session.budget(UsageClient(45000), "x" * 40000))
                with self.assertRaisesRegex(ValueError, "Too close"):
                    await session.budget(UsageClient(95000), "x" * 40000)
                with self.assertRaisesRegex(ValueError, "empty conversation"):
                    await session.budget(UsageClient(0), "x" * 85000)
            asyncio.run(check())

    def test_large_document_is_marked_incomplete_without_truncating_target(self):
        with tempfile.TemporaryDirectory(dir=TEST_TEMP) as temp:
            session = bridge.Bridge(Path(temp))
            session.new_conversation()
            source = "".join(f"{i:04d} " + "a" * 85 + "\n" for i in range(400)) + "selected café\n" + "".join(f"{i:04d} " + "b" * 85 + "\n" for i in range(400))
            request = {"operation": "replace", "instruction": "Change the selection",
                       "document": {"id": "buffer-1", "filetype": "text"}, "text": source,
                       "revision": "1", "targets": [{"id": "a", "start": [400, 0], "end": [400, 14], "text": "selected café"}]}
            context = session.context(request)["context"]
            self.assertEqual(context["kind"], "excerpt")
            self.assertIn("selected café", context["text"])
            self.assertTrue(context["omitted_before"] or context["omitted_after"])
            session.active["baselines"]["buffer-1"] = {"revision": "1", "text": source}
            request["revision"] = "2"
            request["text"] = source.replace("selected café", "selected text")
            diff = session.context(request)["context"]
            self.assertEqual(diff["kind"], "diff")
            self.assertEqual(diff["base_revision"], "1")


if __name__ == "__main__":
    unittest.main()
