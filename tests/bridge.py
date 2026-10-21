"""Run with the plugin venv Python and TMPDIR on a disposable disk."""

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "python" / "nvim_claude"))
from bridge import Bridge, Manifest, RPCError  # noqa: E402

bridge = Bridge()
record = {"context_limit_tokens": 100_000, "history_bytes": 0, "turn_count": 0}
assert bridge._budget(record, '{"instruction":"short"}', "system", None)[0] is False
assert bridge._budget(record, "x" * 75_000, "system", None)[0] is True
try:
    bridge._budget(record, "x" * 99_000, "system", None)
except RPCError as error:
    assert "Mandatory prompt" in str(error)
else:
    raise AssertionError("oversized mandatory input was admitted")

with tempfile.TemporaryDirectory() as location:
    bridge.manifest = Manifest(Path(location))
    record = bridge._new()
    bridge.storage.save(record)
    assert bridge.storage.list() == []
    record["saved"] = True
    bridge.storage.save(record)
    assert bridge.storage.claim(record["id"])["session_id"] == record["session_id"]
    assert bridge.storage.list()[0]["id"] == record["id"]

print("budget admission and saved manifest checks passed")
