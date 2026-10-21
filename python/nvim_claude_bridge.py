#!/usr/bin/env python3
"""JSON-RPC bridge between Neovim and the Claude Agent SDK."""

from __future__ import annotations

import asyncio
import dataclasses
import importlib.metadata
import inspect
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
from typing import Any

from claude_agent_sdk import (
    AssistantMessage,
    ClaudeAgentOptions,
    ClaudeSDKClient,
    ResultMessage,
    StreamEvent,
    TextBlock,
)


class Protocol:
    def __init__(self) -> None:
        self._write_lock = asyncio.Lock()

    @staticmethod
    def read_frame() -> dict[str, Any] | None:
        headers: dict[str, str] = {}
        while True:
            line = sys.stdin.buffer.readline()
            if not line:
                return None
            if line in (b"\r\n", b"\n"):
                break
            name, value = line.decode("ascii").split(":", 1)
            headers[name.lower()] = value.strip()
        body = sys.stdin.buffer.read(int(headers["content-length"]))
        return json.loads(body)

    async def write(self, message: dict[str, Any]) -> None:
        body = json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode()
        frame = f"Content-Length: {len(body)}\r\n\r\n".encode() + body
        async with self._write_lock:
            sys.stdout.buffer.write(frame)
            sys.stdout.buffer.flush()

    async def result(self, request_id: Any, value: Any) -> None:
        await self.write({"jsonrpc": "2.0", "id": request_id, "result": value})

    async def error(self, request_id: Any, code: int, message: str) -> None:
        await self.write({"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}})

    async def notify(self, method: str, params: dict[str, Any]) -> None:
        await self.write({"jsonrpc": "2.0", "method": method, "params": params})


class Bridge:
    def __init__(self, protocol: Protocol) -> None:
        self.protocol = protocol
        self.state_dir = Path()
        self.system_prompt = ""
        self.model = "claude-haiku-5-5"
        self.effort: str | None = "low"
        self.limit = 100_000
        self.ttl = 3600
        self.client: ClaudeSDKClient | None = None
        self.active_task: asyncio.Task[None] | None = None
        self.cancelled: set[str] = set()
        self.epoch = 0
        self.sticky = False
        self.active: dict[str, Any] = self._new_conversation()
        self.saved: dict[str, dict[str, Any]] = {}
        self.server_info: dict[str, Any] = {}
        self.context_usage: dict[str, Any] = {}
        self.runtime_versions: dict[str, str] = {}
        self.manifest_path = Path()

    def _new_conversation(self) -> dict[str, Any]:
        return {
            "id": f"conversation-{time.time_ns()}",
            "created": time.time(),
            "first_prompt": "",
            "saved": getattr(self, "sticky", False),
            "session_id": None,
            "last_request": None,
            "usage": {},
            "transcript": [],
            "baselines": {},
        }

    def _manifest(self) -> dict[str, Any]:
        return {"version": 1, "owner_pid": os.getpid(), "sticky": self.sticky, "active": self.active, "saved": self.saved}

    def _save_manifest(self) -> None:
        self.state_dir.mkdir(parents=True, exist_ok=True)
        temporary = self.manifest_path.with_suffix(".tmp")
        temporary.write_text(json.dumps(self._manifest(), ensure_ascii=False, indent=2))
        temporary.replace(self.manifest_path)

    @staticmethod
    def _alive(pid: int | None) -> bool:
        if not pid:
            return False
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False

    def _delete_session(self, session_id: str | None) -> None:
        if not session_id:
            return
        projects = Path.home() / ".claude" / "projects"
        for record in projects.glob(f"*/{session_id}.jsonl"):
            try:
                record.unlink()
            except OSError:
                pass

    async def initialize(self, params: dict[str, Any]) -> dict[str, Any]:
        self.state_dir = Path(params["state_dir"])
        self.manifest_path = self.state_dir / "conversations.json"
        self.system_prompt = (Path(params["plugin_root"]) / "resources" / "system-prompt.txt").read_text()
        self.model = params["model"]
        self.effort = params.get("effort")
        self.limit = int(params["context_limit_tokens"])
        self.ttl = int(params["cache_ttl_seconds"])
        if self.manifest_path.exists():
            try:
                old = json.loads(self.manifest_path.read_text())
                if not self._alive(old.get("owner_pid")):
                    abandoned = old.get("active", {})
                    if abandoned and not abandoned.get("saved"):
                        self._delete_session(abandoned.get("session_id"))
                self.saved = old.get("saved", {})
                self.sticky = bool(old.get("sticky", False))
            except (OSError, ValueError):
                pass
        self.active = self._new_conversation()
        self.runtime_versions = self._versions()
        self._save_manifest()
        return {"protocol_version": 1, "capabilities": {"streaming": True, "sessions": True, "cancellation": True}, "versions": self.runtime_versions}

    def _versions(self) -> dict[str, str]:
        versions = {"python": sys.version.split()[0], "sdk": importlib.metadata.version("claude-agent-sdk")}
        cli = self._cli_path()
        if cli:
            try:
                versions["cli"] = subprocess.run([str(cli), "--version"], capture_output=True, text=True, timeout=10).stdout.strip()
            except (OSError, subprocess.SubprocessError):
                versions["cli"] = "unavailable"
        return versions

    @staticmethod
    def _cli_path() -> Path | None:
        import claude_agent_sdk
        root = Path(claude_agent_sdk.__file__).parent
        candidates = [root / "_bundled" / "claude", root / "_bundled" / "claude.exe"]
        return next((path for path in candidates if path.exists()), None)

    def _options(self) -> ClaudeAgentOptions:
        available = set(inspect.signature(ClaudeAgentOptions).parameters)
        values: dict[str, Any] = {
            "tools": [],
            "allowed_tools": [],
            "system_prompt": self.system_prompt,
            "mcp_servers": {},
            "strict_mcp_config": True,
            "setting_sources": [],
            "agents": {},
            "skills": [],
            "plugins": [],
            "include_partial_messages": True,
            "model": self.model,
            "fallback_model": None,
            "effort": self.effort,
            "resume": self.active.get("session_id"),
            "cwd": str(self.state_dir),
            "env": {"CLAUDE_CODE_AUTO_COMPACT_WINDOW": str(max(self.limit, 100_000))},
        }
        return ClaudeAgentOptions(**{key: value for key, value in values.items() if key in available})

    async def _connect(self) -> None:
        if self.client is not None:
            return
        self.client = ClaudeSDKClient(self._options())
        await self.client.connect()
        self.server_info = await self.client.get_server_info() or {}
        tools = self._find_values(self.server_info, {"tools"})
        unexpected = [item for item in tools if isinstance(item, str) and item not in {"compact"}]
        if unexpected:
            await self.client.disconnect()
            self.client = None
            raise RuntimeError("runtime announced unexpected model tools: " + ", ".join(unexpected))

    @staticmethod
    def _find_values(value: Any, keys: set[str]) -> list[Any]:
        found: list[Any] = []
        if isinstance(value, dict):
            for key, child in value.items():
                if key in keys and isinstance(child, list):
                    found.extend(child)
                else:
                    found.extend(Bridge._find_values(child, keys))
        elif isinstance(value, list):
            for child in value:
                found.extend(Bridge._find_values(child, keys))
        return found

    async def _disconnect(self) -> None:
        if self.client:
            await self.client.disconnect()
            self.client = None

    async def _usage(self) -> dict[str, Any]:
        if not self.client:
            return self.context_usage
        try:
            usage = await self.client.get_context_usage()
            self.context_usage = dataclasses.asdict(usage) if dataclasses.is_dataclass(usage) else dict(usage)
        except Exception:
            pass
        return self.context_usage

    @staticmethod
    def _occupancy(usage: dict[str, Any]) -> int:
        for key in ("context_window_used", "input_tokens", "total_input_tokens", "tokens"):
            value = usage.get(key)
            if isinstance(value, int):
                return value
        return 0

    async def _budget(self, encoded: str) -> tuple[bool, str | None]:
        usage = await self._usage()
        occupied = self._occupancy(usage)
        # One UTF-8 byte per token is a conservative upper bound for supplied text.
        # The fixed reserve covers the static prompt, runtime additions, and output.
        required = occupied + len(encoded.encode("utf-8")) + 20_000
        if required <= self.limit:
            return True, None
        if occupied and self.active.get("session_id"):
            await self._compact()
            required = len(encoded.encode("utf-8")) + 20_000
        if required > self.limit:
            return False, f"The request cannot fit the {self.limit:,}-token local ceiling. Conservative bound: {required:,} tokens."
        return True, None

    @staticmethod
    def _stream_text(message: StreamEvent) -> str:
        event = message.event
        if event.get("type") == "content_block_delta":
            delta = event.get("delta", {})
            if delta.get("type") == "text_delta":
                return delta.get("text", "")
        nested = event.get("event", {})
        if nested.get("type") == "content_block_delta":
            return nested.get("delta", {}).get("text", "")
        return ""

    async def request(self, params: dict[str, Any]) -> None:
        request_key = str(params["request_id"])
        try:
            last = self.active.get("last_request")
            if last and not self.active.get("saved") and time.time() - last > self.ttl:
                self._delete_session(self.active.get("session_id"))
                await self._disconnect()
                self.active = self._new_conversation()
                self.epoch += 1
            encoded = json.dumps(params["payload"], ensure_ascii=False, separators=(",", ":"))
            allowed, reason = await self._budget(encoded)
            if not allowed:
                await self.protocol.notify("request/error", {"request_id": request_key, "epoch": self.epoch, "message": reason})
                return
            await self._connect()
            await self.client.query(encoded)
            partial = ""
            final_text = ""
            result: ResultMessage | None = None
            async for message in self.client.receive_response():
                if request_key in self.cancelled:
                    return
                if isinstance(message, StreamEvent):
                    delta = self._stream_text(message)
                    if delta:
                        partial += delta
                        await self.protocol.notify("request/partial", {"request_id": request_key, "epoch": self.epoch, "text": delta})
                elif isinstance(message, AssistantMessage):
                    final_text = "".join(block.text for block in message.content if isinstance(block, TextBlock))
                elif isinstance(message, ResultMessage):
                    result = message
            if request_key in self.cancelled:
                return
            if not result or result.is_error:
                errors = "; ".join(result.errors or []) if result else "no result message"
                raise RuntimeError(errors or "Claude request failed")
            raw = final_text or partial or result.result or ""
            self.active["session_id"] = result.session_id
            self.active["last_request"] = time.time()
            self.active["usage"] = result.usage or {}
            self.active["transcript"].append({"request": params["payload"], "response": raw, "time": time.time()})
            if not self.active["first_prompt"]:
                self.active["first_prompt"] = params["payload"].get("instruction", "")
            if self.active.get("saved"):
                self.saved[self.active["id"]] = self.active
            self._save_manifest()
            await self.protocol.notify("request/complete", {
                "request_id": request_key,
                "epoch": self.epoch,
                "text": raw,
                "session_id": result.session_id,
                "usage": result.usage or {},
                "new_session": len(self.active["transcript"]) == 1,
            })
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            await self.protocol.notify("request/error", {"request_id": request_key, "epoch": self.epoch, "message": str(exc)})
        finally:
            self.active_task = None
            self.cancelled.discard(request_key)

    async def _compact(self) -> None:
        await self._connect()
        await self.client.query("/compact")
        async for message in self.client.receive_response():
            if isinstance(message, ResultMessage) and message.is_error:
                raise RuntimeError("runtime compaction failed")
        self.active["baselines"] = {}
        self.context_usage = {}

    async def command(self, params: dict[str, Any]) -> Any:
        action = params["action"]
        if action in {"new", "clear", "resume"}:
            if self.active_task:
                await self.cancel({})
            await self._disconnect()
            self.epoch += 1
        if action == "new":
            if not self.active.get("saved"):
                self._delete_session(self.active.get("session_id"))
            self.active = self._new_conversation()
        elif action == "clear":
            saved_copy = self.saved.get(self.active["id"])
            if not self.active.get("saved"):
                self._delete_session(self.active.get("session_id"))
            self.active = self._new_conversation()
            if saved_copy:
                self.saved[saved_copy["id"]] = saved_copy
        elif action == "save":
            self.active["saved"] = True
            self.saved[self.active["id"]] = self.active
        elif action == "sticky":
            requested = params.get("value")
            self.sticky = (not self.sticky) if requested is None else bool(requested)
            if self.sticky:
                self.active["saved"] = True
                self.saved[self.active["id"]] = self.active
        elif action == "compact":
            if not self.active.get("session_id"):
                raise RuntimeError("there is no active conversation to compact")
            await self._compact()
        elif action == "resume":
            conversation_id = params["id"]
            if conversation_id not in self.saved:
                raise RuntimeError("saved conversation not found")
            self.active = self.saved[conversation_id]
        elif action == "set_config":
            changed = params.get("model") != self.model or params.get("effort") != self.effort
            self.model = params.get("model", self.model)
            self.effort = params.get("effort", self.effort)
            self.limit = int(params.get("context_limit_tokens", self.limit))
            if changed:
                await self._disconnect()
        elif action == "system_prompt":
            self.system_prompt = params["text"]
            await self._disconnect()
        else:
            raise RuntimeError(f"unknown command: {action}")
        self._save_manifest()
        return {"epoch": self.epoch, "sticky": self.sticky, "conversation_id": self.active["id"]}

    async def cancel(self, params: dict[str, Any]) -> dict[str, bool]:
        if not self.active_task:
            return {"cancelled": False}
        request_id = str(params.get("request_id", ""))
        if request_id:
            self.cancelled.add(request_id)
        if self.client:
            await self.client.interrupt()
        self.active_task.cancel()
        self.active_task = None
        return {"cancelled": True}

    def models(self) -> dict[str, Any]:
        models = self._find_values(self.server_info, {"models", "availableModels", "available_models"})
        return {"models": models, "source": "runtime initialization metadata" if models else "unavailable"}

    async def info(self) -> dict[str, Any]:
        usage = await self._usage()
        return {
            "model": self.model,
            "effort": self.effort,
            "context_limit_tokens": self.limit,
            "context_usage": usage,
            "cumulative_usage": self.active.get("usage", {}),
            "saved": bool(self.active.get("saved")),
            "sticky": self.sticky,
            "session_id": self.active.get("session_id"),
            "cache": {"ttl_seconds": self.ttl, "provenance": "estimated from configured billing mode"},
            "versions": self.runtime_versions,
            "models": self.models(),
            "no_tools": {"requested": True, "server_info": self.server_info},
        }

    def list_saved(self) -> list[dict[str, Any]]:
        rows = []
        for conversation in self.saved.values():
            rows.append({"id": conversation["id"], "created": conversation["created"], "first_prompt": conversation.get("first_prompt", "")})
        return sorted(rows, key=lambda item: item["created"], reverse=True)

    async def shutdown(self) -> dict[str, bool]:
        await self._disconnect()
        if not self.active.get("saved"):
            self._delete_session(self.active.get("session_id"))
        try:
            self.manifest_path.unlink()
        except OSError:
            pass
        return {"ok": True}


async def main() -> None:
    protocol = Protocol()
    bridge = Bridge(protocol)
    while True:
        message = await asyncio.to_thread(protocol.read_frame)
        if message is None:
            break
        request_id = message.get("id")
        method = message.get("method")
        params = message.get("params", {})
        try:
            if method == "initialize":
                await protocol.result(request_id, await bridge.initialize(params))
            elif method == "request":
                if bridge.active_task:
                    await protocol.error(request_id, -32001, "the active conversation is busy")
                else:
                    bridge.active_task = asyncio.create_task(bridge.request(params))
                    await protocol.result(request_id, {"accepted": True, "epoch": bridge.epoch})
            elif method == "cancel":
                await protocol.result(request_id, await bridge.cancel(params))
            elif method == "command":
                await protocol.result(request_id, await bridge.command(params))
            elif method == "models":
                if not bridge.server_info:
                    await bridge._connect()
                await protocol.result(request_id, bridge.models())
            elif method == "list":
                await protocol.result(request_id, bridge.list_saved())
            elif method == "info":
                await protocol.result(request_id, await bridge.info())
            elif method == "login":
                cli = bridge._cli_path()
                await protocol.result(request_id, {"argv": [str(cli), "login"] if cli else None})
            elif method == "shutdown":
                await protocol.result(request_id, await bridge.shutdown())
                break
            else:
                await protocol.error(request_id, -32601, f"unknown method: {method}")
        except Exception as exc:
            await protocol.error(request_id, -32000, str(exc))


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
