"""Stdio JSON-RPC bridge for nvim-claude. Stdout is reserved for protocol frames."""

from __future__ import annotations

import asyncio
import fcntl
import importlib.metadata
import json
import os
import sys
import time
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Any

from claude_agent_sdk import (
    AssistantMessage,
    ClaudeAgentOptions,
    ClaudeSDKClient,
    ServerToolUseBlock,
    ResultMessage,
    StreamEvent,
    SystemMessage,
    TextBlock,
    ToolUseBlock,
    delete_session,
)


PROMPT_PATH = Path(__file__).resolve().parents[2] / "resources" / "system.txt"
MAX_FRAME = 32 * 1024 * 1024
# Reserved for unreported runtime input, serialization, and response admission.
RUNTIME_RESERVE = 16_384
TURN_RESERVE = 2_048
COMPACT_RESERVE = 8_192
EFFORTS = {"low", "medium", "high", "xhigh", "max"}


class RPCError(Exception):
    def __init__(self, message: str, code: int = -32000, data: Any = None):
        super().__init__(message)
        self.code = code
        self.data = data


def _bytes_upper(text: str) -> int:
    # A UTF-8 byte per token is conservative for ordinary model text; the
    # separate reserves cover framing and runtime-supplied input.
    return len(text.encode("utf-8"))


def _pid_birth(pid: int) -> str | None:
    try:
        # Field 22 is starttime; comm can include spaces and parentheses.
        return Path(f"/proc/{pid}/stat").read_text().rsplit(") ", 1)[1].split()[19]
    except (OSError, IndexError):
        try:
            os.kill(pid, 0)
            return "present"
        except (OSError, ValueError):
            return None


def _alive(owner: dict[str, Any]) -> bool:
    try:
        pid = int(owner["pid"])
    except (KeyError, ValueError, TypeError):
        return False
    return _pid_birth(pid) == owner.get("birth")


class Manifest:
    def __init__(self, state: Path):
        self.state = state
        self.state.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.path = state / "manifest.json"
        self.lock_path = state / "manifest.lock"
        self.cwd = state / "runtime"
        self.cwd.mkdir(mode=0o700, exist_ok=True)
        self.owner = {"pid": os.getpid(), "birth": _pid_birth(os.getpid())}

    @contextmanager
    def locked(self):
        with self.lock_path.open("a+b") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            try:
                if self.path.exists():
                    data = json.loads(self.path.read_text(encoding="utf-8"))
                    if not isinstance(data, dict) or not isinstance(data.get("conversations"), dict):
                        raise RPCError("Invalid conversation manifest; refusing to discard saved sessions")
                else:
                    data = {"conversations": {}}
                yield data["conversations"]
                temp = self.state / f".manifest-{uuid.uuid4().hex}"
                try:
                    with temp.open("x", encoding="utf-8") as file:
                        os.chmod(temp, 0o600)
                        json.dump(data, file, ensure_ascii=False, separators=(",", ":"))
                        file.flush()
                        os.fsync(file.fileno())
                    os.replace(temp, self.path)
                finally:
                    temp.unlink(missing_ok=True)
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    def drop(self, record: dict[str, Any]) -> None:
        ids = record.get("owned_session_ids") or [record.get("session_id")]
        for sid in ids:
            try:
                uuid.UUID(sid)
                # Restrict deletion to this plugin's designated SDK project.
                delete_session(sid, directory=str(self.cwd))
            except FileNotFoundError:
                pass
            except (ValueError, TypeError):
                continue

    def sweep(self) -> None:
        with self.locked() as records:
            for rid, record in list(records.items()):
                if not record.get("saved") and not _alive(record.get("owner") or {}):
                    self.drop(record)
                    del records[rid]

    def save(self, record: dict[str, Any]) -> None:
        with self.locked() as records:
            records[record["id"]] = record.copy()

    def claim(self, rid: str) -> dict[str, Any]:
        with self.locked() as records:
            record = records.get(rid)
            if not record or not record.get("saved"):
                raise RPCError("Saved conversation not found")
            if record.get("owner") != self.owner and _alive(record.get("owner") or {}):
                raise RPCError("Saved conversation is active in another Neovim instance")
            record["owner"] = self.owner
            records[rid] = record
            return record.copy()

    def list(self) -> list[dict[str, Any]]:
        with self.locked() as records:
            return [r.copy() for r in records.values() if r.get("saved")]

    def remove(self, record: dict[str, Any]) -> None:
        with self.locked() as records:
            current = records.get(record["id"])
            if current and not current.get("saved"):
                self.drop(current)
                del records[record["id"]]


class Bridge:
    def __init__(self):
        self.manifest: Manifest | None = None
        self.client: ClaudeSDKClient | None = None
        self.client_configuration: tuple[Any, ...] | None = None
        self.active: dict[str, Any] | None = None
        self.sticky = False
        self.epoch = 0
        self.pending: asyncio.Task | None = None
        self.pending_id: Any = None
        self.pending_epoch: Any = None
        self.cancelled = False
        self.models: list[dict[str, Any]] = []
        self.capabilities: dict[str, Any] = {"models_source": "unavailable", "no_tools": "configured; awaiting runtime init"}
        self.default_prompt = PROMPT_PATH.read_text(encoding="utf-8")
        self.prompt = self.default_prompt
        self.cli_path = str(Path(__import__("claude_agent_sdk").__file__).parent / "_bundled" / "claude")
        try:
            from claude_agent_sdk._cli_version import __cli_version__
            self.cli_version = __cli_version__
        except ImportError:
            self.cli_version = "unknown"
        self.sdk_version = importlib.metadata.version("claude-agent-sdk")
        self.allow_api_key = False
        self.auth_method = "unknown"

    @property
    def storage(self) -> Manifest:
        if not self.manifest:
            raise RPCError("Initialize the bridge first")
        return self.manifest

    def _new(self, profile: dict[str, Any] | None = None) -> dict[str, Any]:
        now = time.time()
        session_id = str(uuid.uuid4())
        profile = profile or {}
        return {
            "id": str(uuid.uuid4()), "session_id": session_id, "owned_session_ids": [session_id],
            "created_at": now, "updated_at": now, "title": "",
            "saved": self.sticky, "owner": self.storage.owner,
            "model": profile.get("model", "claude-haiku-5-5"),
            "effort": profile.get("effort", "low"),
            "context_limit_tokens": profile.get("context_limit_tokens", 100_000),
            "runtime_context_limit": None,
            "occupancy": None, "usage": {"input_tokens": 0, "output_tokens": 0,
                                           "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0},
            "history_bytes": 0, "turn_count": 0, "baselines": {},
            "last_request_at": None, "cache_ttl_seconds": None,
        }

    def _ensure_active(self) -> dict[str, Any]:
        if not self.active:
            self.active = self._new()
            self.storage.save(self.active)
            self.epoch += 1
        return self.active

    async def _expire(self, allow_pending: bool = False) -> None:
        if self.pending and not allow_pending:
            return
        old = self.active
        if old and not old["saved"] and old["last_request_at"] is not None:
            ttl = old.get("cache_ttl_seconds") or 300
            if time.time() - old["last_request_at"] > ttl:
                await self._disconnect()
                self.storage.remove(old)
                self.active = None
                self.epoch += 1

    def _persist(self) -> None:
        if self.active:
            self.active["updated_at"] = time.time()
            self.storage.save(self.active)

    async def _disconnect(self) -> None:
        client, self.client = self.client, None
        self.client_configuration = None
        if client:
            await client.disconnect()

    def _options(self, record: dict[str, Any], prompt: str) -> ClaudeAgentOptions:
        resumed = record["turn_count"] > 0
        args = {"resume": record["session_id"]} if resumed else {"session_id": record["session_id"]}
        env = {"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
               "CLAUDE_CODE_AUTO_CONNECT_IDE": "false"}
        if record.get("context_limit_tokens") is not None:
            # Claude Code applies this window to a recognized model only when
            # compaction is disabled. It then returns a context-limit error.
            env["CLAUDE_CODE_MAX_CONTEXT_TOKENS"] = str(record["context_limit_tokens"])
            env["DISABLE_COMPACT"] = "1"
        return ClaudeAgentOptions(
            **args, tools=[], allowed_tools=[], mcp_servers={},
            strict_mcp_config=True, setting_sources=[], skills=[], plugins=[], agents=None,
            # Safe mode suppresses global-config plugins and bundled skills
            # while retaining the user's normal Claude Code authentication.
            extra_args={"safe-mode": None},
            permission_mode="dontAsk", max_turns=1, include_partial_messages=True,
            system_prompt={"type": "custom", "prompt": prompt, "snapshot": False},
            model=record["model"], effort=record.get("effort"),
            fallback_model=None, cwd=str(self.storage.cwd), env=env,
        )

    async def _connect(self, record: dict[str, Any], prompt: str) -> ClaudeSDKClient:
        config = (record["id"], record["model"], record.get("effort"), record.get("context_limit_tokens"), prompt)
        if self.client and self.client_configuration == config:
            return self.client
        await self._disconnect()
        # Ignore inherited window/compaction controls; the bridge sets the
        # per-conversation policy explicitly in ClaudeAgentOptions.env.
        os.environ.pop("CLAUDE_CODE_MAX_CONTEXT_TOKENS", None)
        os.environ.pop("DISABLE_COMPACT", None)
        record["runtime_context_limit"] = None
        if not self.allow_api_key:
            # CLI transport merges options.env over this process's environment.
            # Never silently spend API-key credits in a subscription workflow.
            for name in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"):
                os.environ.pop(name, None)
        client = ClaudeSDKClient(options=self._options(record, prompt))
        try:
            await client.connect()
            info = await client.get_server_info() or {}
            self._inspect_info(info)
        except BaseException:
            await client.disconnect()
            raise
        self.client = client
        self.client_configuration = config
        return client

    def _inspect_info(self, info: dict[str, Any]) -> None:
        models = info.get("models") or info.get("available_models")
        if isinstance(models, list):
            catalogue = []
            for model in models:
                if isinstance(model, str):
                    catalogue.append({"id": model})
                elif isinstance(model, dict):
                    mid = model.get("id") or model.get("value") or model.get("model")
                    if isinstance(mid, str):
                        entry = {"id": mid}
                        for key in ("display_name", "description", "context_window", "efforts"):
                            val = model.get(key)
                            if val is not None:
                                entry[key] = val
                        if isinstance(model.get("displayName"), str):
                            entry["display_name"] = model["displayName"]
                        catalogue.append(entry)
            self.models = catalogue
            self.capabilities["models_source"] = "runtime initialize response"
        for key in ("capabilities", "tools", "skills", "mcp_servers"):
            if key in info:
                self.capabilities[key] = info[key]

    def _check_runtime(self, data: dict[str, Any]) -> None:
        tools = data.get("tools")
        if not isinstance(tools, list) or not isinstance(data.get("mcp_servers"), list):
            raise RPCError("Runtime did not report its effective tools and MCP servers; cannot verify no-tools mode")
        announced = {key: len(data[key]) for key in ("skills", "plugins", "agents")
                     if isinstance(data.get(key), list) and data[key]}
        mcp = data["mcp_servers"]
        if tools or mcp:
            raise RPCError(f"Runtime exposes model tools or MCP servers: {list(tools)}, {len(mcp)} MCP servers")
        # Init advertises an extension catalogue on some installations even
        # under safe mode. It is not evidence of model-accessible tools.
        self.capabilities["extension_catalogue_announced"] = announced
        self.capabilities["no_tools"] = "effective runtime tools and MCP servers verified empty; safe mode requested"
        source = data.get("apiKeySource")
        if source and source != "none":
            self.auth_method = "api_key"
        self.capabilities["authentication"] = self.auth_method
        if data.get("claude_code_version"):
            self.cli_version = str(data["claude_code_version"])
        if data.get("model"):
            self.capabilities["resolved_model"] = data["model"]

    async def _auth_status(self) -> None:
        if not Path(self.cli_path).is_file():
            return
        try:
            process = await asyncio.create_subprocess_exec(
                self.cli_path, "auth", "status", stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL,
            )
            try:
                stdout, _ = await asyncio.wait_for(process.communicate(), timeout=10)
            except asyncio.TimeoutError:
                process.kill()
                await process.communicate()
                return
            if len(stdout) > 16384:
                return
            value = json.loads(stdout)
            mode = value.get("authMethod")
            if mode in ("claude.ai", "oauth_token", "api_key", "api_key_helper", "third_party", "none"):
                self.auth_method = mode
                self.capabilities["authentication"] = mode
        except (OSError, ValueError, KeyError):
            pass

    async def initialize(self, params: dict[str, Any]) -> dict[str, Any]:
        if not self.manifest:
            state = params.get("state_dir") or os.path.join(
                os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local" / "state")),
                "nvim", "nvim-claude")
            self.manifest = Manifest(Path(state).expanduser())
            self.storage.sweep()
        self.allow_api_key = params.get("allow_api_key") is True
        if not self.allow_api_key:
            for name in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"):
                os.environ.pop(name, None)
        await self._auth_status()
        # No model request: connect only to inspect runtime metadata. An offline
        # or unauthenticated runtime still leaves editor commands available.
        try:
            record = self._ensure_active()
            await self._connect(record, self.prompt)
        except Exception as exc:
            self.capabilities["runtime_error"] = str(exc)
        return {"protocol": 1, "python": sys.version.split()[0], "sdk": self.sdk_version,
                "cli": self.cli_version, "models": self.models,
                "capabilities": self.capabilities.copy()}

    def _cache(self, record: dict[str, Any]) -> dict[str, Any]:
        last, ttl = record.get("last_request_at"), record.get("cache_ttl_seconds")
        return {"status": "estimated, not a live cache check",
                "last_request_at": last, "ttl_seconds": ttl,
                "expires_at": last + ttl if last and ttl else None,
                "provenance": "Claude Code documented main-turn defaults; account mode can change"}

    def _documented_cap(self, model: str, limit: int | None) -> bool:
        try:
            version = tuple(int(part) for part in self.cli_version.split(".")[:3])
        except ValueError:
            return False
        # The bundled CLI recognizes this initial model; other manual slugs
        # require their effective runtime window to be measured first.
        return model == "claude-haiku-5-5" and limit is not None and limit >= 100_000 and version >= (2, 1, 259)

    async def _info(self) -> dict[str, Any]:
        await self._expire()
        r = self._ensure_active()
        occupancy = r.get("occupancy")
        limit = r.get("context_limit_tokens")
        runtime_limit = r.get("runtime_context_limit")
        model = next((m for m in self.models if m["id"] == r["model"]), {})
        physical = model.get("context_window")
        if limit is None:
            budget_status = {"status": "model default", "reason": "No local hard budget selected"}
        elif isinstance(runtime_limit, int) and 0 < runtime_limit <= limit:
            budget_status = {"status": "enforced", "reason": "Runtime reports a context window at or below the selected cap"}
        elif self._documented_cap(r["model"], limit) and r["turn_count"] == 0:
            budget_status = {"status": "documented cap pending measurement", "reason": "Runtime window override configured; confirm its reported window after the first turn"}
        else:
            budget_status = {"status": "unsupported", "reason": "Runtime has not reported an effective context window at or below the selected cap"}
        budget_status["runtime_context_limit"] = runtime_limit
        budget_status["physical_context_window"] = physical if type(physical) is int else None
        return {"active_id": r["id"], "session_id": r["session_id"],
                "baseline_epoch": self.epoch, "model": r["model"], "effort": r.get("effort"),
                "context_limit_tokens": limit, "budget_status": budget_status,
                "occupancy": occupancy, "usage": r["usage"],
                "retention": "saved" if r["saved"] else "ephemeral", "sticky": self.sticky,
                "cache": self._cache(r), "python": sys.version.split()[0],
                "sdk": self.sdk_version, "cli": self.cli_version,
                "resolved_model": self.capabilities.get("resolved_model"),
                "budget_enforcement": budget_status["reason"],
                "capabilities": self.capabilities.copy()}

    def _validate_context(self, request: dict[str, Any], record: dict[str, Any]) -> tuple[str | None, str | None]:
        context = request.get("context")
        if context is None:
            return None, None
        if not isinstance(context, dict) or context.get("kind") not in ("snapshot", "excerpt", "diff", "unchanged"):
            raise RPCError("Invalid document context")
        document = request.get("document")
        if not isinstance(document, dict) or not isinstance(document.get("id"), (str, int)):
            raise RPCError("Context requires a document ID")
        doc_id = str(document["id"])
        kind = context["kind"]
        revision = context.get("revision") or context.get("new_revision")
        if not isinstance(revision, (str, int)):
            raise RPCError("Context requires a revision")
        revision = str(revision)
        if kind in ("diff", "unchanged"):
            previous = record["baselines"].get(doc_id)
            base = str(context.get("base_revision")) if kind == "diff" else revision
            if not previous or previous != base:
                raise RPCError("Context baseline is unavailable; resend a full snapshot or marked excerpt",
                               data={"context_reset": True, "baseline_epoch": self.epoch})
        return doc_id, revision

    def _budget(self, record: dict[str, Any], message: str, prompt: str, occupancy: int | None) -> tuple[bool, int]:
        limit = record.get("context_limit_tokens")
        if limit is None:
            return False, record["history_bytes"] + _bytes_upper(prompt) + _bytes_upper(message) + RUNTIME_RESERVE
        if type(limit) is not int or limit <= 0:
            raise RPCError("Context budget must be a positive token count")
        # Runtime/input and completion reserves augment the CLI window guard.
        # History remains charged even when the provider reports a cache hit.
        history_bound = record["history_bytes"] + _bytes_upper(prompt)
        if record.get("requires_measurement") and occupancy is None:
            raise RPCError("Runtime context measurement is unavailable after compaction; cannot admit a capped request")
        estimate = max(history_bound, occupancy or 0) + _bytes_upper(message) + RUNTIME_RESERVE + TURN_RESERVE
        if _bytes_upper(prompt) + _bytes_upper(message) + RUNTIME_RESERVE + TURN_RESERVE > limit:
            raise RPCError(f"Mandatory prompt and target exceed the {limit}-token local budget; no text was truncated")
        # Keep a margin even though the runtime will refuse above its window.
        return estimate > limit - COMPACT_RESERVE, estimate

    @staticmethod
    def _check_usage_context(data: dict[str, Any] | None) -> None:
        if not data:
            return
        unexpected = [key for key in ("memoryFiles", "mcpTools", "agents", "systemTools", "deferredBuiltinTools")
                      if data.get(key)]
        if unexpected:
            raise RPCError("Runtime context contains unexpected memory or tools: " + ", ".join(unexpected))

    async def _usage(self, client: ClaudeSDKClient) -> dict[str, Any] | None:
        try:
            return await asyncio.wait_for(client.get_context_usage(), timeout=8)
        except Exception:
            return None

    async def _compact(self, record: dict[str, Any], client: ClaudeSDKClient) -> dict[str, Any]:
        if record.get("context_limit_tokens") is not None:
            raise RPCError("Manual compaction under a capped session is unsupported: Claude Code disables /compact when enforcing its context window")
        if record["turn_count"] == 0:
            raise RPCError("Nothing to compact in this conversation")
        request_started_at = time.time()
        await client.query("/compact")
        boundary = False
        result = None
        async for msg in client.receive_response():
            if isinstance(msg, SystemMessage) and msg.subtype in ("compact_boundary", "compact_complete"):
                boundary = True
            if isinstance(msg, ResultMessage):
                result = msg
        if not result or result.is_error or result.subtype != "success" or not boundary:
            raise RPCError("Runtime did not confirm compaction; original context was not marked compacted")
        if result.session_id != record["session_id"]:
            record.setdefault("owned_session_ids", [record["session_id"]]).append(result.session_id)
            record["session_id"] = result.session_id
        usage = result.usage or {}
        for key in record["usage"]:
            record["usage"][key] += int(usage.get(key) or 0)
        record["last_request_at"] = request_started_at
        record["baselines"] = {}
        record["history_bytes"] = 0
        record["requires_measurement"] = True
        measured = await self._usage(client)
        record["occupancy"] = {"tokens": measured["totalTokens"], "source": "runtime get_context_usage"} if measured and isinstance(measured.get("totalTokens"), int) else None
        self.epoch += 1
        self._persist()
        return {"compacted": True, "context_reset": True, "baseline_epoch": self.epoch}

    async def turn(self, params: dict[str, Any], rpc_id: Any, send) -> dict[str, Any]:
        await self._expire(allow_pending=True)
        r = self._ensure_active()
        expected_epoch = params.get("baseline_epoch")
        if expected_epoch is not None and expected_epoch != self.epoch:
            raise RPCError("Conversation changed; refresh context before sending", data={"context_reset": True, "baseline_epoch": self.epoch})
        operation, request = params.get("operation"), params.get("request")
        if operation not in ("ask", "replace", "generate") or not isinstance(request, dict) or request.get("operation") != operation:
            raise RPCError("Invalid turn operation/request")
        if not isinstance(request.get("instruction"), str) or not request["instruction"].strip():
            raise RPCError("Turn requires a nonempty instruction")
        if operation != "ask" and not isinstance(request.get("targets"), list):
            raise RPCError("Editing requires captured target(s)")
        doc_id, revision = self._validate_context(request, r)
        model = params.get("model", r["model"])
        effort = params.get("effort", r.get("effort"))
        limit = params.get("context_limit_tokens", r.get("context_limit_tokens"))
        prompt = params.get("system_prompt", self.default_prompt)
        if not isinstance(model, str) or not model.strip() or (effort is not None and effort not in EFFORTS):
            raise RPCError("Invalid model or effort")
        if not isinstance(prompt, str) or not prompt.strip():
            raise RPCError("System prompt cannot be empty")
        if limit is not None and (type(limit) is not int or limit <= 0):
            raise RPCError("Context budget must be positive or model default")
        selected = next((m for m in self.models if m["id"] == model), None)
        if selected and isinstance(selected.get("efforts"), list) and effort and effort not in selected["efforts"]:
            raise RPCError(f"Effort {effort} is not announced for model {model}")
        # Do not permanently mutate the session configuration before admission.
        previous = (r["model"], r.get("effort"), r.get("context_limit_tokens"))
        old_prompt = self.prompt
        r.update(model=model, effort=effort, context_limit_tokens=limit)
        text = json.dumps(request, ensure_ascii=False, separators=(",", ":"))
        self.prompt = prompt
        try:
            client = await self._connect(r, prompt)
            measured = await self._usage(client)
            self._check_usage_context(measured)
            runtime_limit = measured.get("rawMaxTokens") if measured else None
            if limit is not None:
                if type(runtime_limit) is int:
                    if runtime_limit <= 0 or runtime_limit > limit:
                        raise RPCError("Unsupported local budget: runtime reports a context window above the selected cap")
                    r["runtime_context_limit"] = runtime_limit
                elif r["turn_count"] != 0 or not self._documented_cap(model, limit):
                    raise RPCError("Unsupported local budget: runtime did not report an effective context window at or below the selected cap")
            occupancy = measured.get("totalTokens") if measured else None
            must_compact, estimate = self._budget(r, text, prompt, occupancy)
            if must_compact and not r["turn_count"]:
                raise RPCError("Initial request cannot fit the local budget with runtime and output reserves; choose a larger budget or reduce explicit context")
            if must_compact:
                raise RPCError("Next turn approaches the local budget; this runtime cannot compact while its hard context window is active. Start a fresh conversation or explicitly select model-default budget.")
            await send({"jsonrpc": "2.0", "method": "event", "params": {"id": rpc_id, "epoch": params.get("epoch"), "type": "status", "status": "continued" if r["turn_count"] else "new"}})
            request_started_at = time.time()
            await client.query(text)
            chunks: list[str] = []
            streamed = False
            final_assistant: str | None = None
            result: ResultMessage | None = None
            compacted = False
            resolved_model = None
            async for msg in client.receive_response():
                if self.cancelled:
                    continue
                if isinstance(msg, SystemMessage):
                    if msg.subtype == "init":
                        self._check_runtime(msg.data)
                    elif msg.subtype == "compact_boundary":
                        compacted = True
                elif isinstance(msg, StreamEvent):
                    event = msg.event
                    delta = event.get("delta", {})
                    if event.get("type") == "content_block_delta" and delta.get("type") == "text_delta":
                        part = delta.get("text", "")
                        if isinstance(part, str) and part:
                            chunks.append(part)
                            streamed = True
                            await send({"jsonrpc": "2.0", "method": "event", "params": {"id": rpc_id, "epoch": params.get("epoch"), "type": "partial", "text": "".join(chunks)}})
                elif isinstance(msg, AssistantMessage):
                    if msg.error:
                        raise RPCError(f"Assistant failed: {msg.error}")
                    if any(isinstance(block, (ToolUseBlock, ServerToolUseBlock)) for block in msg.content):
                        raise RPCError("Runtime attempted a model tool call despite no-tools configuration")
                    resolved_model = msg.model
                    final_assistant = "".join(b.text for b in msg.content if isinstance(b, TextBlock))
                    if not streamed and final_assistant:
                        await send({"jsonrpc": "2.0", "method": "event", "params": {"id": rpc_id, "epoch": params.get("epoch"), "type": "partial", "text": final_assistant}})
                elif isinstance(msg, ResultMessage):
                    result = msg
            if self.cancelled or (result and result.terminal_reason in ("aborted_streaming", "aborted_tools")):
                raise RPCError("Turn canceled; no edit was applied")
            if not result or result.is_error or result.subtype != "success":
                raise RPCError("Claude runtime failed: " + ("; ".join(result.errors or []) or str(result.result or result.subtype)) if result else "No runtime result")
            answer = final_assistant if final_assistant is not None else "".join(chunks)
            if not answer and isinstance(result.result, str):
                answer = result.result
            if not answer:
                raise RPCError("Claude returned no assistant text")
            if result.session_id != r["session_id"]:
                # Keep ownership of every transcript this conversation produced.
                r.setdefault("owned_session_ids", [r["session_id"]]).append(result.session_id)
                r["session_id"] = result.session_id
            r["turn_count"] += 1
            r["history_bytes"] += _bytes_upper(text) + _bytes_upper(answer) + 1024
            r["last_request_at"] = request_started_at
            r["cache_ttl_seconds"] = 3600 if self.auth_method == "claude.ai" else 300
            if doc_id and revision:
                if request["context"]["kind"] == "excerpt":
                    r["baselines"].pop(doc_id, None)
                else:
                    r["baselines"][doc_id] = revision
            if not r["title"]:
                r["title"] = request["instruction"].replace("\n", " ").strip()[:90]
            usage = result.usage or {}
            for key in r["usage"]:
                r["usage"][key] += int(usage.get(key) or 0)
            measured = await self._usage(client)
            self._check_usage_context(measured)
            after_limit = measured.get("rawMaxTokens") if measured else None
            if limit is not None and type(after_limit) is int:
                if after_limit <= 0 or after_limit > limit:
                    raise RPCError("Runtime did not enforce the selected context window; result withheld")
                r["runtime_context_limit"] = after_limit
            r["occupancy"] = {"tokens": measured["totalTokens"], "source": "runtime get_context_usage"} if measured and isinstance(measured.get("totalTokens"), int) else {"tokens": estimate, "source": "local upper-bound estimate"}
            if compacted:
                self.epoch += 1
                r["baselines"] = {}
                r["history_bytes"] = _bytes_upper(text) + _bytes_upper(answer) + 1024
            self._persist()
            return {"text": answer, "accepted_context": True, "active_id": r["id"], "session_id": r["session_id"],
                    "occupancy": r["occupancy"], "usage": r["usage"].copy(),
                    "resolved_model": resolved_model or self.capabilities.get("resolved_model") or model,
                    "cache": self._cache(r), "context_reset": compacted,
                    "baseline_epoch": self.epoch}
        except BaseException:
            # An uncertain turn must never leave a confirmed document baseline.
            r["baselines"] = {}
            self.epoch += 1
            r.update(model=previous[0], effort=previous[1], context_limit_tokens=previous[2])
            self.prompt = old_prompt
            self._persist()
            await self._disconnect()
            raise

    async def session(self, params: dict[str, Any]) -> dict[str, Any]:
        action = params.get("action")
        if action == "info":
            return await self._info()
        if action == "list":
            saved = sorted(self.storage.list(), key=lambda r: r["updated_at"], reverse=True)
            return {"conversations": [
                {"id": r["id"], "title": time.strftime("%y:%m:%d:%H:%M:%S", time.localtime(r["created_at"])) + " - " + (r.get("title") or "Untitled") + " [" + r["id"][:8] + "]",
                 "created_at": r["created_at"], "updated_at": r["updated_at"], "model": r["model"],
                 "effort": r.get("effort"), "context_limit_tokens": r.get("context_limit_tokens")}
                for r in saved], "active_id": self.active["id"] if self.active else None, "sticky": self.sticky}
        if action == "sticky":
            value = params.get("value", params.get("enabled"))
            self.sticky = not self.sticky if value is None else (value is True or value == "on")
            if self.sticky:
                r = self._ensure_active()
                r["saved"] = True
                self._persist()
            return {"sticky": self.sticky, "active_id": self.active["id"] if self.active else None}
        if action == "save":
            r = self._ensure_active()
            r["saved"] = True
            self._persist()
            return {"saved": True, "active_id": r["id"]}
        if action == "resume":
            rid = params.get("id") or params.get("conversation_id")
            if not isinstance(rid, str):
                raise RPCError("Resume requires a saved conversation ID")
            candidate = self.storage.claim(rid)
            await self._disconnect()
            if self.active and not self.active["saved"]:
                self.storage.remove(self.active)
            candidate["baselines"] = {}
            candidate["runtime_context_limit"] = None
            self.active = candidate
            self.epoch += 1
            self._persist()
            return await self._info()
        if action in ("new", "clear"):
            await self._disconnect()
            profile = self.active.copy() if self.active else None
            if self.active and not self.active["saved"]:
                self.storage.remove(self.active)
            self.active = self._new(profile)
            self.storage.save(self.active)
            self.epoch += 1
            return await self._info()
        if action == "compact":
            r = self._ensure_active()
            if r.get("context_limit_tokens") is not None:
                raise RPCError("Compaction under a capped conversation is unsupported by the installed CLI; no model request was sent")
            client = await self._connect(r, self.prompt)
            try:
                return await self._compact(r, client)
            except Exception:
                await self._disconnect()
                raise
        raise RPCError(f"Unknown session action: {action}", code=-32601)

    async def login(self) -> dict[str, Any]:
        if not Path(self.cli_path).is_file():
            raise RPCError("Bundled Claude Code CLI is unavailable; reinstall claude-agent-sdk")
        return {"command": [self.cli_path, "auth", "login"],
                "message": "Run the official bundled Claude Code login flow in a terminal; credentials stay with Claude Code."}

    async def close(self) -> None:
        await self._disconnect()
        if self.manifest and self.active and not self.active["saved"]:
            self.storage.remove(self.active)


async def _read_frame() -> dict[str, Any] | None:
    def read():
        stream = sys.stdin.buffer
        headers = []
        while True:
            line = stream.readline(8192)
            if not line:
                return None
            if line in (b"\r\n", b"\n"):
                break
            headers.append(line)
            if len(headers) > 32:
                raise RPCError("Too many protocol headers", -32700)
        length = None
        for line in headers:
            name, sep, value = line.partition(b":")
            if sep and name.strip().lower() == b"content-length":
                try:
                    length = int(value.strip())
                except ValueError:
                    raise RPCError("Invalid Content-Length", -32700) from None
        if length is None or not 0 < length <= MAX_FRAME:
            raise RPCError("Missing or oversized Content-Length", -32700)
        raw = stream.read(length)
        if len(raw) != length:
            raise RPCError("Truncated protocol frame", -32700)
        return json.loads(raw)
    return await asyncio.to_thread(read)


async def main() -> None:
    bridge = Bridge()

    async def send(message: dict[str, Any]) -> None:
        raw = json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        sys.stdout.buffer.write(b"Content-Length: " + str(len(raw)).encode() + b"\r\n\r\n" + raw)
        sys.stdout.buffer.flush()

    async def dispatch(request: dict[str, Any]) -> None:
        rpc_id = request.get("id")
        params = request.get("params") or {}
        try:
            if not isinstance(params, dict):
                raise RPCError("RPC params must be an object", -32602)
            method = request.get("method")
            if method == "initialize":
                value = await bridge.initialize(params)
            elif method == "cancel":
                if bridge.pending and params.get("id") == bridge.pending_id and params.get("epoch") == bridge.pending_epoch:
                    bridge.cancelled = True
                    if bridge.client:
                        await bridge.client.interrupt()
                value = {"cancelled": bridge.cancelled}
            elif method == "turn":
                if bridge.pending:
                    raise RPCError("A turn is already active")
                bridge.pending = asyncio.current_task()
                bridge.pending_id = rpc_id
                bridge.pending_epoch = params.get("epoch")
                bridge.cancelled = False
                try:
                    value = await bridge.turn(params, rpc_id, send)
                finally:
                    bridge.pending = None
                    bridge.pending_id = None
                    bridge.pending_epoch = None
            elif method == "session":
                if bridge.pending:
                    raise RPCError("Finish or cancel the active turn before changing sessions")
                value = await bridge.session(params)
            elif method == "login":
                value = await bridge.login()
            else:
                raise RPCError("Unknown JSON-RPC method", -32601)
            if rpc_id is not None:
                await send({"jsonrpc": "2.0", "id": rpc_id, "result": value})
        except Exception as exc:
            if rpc_id is not None:
                error = {"code": exc.code, "message": str(exc)} if isinstance(exc, RPCError) else {"code": -32000, "message": str(exc)}
                if isinstance(exc, RPCError) and exc.data is not None:
                    error["data"] = exc.data
                await send({"jsonrpc": "2.0", "id": rpc_id, "error": error})

    tasks = set()
    try:
        while True:
            frame = await _read_frame()
            if frame is None:
                break
            if not isinstance(frame, dict) or frame.get("jsonrpc") != "2.0":
                await send({"jsonrpc": "2.0", "id": frame.get("id") if isinstance(frame, dict) else None,
                            "error": {"code": -32600, "message": "Invalid JSON-RPC request"}})
                continue
            task = asyncio.create_task(dispatch(frame))
            tasks.add(task)
            task.add_done_callback(tasks.discard)
    except (RPCError, ValueError, json.JSONDecodeError) as exc:
        print(f"Protocol read failure: {exc}", file=sys.stderr)
    finally:
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        await bridge.close()


if __name__ == "__main__":
    asyncio.run(main())
