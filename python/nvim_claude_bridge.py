#!/usr/bin/env python3
"""Claude Agent SDK bridge for nvim-claude.

Stdout is reserved for Content-Length framed JSON-RPC. Diagnostics use stderr.
"""

from __future__ import annotations

import argparse
import asyncio
import dataclasses
import importlib.metadata
import json
import os
from pathlib import Path
import signal
import sys
import time
import uuid
from typing import Any

from claude_agent_sdk import ClaudeAgentOptions, ClaudeSDKClient
from claude_agent_sdk.types import AssistantMessage, ResultMessage, StreamEvent, TextBlock, ToolUseBlock


class RpcFailure(Exception):
    def __init__(self, message: str, code: int = -32000, data: Any = None) -> None:
        super().__init__(message)
        self.code = code
        self.data = data


class FramedRpc:
    def __init__(self) -> None:
        self.reader = asyncio.StreamReader()
        self.write_lock = asyncio.Lock()

    async def connect(self) -> None:
        loop = asyncio.get_running_loop()
        protocol = asyncio.StreamReaderProtocol(self.reader)
        await loop.connect_read_pipe(lambda: protocol, sys.stdin.buffer)

    async def read(self) -> dict[str, Any] | None:
        headers: dict[str, str] = {}
        while True:
            line = await self.reader.readline()
            if not line:
                return None
            if line == b"\r\n":
                break
            name, _, value = line.decode("ascii", "strict").partition(":")
            headers[name.lower()] = value.strip()
        try:
            length = int(headers["content-length"])
        except (KeyError, ValueError) as error:
            raise RpcFailure("Invalid Content-Length header", -32700) from error
        body = await self.reader.readexactly(length)
        try:
            return json.loads(body)
        except json.JSONDecodeError as error:
            raise RpcFailure("Invalid JSON", -32700) from error

    async def write(self, message: dict[str, Any]) -> None:
        payload = json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode()
        frame = f"Content-Length: {len(payload)}\r\n\r\n".encode() + payload
        async with self.write_lock:
            sys.stdout.buffer.write(frame)
            sys.stdout.buffer.flush()

    async def result(self, request_id: Any, result: Any) -> None:
        await self.write({"jsonrpc": "2.0", "id": request_id, "result": result})

    async def error(self, request_id: Any, failure: Exception) -> None:
        if isinstance(failure, RpcFailure):
            error = {"code": failure.code, "message": str(failure)}
            if failure.data is not None:
                error["data"] = failure.data
        else:
            error = {"code": -32603, "message": str(failure)}
        await self.write({"jsonrpc": "2.0", "id": request_id, "error": error})

    async def notify(self, method: str, params: dict[str, Any]) -> None:
        await self.write({"jsonrpc": "2.0", "method": method, "params": params})


class Store:
    def __init__(self, root: Path, instance_id: str) -> None:
        self.root = root
        self.root.mkdir(parents=True, exist_ok=True)
        self.instances = root / "instances"
        self.instances.mkdir(exist_ok=True)
        self.manifest_path = root / "manifest.json"
        self.instance_path = self.instances / f"{instance_id}.json"
        self.manifest = self._read(self.manifest_path, {"sticky": False, "saved": []})
        self.unsaved_sessions: set[str] = set()
        self._cleanup_abandoned_instances()
        self._write_instance()

    @staticmethod
    def _read(path: Path, fallback: Any) -> Any:
        try:
            return json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            return fallback

    @staticmethod
    def _atomic_write(path: Path, value: Any) -> None:
        temporary = path.with_suffix(path.suffix + f".{os.getpid()}.tmp")
        temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
        temporary.replace(path)

    @staticmethod
    def _alive(pid: Any) -> bool:
        if not isinstance(pid, int):
            return False
        try:
            os.kill(pid, 0)
            return True
        except (OSError, ValueError):
            return False

    @staticmethod
    def _delete_transcript(session_id: str) -> None:
        if not session_id or "/" in session_id or session_id.startswith("."):
            return
        projects = Path.home() / ".claude" / "projects"
        if not projects.exists():
            return
        for path in projects.glob(f"**/{session_id}.jsonl"):
            try:
                path.unlink()
            except OSError:
                pass

    def _cleanup_abandoned_instances(self) -> None:
        for path in self.instances.glob("*.json"):
            if path == self.instance_path:
                continue
            record = self._read(path, {})
            if self._alive(record.get("pid")):
                continue
            for session_id in record.get("unsaved_sessions", []):
                self._delete_transcript(session_id)
            try:
                path.unlink()
            except OSError:
                pass

    def _write_instance(self) -> None:
        self._atomic_write(
            self.instance_path,
            {"pid": os.getpid(), "unsaved_sessions": sorted(self.unsaved_sessions), "updated": time.time()},
        )

    def track_unsaved(self, session_id: str | None) -> None:
        if session_id:
            self.unsaved_sessions.add(session_id)
            self._write_instance()

    def untrack(self, session_id: str | None) -> None:
        if session_id:
            self.unsaved_sessions.discard(session_id)
            self._write_instance()

    def delete_unsaved(self, session_id: str | None) -> None:
        if session_id and session_id in self.unsaved_sessions:
            self._delete_transcript(session_id)
            self.unsaved_sessions.discard(session_id)
            self._write_instance()

    def saved(self) -> list[dict[str, Any]]:
        return list(self.manifest.get("saved", []))

    def save_conversation(self, conversation: dict[str, Any]) -> None:
        saved = [item for item in self.saved() if item["id"] != conversation["id"]]
        saved.append({key: value for key, value in conversation.items() if key != "client"})
        saved.sort(key=lambda item: item.get("updated", 0), reverse=True)
        self.manifest["saved"] = saved
        self._atomic_write(self.manifest_path, self.manifest)
        self.untrack(conversation.get("session_id"))

    def sticky(self, value: bool | None = None) -> bool:
        if value is not None:
            self.manifest["sticky"] = value
            self._atomic_write(self.manifest_path, self.manifest)
        return bool(self.manifest.get("sticky"))

    def close(self) -> None:
        for session_id in list(self.unsaved_sessions):
            self._delete_transcript(session_id)
        self.unsaved_sessions.clear()
        try:
            self.instance_path.unlink()
        except OSError:
            pass


class Bridge:
    def __init__(self, rpc: FramedRpc, state_dir: Path, resource: Path, instance_id: str) -> None:
        self.rpc = rpc
        self.store = Store(state_dir, instance_id)
        self.workspace = state_dir / "workspace"
        self.workspace.mkdir(exist_ok=True)
        self.default_prompt = resource.read_text()
        self.client: ClaudeSDKClient | None = None
        self.client_signature: tuple[Any, ...] | None = None
        self.server_info: dict[str, Any] = {}
        self.active_task: asyncio.Task[Any] | None = None
        self.active_request_id: str | None = None
        self.canceled: set[str] = set()
        self.current = self._new_conversation()
        self.sdk_version = importlib.metadata.version("claude-agent-sdk")
        self.cli_path = self._find_cli()
        self.cli_version: str | None = None
        self.closed = False

    def _new_conversation(self) -> dict[str, Any]:
        now = time.time()
        return {
            "id": str(uuid.uuid4()),
            "session_id": None,
            "created": now,
            "updated": now,
            "last_activity": None,
            "first_prompt": "",
            "saved": self.store.sticky(),
            "model": None,
            "effort": None,
            "context_limit_tokens": None,
            "cumulative_usage": {},
            "total_cost_usd": 0.0,
        }

    @staticmethod
    def _find_cli() -> str | None:
        try:
            import claude_agent_sdk
            package = Path(claude_agent_sdk.__file__).parent
            candidates = [package / "_bundled" / "claude", package / "_bundled" / "claude.exe"]
            return str(next(path for path in candidates if path.exists()))
        except (ImportError, StopIteration):
            return None

    async def _read_cli_version(self) -> str | None:
        if self.cli_version is not None:
            return self.cli_version
        if not self.cli_path:
            return None
        try:
            process = await asyncio.create_subprocess_exec(
                self.cli_path, "--version", stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
            )
            stdout, _ = await asyncio.wait_for(process.communicate(), 10)
            self.cli_version = stdout.decode(errors="replace").strip() or None
        except (OSError, asyncio.TimeoutError):
            self.cli_version = None
        return self.cli_version

    def _options(self, params: dict[str, Any]) -> ClaudeAgentOptions:
        config = params["config"]
        budget = config.get("context_limit_tokens")
        env: dict[str, str] = {}
        if budget and budget >= 100_000:
            env["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] = str(budget)
        options: dict[str, Any] = {
            "tools": [],
            "allowed_tools": [],
            "mcp_servers": {},
            "strict_mcp_config": True,
            "setting_sources": [],
            "skills": [],
            "agents": {},
            "plugins": [],
            "system_prompt": {
                "type": "custom",
                "prompt": params.get("system_prompt") or self.default_prompt,
                "snapshot": False,
            },
            "model": config.get("model"),
            "effort": config.get("effort"),
            "include_partial_messages": True,
            "max_turns": 1,
            "cwd": self.workspace,
            "env": env,
            "max_buffer_size": 16 * 1024 * 1024,
        }
        if self.current.get("session_id"):
            options["resume"] = self.current["session_id"]
        return ClaudeAgentOptions(**options)

    async def _disconnect(self) -> None:
        client, self.client = self.client, None
        self.client_signature = None
        if client:
            try:
                await client.disconnect()
            except Exception as error:
                print(f"disconnect: {error}", file=sys.stderr)

    async def _ensure_client(self, params: dict[str, Any]) -> ClaudeSDKClient:
        config = params["config"]
        signature = (
            self.current.get("session_id"),
            config.get("model"),
            config.get("effort"),
            config.get("context_limit_tokens"),
            params.get("system_prompt") or self.default_prompt,
        )
        if self.client and signature == self.client_signature:
            return self.client
        await self._disconnect()
        client = ClaudeSDKClient(options=self._options(params))
        try:
            await client.connect()
            self.server_info = await client.get_server_info() or {}
            await self._verify_no_tools(client)
        except Exception:
            try:
                await client.disconnect()
            except Exception:
                pass
            raise
        self.client = client
        self.client_signature = signature
        return client

    async def _verify_no_tools(self, client: ClaudeSDKClient) -> None:
        usage = await client.get_context_usage()
        unexpected = []
        for field in ("mcpTools", "agents", "skills"):
            values = self._field(usage, field, [])
            if values:
                unexpected.append(field)
        if unexpected:
            raise RpcFailure("Runtime exposed forbidden capabilities: " + ", ".join(unexpected))

    @staticmethod
    def _field(value: Any, name: str, default: Any = None) -> Any:
        if isinstance(value, dict):
            return value.get(name, default)
        return getattr(value, name, default)

    @staticmethod
    def _as_dict(value: Any) -> Any:
        if dataclasses.is_dataclass(value):
            return dataclasses.asdict(value)
        if isinstance(value, dict):
            return value
        if hasattr(value, "__dict__"):
            return vars(value)
        return value

    async def _context_usage(self, client: ClaudeSDKClient) -> dict[str, Any]:
        return self._as_dict(await client.get_context_usage())

    async def _compact(self, client: ClaudeSDKClient, request_id: str, automatic: bool) -> dict[str, Any]:
        await self.rpc.notify("status", {"request_id": request_id, "state": "compacting", "automatic": automatic})
        await client.query("/compact")
        result: ResultMessage | None = None
        async for message in client.receive_response():
            if isinstance(message, ToolUseBlock):
                await client.interrupt()
                raise RpcFailure("Runtime attempted a tool during compaction")
            if isinstance(message, ResultMessage):
                result = message
        if not result or result.is_error:
            raise RpcFailure("Runtime compaction failed" + (f": {result.result}" if result and result.result else ""))
        self.current["session_id"] = result.session_id
        self.current["updated"] = time.time()
        return {"session_id": result.session_id, "usage": self._as_dict(result.usage)}

    async def _budget(self, client: ClaudeSDKClient, params: dict[str, Any], prompt: str) -> dict[str, Any]:
        config = params["config"]
        limit = config.get("context_limit_tokens")
        if not limit:
            return await self._context_usage(client)
        overhead = int(config.get("runtime_overhead_tokens", 16384))
        reserve = int(config.get("output_reserve_tokens", 8192))
        prompt_bytes = len(prompt.encode())
        system_bytes = len((params.get("system_prompt") or self.default_prompt).encode())
        mandatory = prompt_bytes + system_bytes + overhead + reserve
        if mandatory > limit:
            raise RpcFailure(
                f"Mandatory input needs a conservative {mandatory:,}-token bound, above the {limit:,}-token budget"
            )
        usage = await self._context_usage(client)
        current = int(usage.get("totalTokens", 0))
        if current + prompt_bytes + overhead + reserve <= limit:
            return usage
        compact_bound = current + len("/compact") + overhead + reserve
        if compact_bound > limit:
            raise RpcFailure(
                f"Context occupancy {current:,} is too close to the {limit:,}-token budget to compact safely"
            )
        await self._compact(client, params["request_id"], True)
        usage = await self._context_usage(client)
        current = int(usage.get("totalTokens", 0))
        if current + prompt_bytes + overhead + reserve > limit:
            raise RpcFailure("The request remains above the configured budget after compaction")
        return usage

    async def request(self, params: dict[str, Any]) -> dict[str, Any]:
        if self.active_task and self.active_task is not asyncio.current_task():
            raise RpcFailure("The conversation is busy; the draft was not sent")
        request_id = str(params["request_id"])
        self.active_task = asyncio.current_task()
        self.active_request_id = request_id
        try:
            ttl = int(params.get("cache_ttl_seconds", 3600))
            last = self.current.get("last_activity")
            if last and not self.current.get("saved") and time.time() - last > ttl:
                await self._discard_current()
                self.current = self._new_conversation()
                await self.rpc.notify("session", {"request_id": request_id, "state": "new", "reason": "expired"})
            else:
                await self.rpc.notify(
                    "session",
                    {"request_id": request_id, "state": "continued" if self.current.get("session_id") else "new"},
                )

            client = await self._ensure_client(params)
            prompt = json.dumps(params["payload"], ensure_ascii=False, separators=(",", ":"))
            usage_before = await self._budget(client, params, prompt)
            if request_id in self.canceled:
                raise RpcFailure("Request canceled", -32800)
            await client.query(prompt)
            final_text = ""
            result: ResultMessage | None = None
            tool_seen = False
            async for message in client.receive_response():
                if request_id in self.canceled:
                    await client.interrupt()
                    raise RpcFailure("Request canceled", -32800)
                if isinstance(message, StreamEvent):
                    event = message.event
                    delta = event.get("delta", {}) if isinstance(event, dict) else {}
                    text = delta.get("text") if isinstance(delta, dict) else None
                    if text and params["payload"]["operation"] == "ask":
                        await self.rpc.notify("stream", {"request_id": request_id, "text": text})
                elif isinstance(message, AssistantMessage):
                    pieces = []
                    for block in message.content:
                        if isinstance(block, ToolUseBlock):
                            tool_seen = True
                        elif isinstance(block, TextBlock):
                            pieces.append(block.text)
                    if pieces:
                        final_text += "".join(pieces)
                elif isinstance(message, ResultMessage):
                    result = message
            if tool_seen:
                raise RpcFailure("Runtime exposed a tool to the model; output was rejected")
            if not result:
                raise RpcFailure("SDK response ended without a result")
            if result.is_error:
                detail = result.result or "; ".join(result.errors or []) or result.subtype
                raise RpcFailure(f"Claude request failed: {detail}")
            if not final_text and result.result:
                final_text = result.result

            self.current["session_id"] = result.session_id
            self.current["updated"] = time.time()
            self.current["last_activity"] = time.time()
            self.current["model"] = params["config"].get("model")
            self.current["effort"] = params["config"].get("effort")
            self.current["context_limit_tokens"] = params["config"].get("context_limit_tokens")
            turn_usage = self._as_dict(result.usage) or {}
            cumulative = dict(self.current.get("cumulative_usage") or {})
            if isinstance(turn_usage, dict):
                for key, value in turn_usage.items():
                    if isinstance(value, (int, float)) and not isinstance(value, bool):
                        cumulative[key] = cumulative.get(key, 0) + value
            self.current["cumulative_usage"] = cumulative
            self.current["total_cost_usd"] = self.current.get("total_cost_usd", 0.0) + (result.total_cost_usd or 0.0)
            if not self.current["first_prompt"]:
                self.current["first_prompt"] = params.get("instruction", "")
            if self.current.get("saved") or self.store.sticky():
                self.current["saved"] = True
                self.store.save_conversation(self.current)
            else:
                self.store.track_unsaved(result.session_id)
            usage_after = await self._context_usage(client)
            return {
                "request_id": request_id,
                "text": final_text,
                "session_id": result.session_id,
                "resolved_model": self._resolved_model(result),
                "usage_before": usage_before,
                "usage_after": usage_after,
                "cumulative_usage": cumulative,
                "cost_usd": result.total_cost_usd,
            }
        except RpcFailure:
            raise
        except Exception as error:
            message = str(error)
            lower = message.lower()
            if "auth" in lower or "login" in lower or "credential" in lower:
                raise RpcFailure(
                    "Claude authentication is unavailable. Run :NvClaude login to use the bundled runtime's login flow.",
                    data={"login_command": self.cli_path},
                ) from error
            raise RpcFailure(message) from error
        finally:
            self.active_task = None
            self.active_request_id = None
            self.canceled.discard(request_id)

    @staticmethod
    def _resolved_model(result: ResultMessage) -> str | None:
        if result.model_usage:
            return next(iter(result.model_usage.keys()), None)
        return None

    async def cancel(self, params: dict[str, Any]) -> None:
        request_id = str(params.get("request_id") or self.active_request_id or "")
        if request_id:
            self.canceled.add(request_id)
        if self.client and self.active_task:
            try:
                await self.client.interrupt()
            except Exception as error:
                print(f"interrupt: {error}", file=sys.stderr)

    async def _settle_active(self) -> None:
        if self.active_task and self.active_task is not asyncio.current_task():
            await self.cancel({})
            try:
                await asyncio.wait_for(asyncio.shield(self.active_task), 10)
            except (asyncio.TimeoutError, Exception):
                pass

    async def _discard_current(self) -> None:
        await self._disconnect()
        if not self.current.get("saved"):
            self.store.delete_unsaved(self.current.get("session_id"))

    async def command(self, params: dict[str, Any]) -> Any:
        await self._settle_active()
        action = params.get("action")
        if action in {"new", "clear"}:
            await self._discard_current()
            self.current = self._new_conversation()
            return {"state": "new", "action": action}
        if action == "save":
            self.current["saved"] = True
            self.current["updated"] = time.time()
            self.store.save_conversation(self.current)
            return {"saved": True, "id": self.current["id"]}
        if action == "sticky":
            requested = params.get("value")
            value = not self.store.sticky() if requested is None else bool(requested)
            self.store.sticky(value)
            if value:
                self.current["saved"] = True
                self.store.save_conversation(self.current)
            return {"sticky": value}
        if action == "list":
            return {"conversations": self.store.saved()}
        if action == "resume":
            identifier = params.get("id")
            selected = next((item for item in self.store.saved() if item["id"] == identifier), None)
            if not selected:
                raise RpcFailure("Saved conversation was not found")
            await self._discard_current()
            self.current = dict(selected)
            self.current["saved"] = True
            return {"resumed": identifier}
        if action == "compact":
            request_id = str(params.get("request_id", "compact"))
            client = await self._ensure_client(params)
            result = await self._compact(client, request_id, False)
            self.current["last_activity"] = time.time()
            if self.current.get("saved"):
                self.store.save_conversation(self.current)
            return result
        raise RpcFailure(f"Unknown conversation action: {action}", -32602)

    @staticmethod
    def _walk_models(value: Any, found: dict[str, dict[str, Any]], key: str = "") -> None:
        if isinstance(value, dict):
            model_id = value.get("id") or value.get("model") or value.get("value")
            if model_id and isinstance(model_id, str) and "model" in key.lower():
                efforts = value.get("efforts") or value.get("supportedEfforts") or []
                found[model_id] = {"id": model_id, "label": value.get("name") or value.get("displayName") or model_id, "efforts": efforts}
            for child_key, child in value.items():
                Bridge._walk_models(child, found, str(child_key))
        elif isinstance(value, list):
            for child in value:
                if isinstance(child, str) and "model" in key.lower():
                    found.setdefault(child, {"id": child, "label": child, "efforts": []})
                else:
                    Bridge._walk_models(child, found, key)

    async def models(self, params: dict[str, Any]) -> dict[str, Any]:
        await self._settle_active()
        client = await self._ensure_client(params)
        info = await client.get_server_info() or {}
        found: dict[str, dict[str, Any]] = {}
        self._walk_models(info, found)
        return {"models": list(found.values()), "announced": bool(found), "server_info_keys": sorted(info.keys())}

    async def info(self, params: dict[str, Any]) -> dict[str, Any]:
        usage = None
        if self.client:
            try:
                usage = await self._context_usage(self.client)
            except Exception:
                usage = None
        authentication = "api-key environment" if os.environ.get("ANTHROPIC_API_KEY") else "runtime-managed or unknown"
        return {
            "sdk_version": self.sdk_version,
            "cli_version": await self._read_cli_version(),
            "python_version": sys.version.split()[0],
            "cli_path": self.cli_path,
            "conversation": {key: value for key, value in self.current.items() if key != "client"},
            "sticky": self.store.sticky(),
            "context_usage": usage,
            "authentication": authentication,
            "models_announced": bool(self.server_info),
            "cache": {"ttl_seconds": params.get("cache_ttl_seconds", 3600), "provenance": "configured estimate"},
            "no_tools": {
                "tools": [], "allowed_tools": [], "mcp_servers": {}, "strict_mcp_config": True,
                "setting_sources": [], "skills": [], "agents": {}, "plugins": [],
            },
        }

    async def login_info(self) -> dict[str, Any]:
        return {"command": self.cli_path, "version": await self._read_cli_version()}

    async def close(self) -> None:
        if self.closed:
            return
        self.closed = True
        await self.cancel({})
        await self._disconnect()
        self.store.close()


async def serve(args: argparse.Namespace) -> None:
    rpc = FramedRpc()
    await rpc.connect()
    bridge = Bridge(rpc, Path(args.state_dir), Path(args.resource), args.instance_id)
    tasks: set[asyncio.Task[Any]] = set()

    async def handle(message: dict[str, Any]) -> None:
        request_id = message.get("id")
        method = message.get("method")
        params = message.get("params") or {}
        try:
            if method == "initialize":
                result = {
                    "protocol_version": 1,
                    "sdk_version": bridge.sdk_version,
                    "python_version": sys.version.split()[0],
                    "capabilities": ["streaming", "cancel", "sessions", "compaction", "models"],
                }
            elif method == "conversation/request":
                result = await bridge.request(params)
            elif method == "conversation/command":
                result = await bridge.command(params)
            elif method == "models/list":
                result = await bridge.models(params)
            elif method == "runtime/info":
                result = await bridge.info(params)
            elif method == "runtime/login":
                result = await bridge.login_info()
            else:
                raise RpcFailure(f"Unknown method: {method}", -32601)
            if request_id is not None:
                await rpc.result(request_id, result)
        except Exception as error:
            if request_id is not None:
                await rpc.error(request_id, error)

    try:
        while True:
            message = await rpc.read()
            if message is None:
                break
            method = message.get("method")
            if method == "shutdown":
                break
            if method == "conversation/cancel":
                await bridge.cancel(message.get("params") or {})
                continue
            task = asyncio.create_task(handle(message))
            tasks.add(task)
            task.add_done_callback(tasks.discard)
    finally:
        await bridge.close()
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--resource", required=True)
    parser.add_argument("--instance-id", required=True)
    return parser.parse_args()


if __name__ == "__main__":
    try:
        asyncio.run(serve(parse_args()))
    except KeyboardInterrupt:
        pass
