"""Bridge between Neovim (Lua) and the Claude Agent SDK.

Protocol: newline-delimited JSON over stdio.
  Lua -> bridge:  {"id": n, "method": "...", "params": {...}}
  bridge -> Lua:  {"id": n, "result": ...} | {"id": n, "error": "..."}
                  {"id": n, "event": "delta", "text": "..."}   (streaming)
                  {"event": "log", "text": "..."}              (diagnostics)
stdout carries protocol frames only; diagnostics go to stderr.
"""

from __future__ import annotations

import asyncio
import json
import subprocess
import sys
import traceback
from importlib.metadata import version
from pathlib import Path
from typing import Any

import claude_agent_sdk
from claude_agent_sdk import (
    ClaudeAgentOptions,
    ClaudeSDKClient,
    ResultMessage,
    SystemMessage,
)
from claude_agent_sdk.types import StreamEvent

WORKSPACE = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.cwd()
CLI_PATH = Path(claude_agent_sdk.__file__).parent / "_bundled" / "claude"


def send(obj: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def log(text: str) -> None:
    sys.stderr.write(text.rstrip() + "\n")
    sys.stderr.flush()


class Bridge:
    def __init__(self) -> None:
        self.model: str | None = "claude-haiku-5-5"
        self.effort: str | None = "low"
        self.system_prompt = ""
        self.client: ClaudeSDKClient | None = None
        self.session_id: str | None = None
        self.stale = True
        self.lock = asyncio.Lock()
        self.active_id: int | None = None
        self.cancelled: set[int] = set()

    # -- client lifecycle -------------------------------------------------

    def _options(self) -> ClaudeAgentOptions:
        kwargs: dict[str, Any] = dict(
            tools=[],
            mcp_servers={},
            strict_mcp_config=True,
            setting_sources=[],
            skills=[],
            system_prompt=self.system_prompt,
            include_partial_messages=True,
            cwd=str(WORKSPACE),
            stderr=lambda line: log("[claude] " + line),
        )
        if self.model:
            kwargs["model"] = self.model
        if self.effort:
            kwargs["effort"] = self.effort
        if self.session_id:
            kwargs["resume"] = self.session_id
        return ClaudeAgentOptions(**kwargs)

    async def _drop_client(self) -> None:
        client, self.client = self.client, None
        if client is not None:
            try:
                await client.disconnect()
            except Exception as exc:  # noqa: BLE001 - shutdown best effort
                log(f"disconnect failed: {exc!r}")

    async def _ensure_client(self) -> ClaudeSDKClient:
        if self.client is not None and not self.stale:
            return self.client
        await self._drop_client()
        client = ClaudeSDKClient(options=self._options())
        await client.connect()
        self.client = client
        self.stale = False
        return client

    async def _context(self, client: ClaudeSDKClient) -> dict[str, Any]:
        try:
            usage = await client.get_context_usage()
        except Exception as exc:  # noqa: BLE001
            log(f"get_context_usage failed: {exc!r}")
            return {}
        return {
            "context_tokens": usage.get("totalTokens"),
            "max_tokens": usage.get("maxTokens"),
        }

    # -- methods ----------------------------------------------------------

    async def m_init(self, params: dict[str, Any]) -> dict[str, Any]:
        cli_version = None
        try:
            out = subprocess.run(
                [str(CLI_PATH), "--version"], capture_output=True, text=True, timeout=20
            )
            cli_version = out.stdout.strip() or None
        except Exception as exc:  # noqa: BLE001
            log(f"cli --version failed: {exc!r}")
        return {
            "python": sys.version.split()[0],
            "sdk_version": version("claude-agent-sdk"),
            "cli_version": cli_version,
            "cli_path": str(CLI_PATH),
        }

    async def m_configure(self, params: dict[str, Any]) -> dict[str, Any]:
        async with self.lock:
            for key in ("model", "effort", "system_prompt"):
                if key in params:
                    value = params[key]
                    if key == "system_prompt":
                        value = value or ""
                    elif value in ("", None):
                        value = None
                    if getattr(self, key) != value:
                        setattr(self, key, value)
                        self.stale = True
        return {"ok": True}

    async def m_models(self, params: dict[str, Any]) -> list[dict[str, Any]]:
        async with self.lock:
            client = await self._ensure_client()
            info = await client.get_server_info() or {}
        return info.get("models") or []

    async def m_query(self, req_id: int, params: dict[str, Any]) -> dict[str, Any]:
        async with self.lock:
            client = await self._ensure_client()
            self.active_id = req_id
            text_parts: list[str] = []
            result: ResultMessage | None = None
            try:
                await client.query(params["prompt"])
                async for msg in client.receive_response():
                    if isinstance(msg, StreamEvent):
                        event = msg.event
                        if event.get("type") == "content_block_delta":
                            delta = event.get("delta") or {}
                            if delta.get("type") == "text_delta" and delta.get("text"):
                                text_parts.append(delta["text"])
                                if params.get("stream"):
                                    send({"id": req_id, "event": "delta", "text": delta["text"]})
                    elif isinstance(msg, ResultMessage):
                        result = msg
            finally:
                self.active_id = None
            cancelled = req_id in self.cancelled
            self.cancelled.discard(req_id)
            if result is not None and result.session_id:
                self.session_id = result.session_id
            out: dict[str, Any] = {
                "cancelled": cancelled,
                "session_id": self.session_id,
                "text": (result.result if result and result.result is not None else "".join(text_parts)),
                "is_error": bool(result.is_error) if result else True,
                "subtype": result.subtype if result else None,
            }
            out.update(await self._context(client))
            return out

    async def m_cancel(self, params: dict[str, Any]) -> dict[str, Any]:
        target = params.get("id")
        if self.client is not None and self.active_id is not None and (
            target is None or target == self.active_id
        ):
            self.cancelled.add(self.active_id)
            await self.client.interrupt()
            return {"interrupted": True}
        return {"interrupted": False}

    async def m_compact(self, params: dict[str, Any]) -> dict[str, Any]:
        async with self.lock:
            if self.client is None and self.session_id is None:
                return {"ok": False, "reason": "no conversation to compact"}
            client = await self._ensure_client()
            meta: dict[str, Any] = {}
            ok = False
            await client.query("/compact")
            async for msg in client.receive_response():
                if isinstance(msg, SystemMessage):
                    if msg.subtype == "compact_boundary":
                        meta = msg.data.get("compact_metadata") or {}
                        ok = True
                    elif msg.data.get("compact_result") == "success":
                        ok = True
                elif isinstance(msg, ResultMessage) and msg.session_id:
                    self.session_id = msg.session_id
            out: dict[str, Any] = {
                "ok": ok,
                "pre_tokens": meta.get("pre_tokens"),
                "post_tokens": meta.get("post_tokens"),
                "session_id": self.session_id,
            }
            out.update(await self._context(client))
            return out

    async def m_context(self, params: dict[str, Any]) -> dict[str, Any]:
        if self.client is None:
            return {}
        async with self.lock:
            return await self._context(self.client)

    async def m_new(self, params: dict[str, Any]) -> dict[str, Any]:
        async with self.lock:
            await self._drop_client()
            self.session_id = None
            self.stale = True
        return {"ok": True}

    async def m_resume(self, params: dict[str, Any]) -> dict[str, Any]:
        async with self.lock:
            await self._drop_client()
            self.session_id = params["session_id"]
            self.stale = True
        return {"ok": True}

    async def m_shutdown(self, params: dict[str, Any]) -> dict[str, Any]:
        async with self.lock:
            await self._drop_client()
        return {"ok": True}


async def handle(bridge: Bridge, msg: dict[str, Any]) -> None:
    req_id = msg.get("id")
    method = msg.get("method", "")
    params = msg.get("params") or {}
    try:
        if method == "query":
            result = await bridge.m_query(req_id, params)
        else:
            fn = getattr(bridge, "m_" + method, None)
            if fn is None:
                raise ValueError(f"unknown method {method!r}")
            result = await fn(params)
        send({"id": req_id, "result": result})
    except Exception as exc:  # noqa: BLE001 - report every failure to Lua
        log(traceback.format_exc())
        send({"id": req_id, "error": f"{type(exc).__name__}: {exc}"})
    if method == "shutdown":
        asyncio.get_running_loop().stop()


async def main() -> None:
    WORKSPACE.mkdir(parents=True, exist_ok=True)
    bridge = Bridge()
    loop = asyncio.get_running_loop()
    tasks: set[asyncio.Task[None]] = set()
    while True:
        line = await loop.run_in_executor(None, sys.stdin.readline)
        if not line:
            break
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            log(f"bad frame: {line[:200]}")
            continue
        task = asyncio.create_task(handle(bridge, msg))
        tasks.add(task)
        task.add_done_callback(tasks.discard)
    await bridge.m_shutdown({})


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except (KeyboardInterrupt, RuntimeError):
        pass
