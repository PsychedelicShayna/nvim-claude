#!/usr/bin/env python3
"""Claude Agent SDK bridge for nvim-claude.

Stdout is reserved for Content-Length framed JSON-RPC messages. Diagnostics go
only to stderr. The bridge owns SDK sessions; Neovim owns every editor object.
"""

from __future__ import annotations

import asyncio
import importlib.metadata
import json
import os
from pathlib import Path
import shutil
import signal
import sys
import time
import traceback
import uuid
from typing import Any

PROTOCOL_VERSION = 1
DEFAULT_MODEL = "claude-haiku-5-5"
DEFAULT_EFFORT = "low"
DEFAULT_LIMIT = 100_000
RUNTIME_OVERHEAD_TOKENS = 8_192
CACHE_TTL_SECONDS = 300


def diagnostic(message: str) -> None:
    sys.stderr.write(f"nvim-claude: {message}\n")
    sys.stderr.flush()


def atomic_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.{uuid.uuid4().hex}.tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(temporary, path)


def read_json(path: Path, fallback: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError):
        return fallback


def process_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def fresh_conversation(*, sticky: bool = False) -> dict[str, Any]:
    now = time.time()
    return {
        "id": uuid.uuid4().hex,
        "session_id": None,
        "created_at": now,
        "last_active": now,
        "first_prompt": "",
        "saved": bool(sticky),
        "model": DEFAULT_MODEL,
        "effort": DEFAULT_EFFORT,
        "context_limit_tokens": DEFAULT_LIMIT,
        "turns": [],
        "cumulative_usage": {},
    }


def public_conversation(value: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": value.get("id"),
        "session_id": value.get("session_id"),
        "created_at": value.get("created_at"),
        "last_active": value.get("last_active"),
        "first_prompt": value.get("first_prompt", ""),
        "saved": bool(value.get("saved")),
        "model": value.get("model", DEFAULT_MODEL),
        "effort": value.get("effort", DEFAULT_EFFORT),
        "context_limit_tokens": value.get("context_limit_tokens", DEFAULT_LIMIT),
    }


class SessionStore:
    """Tracks only sessions created by this plugin."""

    def __init__(self, state_dir: Path) -> None:
        self.root = state_dir
        self.saved_path = self.root / "saved-conversations.json"
        self.instances = self.root / "instances"
        self.owner = uuid.uuid4().hex
        self.owner_path = self.instances / f"{self.owner}.json"
        self.saved: dict[str, dict[str, Any]] = {}
        self.instances.mkdir(parents=True, exist_ok=True)
        self._load_saved()
        self._clean_abandoned()

    def _load_saved(self) -> None:
        loaded = read_json(self.saved_path, {"conversations": {}})
        conversations = loaded.get("conversations", {}) if isinstance(loaded, dict) else {}
        self.saved = conversations if isinstance(conversations, dict) else {}

    def _save_saved(self) -> None:
        disk = read_json(self.saved_path, {"conversations": {}})
        conversations = disk.get("conversations", {}) if isinstance(disk, dict) else {}
        if not isinstance(conversations, dict):
            conversations = {}
        conversations.update(self.saved)
        atomic_json(self.saved_path, {"version": 1, "conversations": conversations})
        self.saved = conversations

    def _clean_abandoned(self) -> None:
        for path in self.instances.glob("*.json"):
            record = read_json(path, {})
            pid = int(record.get("pid", -1)) if isinstance(record, dict) else -1
            if process_alive(pid):
                continue
            session_id = record.get("session_id") if isinstance(record, dict) else None
            if session_id and not record.get("saved"):
                self.delete_owned_transcript(str(session_id))
            try:
                path.unlink()
            except OSError:
                pass

    def checkpoint(self, conversation: dict[str, Any]) -> None:
        if conversation.get("saved"):
            self.saved[str(conversation["id"])] = conversation
            self._save_saved()
        atomic_json(
            self.owner_path,
            {
                "pid": os.getpid(),
                "owner": self.owner,
                "conversation_id": conversation.get("id"),
                "session_id": conversation.get("session_id"),
                "saved": bool(conversation.get("saved")),
                "updated_at": time.time(),
            },
        )

    def mark_saved(self, conversation: dict[str, Any]) -> None:
        conversation["saved"] = True
        self.saved[str(conversation["id"])] = conversation
        self._save_saved()
        self.checkpoint(conversation)

    def list_saved(self) -> list[dict[str, Any]]:
        self._load_saved()
        return sorted(self.saved.values(), key=lambda item: item.get("last_active", 0), reverse=True)

    def get_saved(self, conversation_id: str) -> dict[str, Any] | None:
        self._load_saved()
        value = self.saved.get(conversation_id)
        if not isinstance(value, dict):
            return None
        return json.loads(json.dumps(value))

    def delete_owned_transcript(self, session_id: str) -> None:
        if not session_id or "/" in session_id or "\\" in session_id:
            return
        claude_root = Path.home() / ".claude" / "projects"
        if not claude_root.is_dir():
            return
        for path in claude_root.glob(f"**/{session_id}.jsonl"):
            try:
                path.unlink()
            except OSError as error:
                diagnostic(f"could not remove owned ephemeral transcript {path}: {error}")

    def discard_ephemeral(self, conversation: dict[str, Any]) -> None:
        if conversation.get("saved"):
            return
        session_id = conversation.get("session_id")
        if session_id:
            self.delete_owned_transcript(str(session_id))

    def close(self, conversation: dict[str, Any]) -> None:
        if conversation.get("saved"):
            self.mark_saved(conversation)
        else:
            self.discard_ephemeral(conversation)
        try:
            self.owner_path.unlink()
        except OSError:
            pass


class FramedRPC:
    def __init__(self) -> None:
        self.write_lock = asyncio.Lock()

    async def send(self, message: dict[str, Any]) -> None:
        encoded = json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        frame = f"Content-Length: {len(encoded)}\r\n\r\n".encode("ascii") + encoded
        async with self.write_lock:
            sys.stdout.buffer.write(frame)
            sys.stdout.buffer.flush()

    async def result(self, request_id: Any, value: Any) -> None:
        await self.send({"jsonrpc": "2.0", "id": request_id, "result": value})

    async def error(self, request_id: Any, code: int, message: str, data: Any = None) -> None:
        error: dict[str, Any] = {"code": code, "message": message}
        if data is not None:
            error["data"] = data
        await self.send({"jsonrpc": "2.0", "id": request_id, "error": error})

    async def event(self, **params: Any) -> None:
        await self.send({"jsonrpc": "2.0", "method": "nvim_claude/event", "params": params})


class Bridge:
    def __init__(self, rpc: FramedRPC, plugin_root: Path) -> None:
        self.rpc = rpc
        self.plugin_root = plugin_root
        self.state_dir = Path(os.environ.get("NVIM_CLAUDE_STATE_DIR", Path.home() / ".local/state/nvim-claude"))
        self.runtime_dir = self.state_dir / "runtime"
        self.runtime_dir.mkdir(parents=True, exist_ok=True)
        self.store = SessionStore(self.state_dir)
        self.sticky = False
        self.active = fresh_conversation()
        self.store.checkpoint(self.active)
        self.client: Any = None
        self.client_signature: tuple[Any, ...] | None = None
        self.server_info: dict[str, Any] = {}
        self.context_usage: dict[str, Any] | None = None
        self.turn_task: asyncio.Task[None] | None = None
        self.turn_key: tuple[str, int] | None = None
        self.cancelled: set[tuple[str, int]] = set()
        self.shutting_down = False
        self.system_prompt_path = plugin_root / "resources" / "system_prompt.txt"
        self.system_prompt = self.system_prompt_path.read_text(encoding="utf-8")
        self.sdk_version = self._package_version()
        self.cli_path = self._bundled_cli_path()
        self.cli_version = self._bundled_cli_version()

    @staticmethod
    def _package_version() -> str | None:
        try:
            return importlib.metadata.version("claude-agent-sdk")
        except importlib.metadata.PackageNotFoundError:
            return None

    @staticmethod
    def _bundled_cli_version() -> str | None:
        try:
            from claude_agent_sdk._cli_version import __cli_version__

            return str(__cli_version__)
        except Exception:
            return None

    @staticmethod
    def _bundled_cli_path() -> str | None:
        try:
            import claude_agent_sdk

            name = "claude.exe" if os.name == "nt" else "claude"
            path = Path(claude_agent_sdk.__file__).parent / "_bundled" / name
            return str(path) if path.is_file() else shutil.which("claude")
        except Exception:
            return shutil.which("claude")

    async def dispatch(self, request: dict[str, Any]) -> None:
        request_id = request.get("id")
        method = request.get("method")
        params = request.get("params") or {}
        if not isinstance(method, str) or not isinstance(params, dict):
            if request_id is not None:
                await self.rpc.error(request_id, -32600, "Invalid JSON-RPC request")
            return
        handler_name = "rpc_" + method.replace("/", "_").replace("-", "_")
        handler = getattr(self, handler_name, None)
        if handler is None:
            if request_id is not None:
                await self.rpc.error(request_id, -32601, f"Unknown method: {method}")
            return
        try:
            value = await handler(params)
            if request_id is not None:
                await self.rpc.result(request_id, value)
        except ValueError as error:
            if request_id is not None:
                await self.rpc.error(request_id, -32602, str(error))
        except Exception as error:
            diagnostic(f"{method} failed: {error}\n{traceback.format_exc()}")
            if request_id is not None:
                await self.rpc.error(request_id, -32000, str(error))

    async def rpc_initialize(self, params: dict[str, Any]) -> dict[str, Any]:
        state_dir = params.get("state_dir")
        if state_dir and Path(str(state_dir)) != self.state_dir:
            self.store.close(self.active)
            self.state_dir = Path(str(state_dir)).expanduser()
            self.runtime_dir = self.state_dir / "runtime"
            self.runtime_dir.mkdir(parents=True, exist_ok=True)
            self.store = SessionStore(self.state_dir)
            self.store.checkpoint(self.active)
        return {
            "protocol_version": PROTOCOL_VERSION,
            "python_version": sys.version.split()[0],
            "sdk_version": self.sdk_version,
            "cli_version": self.cli_version,
            "cli_path": self.cli_path,
            "runtime": {
                "python": sys.version.split()[0],
                "sdk": self.sdk_version,
                "cli": self.cli_version,
                "cli_path": self.cli_path,
            },
            "capabilities": {
                "streaming": True,
                "cancel": True,
                "sessions": True,
                "manual_compaction": True,
                "conservative_budget_guard": True,
                "runtime_models": True,
                "prompt_replacement": True,
                "configured_no_tools": True,
            },
            "conversation": public_conversation(self.active),
            "cache": {
                "ttl_seconds": int(os.environ.get("NVIM_CLAUDE_CACHE_TTL", CACHE_TTL_SECONDS)),
                "provenance": "conservative estimate; authentication mode is unknown",
            },
        }

    async def rpc_turn(self, params: dict[str, Any]) -> dict[str, Any]:
        if self.turn_task and not self.turn_task.done():
            raise ValueError("The active conversation is busy; the draft was not submitted.")
        request_id = str(params.get("request_id") or uuid.uuid4().hex)
        epoch = int(params.get("epoch", 0))
        operation = str(params.get("operation", ""))
        if operation not in {"ask", "replace", "generate"}:
            raise ValueError("turn.operation must be ask, replace, or generate")
        if not isinstance(params.get("envelope"), dict):
            raise ValueError("turn.envelope must be an object")
        key = (request_id, epoch)
        self.turn_key = key
        self.cancelled.discard(key)
        self.turn_task = asyncio.create_task(self._run_turn(key, operation, params))
        return {"accepted": True, "request_id": request_id, "epoch": epoch}

    async def rpc_cancel(self, params: dict[str, Any]) -> dict[str, Any]:
        request_id = str(params.get("request_id") or (self.turn_key or ("", 0))[0])
        epoch = int(params.get("epoch", (self.turn_key or ("", 0))[1]))
        key = (request_id, epoch)
        self.cancelled.add(key)
        if self.turn_key == key and self.client is not None:
            try:
                await self.client.interrupt()
            except Exception as error:
                diagnostic(f"interrupt failed: {error}")
        if self.turn_key == key and self.turn_task and not self.turn_task.done():
            self.turn_task.cancel()
        return {"cancelled": self.turn_key == key}

    async def rpc_models(self, params: dict[str, Any]) -> dict[str, Any]:
        configured_limit = params.get(
            "context_limit_tokens", self.active.get("context_limit_tokens", DEFAULT_LIMIT)
        )
        await self._ensure_client(
            str(params.get("model") or self.active.get("model") or DEFAULT_MODEL),
            params.get("effort", self.active.get("effort")),
            None if configured_limit is False else int(configured_limit),
            str(params.get("system_prompt") or self.system_prompt),
        )
        models = self._extract_models(self.server_info)
        return {
            "models": models,
            "source": "runtime initialization metadata" if models else "unavailable",
            "server_info": self._safe_server_info(),
        }

    async def rpc_session_new(self, params: dict[str, Any]) -> dict[str, Any]:
        await self._require_idle()
        await self._replace_conversation(preserve_saved=True)
        return {"conversation": public_conversation(self.active)}

    async def rpc_session_clear(self, params: dict[str, Any]) -> dict[str, Any]:
        await self._require_idle()
        await self._replace_conversation(preserve_saved=True)
        return {"conversation": public_conversation(self.active), "baselines_invalidated": True}

    async def rpc_session_save(self, params: dict[str, Any]) -> dict[str, Any]:
        self.store.mark_saved(self.active)
        return {"conversation": public_conversation(self.active)}

    async def rpc_session_sticky(self, params: dict[str, Any]) -> dict[str, Any]:
        requested = params.get("enabled")
        self.sticky = not self.sticky if requested is None else bool(requested)
        if self.sticky:
            self.store.mark_saved(self.active)
        return {"sticky": self.sticky, "conversation": public_conversation(self.active)}

    async def rpc_session_list(self, params: dict[str, Any]) -> dict[str, Any]:
        return {"conversations": [public_conversation(item) for item in self.store.list_saved()]}

    async def rpc_session_resume(self, params: dict[str, Any]) -> dict[str, Any]:
        await self._require_idle()
        conversation_id = str(params.get("id") or "")
        conversation = self.store.get_saved(conversation_id)
        if conversation is None:
            raise ValueError("Saved conversation not found")
        await self._disconnect()
        if not self.active.get("saved"):
            self.store.discard_ephemeral(self.active)
        self.active = conversation
        self.store.checkpoint(self.active)
        return {"conversation": public_conversation(self.active), "baselines_invalidated": True}

    async def rpc_session_compact(self, params: dict[str, Any]) -> dict[str, Any]:
        await self._require_idle()
        if self.client is None:
            raise ValueError("There is no active SDK session to compact")
        usage = await self._compact(None)
        return {"compacted": True, "context_usage": usage, "baselines_invalidated": True}

    async def rpc_session_info(self, params: dict[str, Any]) -> dict[str, Any]:
        if self.client is not None and not (self.turn_task and not self.turn_task.done()):
            self.context_usage = await self._get_context_usage()
        return {
            "conversation": public_conversation(self.active),
            "sticky": self.sticky,
            "busy": bool(self.turn_task and not self.turn_task.done()),
            "context_usage": self.context_usage,
            "cumulative_usage": self.active.get("cumulative_usage", {}),
            "runtime": {
                "python": sys.version.split()[0],
                "sdk": self.sdk_version,
                "cli": self.cli_version,
                "resolved_model": self.context_usage.get("model") if self.context_usage else None,
            },
            "budget": {
                "configured_tokens": self.active.get("context_limit_tokens"),
                "enforcement": "conservative UTF-8 byte upper bound plus runtime occupancy and fixed overhead",
                "runtime_overhead_tokens": RUNTIME_OVERHEAD_TOKENS,
                "verified_native_hard_ceiling": False,
            },
            "cache": {
                "ttl_seconds": int(os.environ.get("NVIM_CLAUDE_CACHE_TTL", CACHE_TTL_SECONDS)),
                "expires_at": self.active.get("last_active", 0)
                + int(os.environ.get("NVIM_CLAUDE_CACHE_TTL", CACHE_TTL_SECONDS)),
                "provenance": "estimated; authentication and billing mode are not reported by the SDK",
            },
            "no_tools": self._no_tools_report(),
            "server_info": self._safe_server_info(),
        }

    async def rpc_system_set(self, params: dict[str, Any]) -> dict[str, Any]:
        await self._require_idle()
        prompt = params.get("prompt")
        if not isinstance(prompt, str) or not prompt.strip():
            raise ValueError("system/set requires a non-empty prompt")
        changed = prompt != self.system_prompt
        self.system_prompt = prompt
        if changed:
            await self._disconnect()
        return {"changed": changed, "applies_to": "next request", "history_preserved": True}

    async def rpc_login(self, params: dict[str, Any]) -> dict[str, Any]:
        if not self.cli_path:
            raise ValueError("The SDK bundled Claude CLI is unavailable")
        return {
            "argv": [self.cli_path, "login"],
            "interactive": True,
            "message": "Run the bundled Claude CLI login flow in an interactive terminal.",
        }

    async def rpc_shutdown(self, params: dict[str, Any]) -> dict[str, Any]:
        await self.shutdown()
        return {"stopped": True}

    async def _run_turn(
        self, key: tuple[str, int], operation: str, params: dict[str, Any]
    ) -> None:
        request_id, epoch = key
        try:
            await self.rpc.event(request_id=request_id, epoch=epoch, type="status", status="budgeting")
            await self._expire_if_needed()
            model = str(params.get("model") or self.active.get("model") or DEFAULT_MODEL)
            effort_value = params.get("effort", self.active.get("effort", DEFAULT_EFFORT))
            effort = str(effort_value) if effort_value is not None else None
            configured_limit = params.get(
                "context_limit_tokens", self.active.get("context_limit_tokens", DEFAULT_LIMIT)
            )
            limit = None if configured_limit is False else int(configured_limit)
            prompt_override = params.get("system_prompt")
            system_prompt = str(prompt_override) if isinstance(prompt_override, str) and prompt_override else self.system_prompt
            prompt = json.dumps(params["envelope"], ensure_ascii=False, separators=(",", ":"))
            mandatory = self._prompt_upper_bound(prompt, system_prompt)
            if limit is not None and mandatory > limit:
                raise ValueError(
                    f"The mandatory prompt needs at most {mandatory} conservatively counted tokens, "
                    f"which cannot fit the configured {limit}-token budget. Nothing was sent."
                )
            await self._ensure_client(model, effort, limit, system_prompt)
            usage = await self._get_context_usage()
            occupied = int((usage or {}).get("totalTokens", 0))
            next_upper = occupied + len(prompt.encode("utf-8")) + RUNTIME_OVERHEAD_TOKENS
            if limit is not None and occupied and next_upper > limit:
                await self.rpc.event(
                    request_id=request_id,
                    epoch=epoch,
                    type="status",
                    status="compacting",
                    estimated_tokens=next_upper,
                    limit=limit,
                )
                usage = await self._compact(key)
                occupied = int((usage or {}).get("totalTokens", 0))
                next_upper = occupied + len(prompt.encode("utf-8")) + RUNTIME_OVERHEAD_TOKENS
                if next_upper > limit:
                    raise ValueError(
                        f"The next request remains above the {limit}-token budget after compaction. Nothing was sent."
                    )
            if key in self.cancelled:
                raise asyncio.CancelledError
            await self.rpc.event(request_id=request_id, epoch=epoch, type="status", status="running")
            await self.client.query(prompt, session_id=str(self.active["id"]))
            streamed: list[str] = []
            final_blocks: list[str] = []
            result_message: Any = None
            from claude_agent_sdk import AssistantMessage, ResultMessage, StreamEvent, TextBlock

            async for message in self.client.receive_response():
                if key in self.cancelled:
                    raise asyncio.CancelledError
                if isinstance(message, StreamEvent):
                    text = self._stream_delta(message.event)
                    if text:
                        streamed.append(text)
                        await self.rpc.event(
                            request_id=request_id, epoch=epoch, type="delta", text=text
                        )
                elif isinstance(message, AssistantMessage):
                    final_blocks = [block.text for block in message.content if isinstance(block, TextBlock)]
                elif isinstance(message, ResultMessage):
                    result_message = message
            if key in self.cancelled:
                raise asyncio.CancelledError
            if result_message is None:
                raise RuntimeError("The SDK stream ended without a result message")
            if bool(getattr(result_message, "is_error", False)):
                errors = getattr(result_message, "errors", None)
                detail = "; ".join(errors) if errors else getattr(result_message, "subtype", "SDK request failed")
                raise RuntimeError(str(detail))
            final_text = "".join(final_blocks)
            partial_text = "".join(streamed)
            raw = final_text or partial_text or str(getattr(result_message, "result", "") or "")
            if final_text and not partial_text:
                await self.rpc.event(request_id=request_id, epoch=epoch, type="delta", text=final_text)
            self.active["session_id"] = getattr(result_message, "session_id", None) or self.active.get("session_id")
            self.active["model"] = model
            self.active["effort"] = effort
            self.active["context_limit_tokens"] = limit if limit is not None else False
            self.active["last_active"] = time.time()
            instruction = params["envelope"].get("instruction", "")
            if not self.active.get("first_prompt") and isinstance(instruction, str):
                self.active["first_prompt"] = instruction[:200]
            self.active.setdefault("turns", []).append(
                {"operation": operation, "request": params["envelope"], "raw_assistant": raw, "at": time.time()}
            )
            usage_value = getattr(result_message, "usage", None) or {}
            self._accumulate_usage(usage_value)
            self.context_usage = await self._get_context_usage()
            if self.sticky:
                self.active["saved"] = True
            self.store.checkpoint(self.active)
            await self.rpc.event(
                request_id=request_id,
                epoch=epoch,
                type="result",
                raw=raw,
                session_id=self.active.get("session_id"),
                usage=usage_value,
                context_usage=self.context_usage,
                resolved_model=(self.context_usage or {}).get("model"),
            )
        except asyncio.CancelledError:
            await self.rpc.event(
                request_id=request_id,
                epoch=epoch,
                type="error",
                code="cancelled",
                message="Request cancelled; no edit was applied.",
            )
        except Exception as error:
            diagnostic(f"turn failed: {error}")
            await self.rpc.event(
                request_id=request_id,
                epoch=epoch,
                type="error",
                code="request_failed",
                message=str(error),
            )
        finally:
            if self.turn_key == key:
                self.turn_key = None
            self.cancelled.discard(key)

    def _prompt_upper_bound(self, prompt: str, system_prompt: str) -> int:
        return len(prompt.encode("utf-8")) + len(system_prompt.encode("utf-8")) + RUNTIME_OVERHEAD_TOKENS

    async def _expire_if_needed(self) -> None:
        ttl = int(os.environ.get("NVIM_CLAUDE_CACHE_TTL", CACHE_TTL_SECONDS))
        if self.active.get("saved") or not self.active.get("session_id"):
            return
        if time.time() - float(self.active.get("last_active", 0)) <= ttl:
            return
        await self._replace_conversation(preserve_saved=False)

    async def _replace_conversation(self, *, preserve_saved: bool) -> None:
        await self._disconnect()
        previous = self.active
        if not previous.get("saved"):
            self.store.discard_ephemeral(previous)
        elif preserve_saved:
            self.store.mark_saved(previous)
        self.active = fresh_conversation(sticky=self.sticky)
        self.store.checkpoint(self.active)
        self.context_usage = None

    async def _ensure_client(
        self, model: str, effort: str | None, limit: int | None, system_prompt: str
    ) -> None:
        if self.sdk_version is None:
            raise RuntimeError(
                "claude-agent-sdk is not installed in the plugin environment. Run :NvClaude update or retry provisioning."
            )
        signature = (model, effort, limit, system_prompt, self.active.get("session_id"))
        if self.client is not None and self.client_signature == signature:
            return
        await self._disconnect()
        from claude_agent_sdk import ClaudeAgentOptions, ClaudeSDKClient

        env = dict(os.environ)
        if limit is not None and limit >= 100_000:
            env["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] = str(limit)
        options = ClaudeAgentOptions(
            tools=[],
            allowed_tools=[],
            disallowed_tools=[],
            mcp_servers={},
            strict_mcp_config=True,
            setting_sources=[],
            skills=[],
            plugins=[],
            agents={},
            system_prompt=system_prompt,
            model=model,
            effort=effort,
            include_partial_messages=True,
            cwd=self.runtime_dir,
            env=env,
            resume=self.active.get("session_id"),
            session_id=None if self.active.get("session_id") else str(self.active["id"]),
            fork_session=False,
            max_turns=1,
            stderr=diagnostic,
        )
        self.client = ClaudeSDKClient(options=options)
        try:
            await self.client.connect()
            self.server_info = await self.client.get_server_info() or {}
        except Exception:
            await self._disconnect()
            raise
        self.client_signature = signature

    async def _disconnect(self) -> None:
        client, self.client = self.client, None
        self.client_signature = None
        if client is not None:
            try:
                await client.disconnect()
            except Exception as error:
                diagnostic(f"disconnect failed: {error}")

    async def _get_context_usage(self) -> dict[str, Any] | None:
        if self.client is None:
            return None
        try:
            value = await self.client.get_context_usage()
            return dict(value)
        except Exception as error:
            diagnostic(f"context usage unavailable: {error}")
            return None

    async def _compact(self, key: tuple[str, int] | None) -> dict[str, Any] | None:
        if self.client is None:
            raise RuntimeError("There is no active SDK session to compact")
        await self.client.query("/compact", session_id=str(self.active["id"]))
        from claude_agent_sdk import ResultMessage

        result = None
        async for message in self.client.receive_response():
            if isinstance(message, ResultMessage):
                result = message
        if result is None or bool(getattr(result, "is_error", False)):
            raise RuntimeError("Claude Code did not complete compaction")
        usage = await self._get_context_usage()
        self.context_usage = usage
        if key is not None:
            await self.rpc.event(
                request_id=key[0], epoch=key[1], type="compacted", context_usage=usage
            )
        return usage

    async def _require_idle(self) -> None:
        if self.turn_task and not self.turn_task.done():
            raise ValueError("Finish or cancel the active request before changing conversations.")

    @staticmethod
    def _stream_delta(event: Any) -> str:
        if not isinstance(event, dict) or event.get("type") != "content_block_delta":
            return ""
        delta = event.get("delta")
        if not isinstance(delta, dict) or delta.get("type") != "text_delta":
            return ""
        text = delta.get("text")
        return text if isinstance(text, str) else ""

    @staticmethod
    def _extract_models(value: Any) -> list[dict[str, Any]]:
        found: list[dict[str, Any]] = []
        seen: set[str] = set()

        def visit(node: Any, key: str = "") -> None:
            if isinstance(node, dict):
                if key.lower() in {"models", "available_models", "availablemodels"}:
                    visit_model_list(node)
                for child_key, child in node.items():
                    visit(child, str(child_key))
            elif isinstance(node, list):
                if key.lower() in {"models", "available_models", "availablemodels"}:
                    visit_model_list(node)
                else:
                    for child in node:
                        visit(child, key)

        def visit_model_list(node: Any) -> None:
            values = node.values() if isinstance(node, dict) else node if isinstance(node, list) else []
            for item in values:
                if isinstance(item, str):
                    model_id, metadata = item, {"id": item}
                elif isinstance(item, dict):
                    model_id = item.get("id") or item.get("value") or item.get("model") or item.get("name")
                    metadata = dict(item)
                    if model_id:
                        metadata.setdefault("id", model_id)
                else:
                    continue
                if isinstance(model_id, str) and model_id and model_id not in seen:
                    seen.add(model_id)
                    found.append(metadata)

        visit(value)
        return found

    def _safe_server_info(self) -> dict[str, Any]:
        allowed = {
            "models",
            "available_models",
            "availableModels",
            "capabilities",
            "commands",
            "output_style",
            "outputStyle",
            "version",
        }
        return {key: value for key, value in self.server_info.items() if key in allowed}

    def _no_tools_report(self) -> dict[str, Any]:
        usage = self.context_usage or {}
        unexpected = []
        for key in ("mcpTools", "agents"):
            entries = usage.get(key, [])
            if entries:
                unexpected.append({"category": key, "entries": entries})
        return {
            "configured": True,
            "tools": [],
            "strict_mcp_config": True,
            "setting_sources": [],
            "skills": [],
            "plugins": [],
            "agents": [],
            "unexpected_runtime_capabilities": unexpected,
        }

    def _accumulate_usage(self, usage: dict[str, Any]) -> None:
        totals = self.active.setdefault("cumulative_usage", {})
        for key, value in usage.items():
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                totals[key] = totals.get(key, 0) + value

    async def shutdown(self) -> None:
        if self.shutting_down:
            return
        self.shutting_down = True
        if self.turn_task and not self.turn_task.done():
            if self.turn_key:
                self.cancelled.add(self.turn_key)
            if self.client is not None:
                try:
                    await self.client.interrupt()
                except Exception:
                    pass
            self.turn_task.cancel()
            try:
                await self.turn_task
            except (asyncio.CancelledError, Exception):
                pass
        await self._disconnect()
        self.store.close(self.active)


async def read_requests(bridge: Bridge) -> None:
    loop = asyncio.get_running_loop()
    reader = asyncio.StreamReader()
    protocol = asyncio.StreamReaderProtocol(reader)
    await loop.connect_read_pipe(lambda: protocol, sys.stdin.buffer)
    tasks: set[asyncio.Task[None]] = set()
    try:
        while not bridge.shutting_down:
            headers: dict[str, str] = {}
            while True:
                line = await reader.readline()
                if not line:
                    return
                if line in {b"\r\n", b"\n"}:
                    break
                try:
                    name, value = line.decode("ascii").split(":", 1)
                except ValueError:
                    raise RuntimeError("Malformed JSON-RPC header")
                headers[name.strip().lower()] = value.strip()
            length = int(headers.get("content-length", "0"))
            if length <= 0 or length > 64 * 1024 * 1024:
                raise RuntimeError("Invalid Content-Length")
            payload = await reader.readexactly(length)
            request = json.loads(payload.decode("utf-8"))
            if not isinstance(request, dict):
                continue
            task = asyncio.create_task(bridge.dispatch(request))
            tasks.add(task)
            task.add_done_callback(tasks.discard)
    finally:
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)


async def async_main() -> int:
    plugin_root = Path(__file__).resolve().parent.parent
    rpc = FramedRPC()
    bridge = Bridge(rpc, plugin_root)
    loop = asyncio.get_running_loop()
    for name in ("SIGTERM", "SIGINT"):
        sig = getattr(signal, name, None)
        if sig is not None:
            try:
                loop.add_signal_handler(sig, lambda: asyncio.create_task(bridge.shutdown()))
            except (NotImplementedError, RuntimeError):
                pass
    try:
        await read_requests(bridge)
    except (asyncio.IncompleteReadError, BrokenPipeError):
        pass
    except Exception as error:
        diagnostic(f"protocol failure: {error}\n{traceback.format_exc()}")
        return 1
    finally:
        await bridge.shutdown()
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(async_main()))
