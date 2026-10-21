#!/usr/bin/env python3
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
STATE = ROOT / f".test-state-{uuid.uuid4().hex}"


def frame(value: dict) -> bytes:
    body = json.dumps(value, separators=(",", ":")).encode()
    return f"Content-Length: {len(body)}\r\n\r\n".encode() + body


def read_frame(stream) -> dict:
    headers = {}
    while True:
        line = stream.readline()
        if not line:
            raise AssertionError("bridge closed stdout before a complete frame")
        if line in {b"\r\n", b"\n"}:
            break
        name, value = line.decode("ascii").split(":", 1)
        headers[name.lower()] = value.strip()
    length = int(headers["content-length"])
    body = stream.read(length)
    if len(body) != length:
        raise AssertionError("bridge returned a truncated frame")
    return json.loads(body)


def send(process: subprocess.Popen, value: dict) -> None:
    assert process.stdin is not None
    process.stdin.write(frame(value))
    process.stdin.flush()


def main() -> None:
    env = dict(os.environ)
    env["NVIM_CLAUDE_STATE_DIR"] = str(STATE)
    process = subprocess.Popen(
        [sys.executable, str(ROOT / "python/nvim_claude_bridge.py")],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )
    assert process.stdout is not None
    try:
        send(process, {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {"state_dir": str(STATE)},
        })
        initialized = read_frame(process.stdout)
        assert initialized["id"] == 1
        result = initialized["result"]
        assert result["protocol_version"] == 1
        assert result["capabilities"]["configured_no_tools"] is True
        assert result["runtime"]["python"]
        assert result["sdk_version"]
        uuid.UUID(result["conversation"]["id"])

        send(process, {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "turn",
            "params": {
                "request_id": "budget-check",
                "epoch": 7,
                "operation": "ask",
                "envelope": {"operation": "ask", "instruction": "x" * 200},
                "model": "claude-haiku-5-5",
                "effort": "low",
                "context_limit_tokens": 100,
            },
        })
        accepted = False
        refused = False
        for _ in range(6):
            message = read_frame(process.stdout)
            if message.get("id") == 2:
                assert message["result"]["accepted"] is True
                accepted = True
            event = message.get("params", {})
            if message.get("method") == "nvim_claude/event" and event.get("type") == "error":
                assert event["request_id"] == "budget-check"
                assert "Nothing was sent" in event["message"]
                refused = True
            if accepted and refused:
                break
        assert accepted and refused, "turn was not accepted then refused at the budget boundary"

        send(process, {"jsonrpc": "2.0", "id": 3, "method": "shutdown", "params": {}})
        shutdown = read_frame(process.stdout)
        assert shutdown["id"] == 3 and shutdown["result"]["stopped"] is True
        assert process.stdin is not None
        process.stdin.close()
        assert process.wait(timeout=5) == 0
        stderr = process.stderr.read().decode() if process.stderr is not None else ""
        assert "Traceback" not in stderr, stderr
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        shutil.rmtree(STATE, ignore_errors=True)

    print("bridge-protocol=ok")


if __name__ == "__main__":
    main()
