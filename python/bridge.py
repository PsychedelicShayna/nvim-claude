"""One stdio JSON-RPC bridge and one task-owned SDK client per editor instance."""
import argparse
import asyncio
import contextlib
import importlib.metadata
import json
import os
from pathlib import Path
import signal
import sys
import time
import uuid

from claude_agent_sdk import (AssistantMessage, ClaudeAgentOptions, ClaudeSDKClient,
                              RateLimitEvent, ResultMessage, SystemMessage, TextBlock)
from claude_agent_sdk.types import StreamEvent
from claude_agent_sdk._internal.sessions import _resolve_session_file_path

from policy import (COMPACT_RESERVE, OUTPUT_RESERVE, OVERHEAD, PRESETS, byte_bound,
                    edit_result, encode, enforce_budget, excerpt, make_context,
                    normalize, parse_model, prompt_bound)
from storage import Store

MAX_FRAME = 32 * 1024 * 1024
DEFAULT = {"model": "claude-haiku-5-5", "effort": "low", "context_limit_tokens": 100000}
ROOT = Path(__file__).resolve().parent.parent


def send(value):
    body = encode(value).encode("utf-8")
    sys.stdout.buffer.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
    sys.stdout.buffer.flush()


def read_frame():
    headers = {}
    while True:
        line = sys.stdin.buffer.readline(8192)
        if not line:
            return None
        if line in (b"\r\n", b"\n"):
            break
        key, separator, value = line.decode("ascii").partition(":")
        if not separator:
            raise ValueError("Malformed RPC header")
        headers[key.lower()] = value.strip()
    size = int(headers.get("content-length", "0"))
    if not 0 < size <= MAX_FRAME:
        raise ValueError("Invalid Content-Length")
    body = bytearray()
    while len(body) < size:
        part = sys.stdin.buffer.read(size - len(body))
        if not part:
            raise EOFError("Truncated RPC frame")
        body.extend(part)
    return json.loads(body)


class Bridge:
    def __init__(self, state):
        self.store = Store(state)
        self.config = dict(DEFAULT)
        self.sticky = False
        self.record = self.store.new(self.config)
        self.client = None
        self.server = {}
        self.baselines = {}
        self.context = {}
        self.prompt = (ROOT / "prompts/system.txt").read_text()
        self.punctuation = "allow"
        self.punctuation_map = None
        self.active = None
        self.cancelled = False
        self.epoch = 0
        self.busy = False
        self.queue = asyncio.Queue()
        self.last_bound = None
        self.billing = "unknown; no API-key fallback"
        self.cache_ttl = 300
        self.cache_provenance = "conservative five-minute estimate; account/overage mode unknown"

    def event(self, kind, **data):
        send({"jsonrpc": "2.0", "method": "event", "params": {
            "kind": kind, "request_id": self.active, "epoch": self.epoch, **data}})

    def track(self):
        sid = self.record.get("session_id")
        if sid:
            path = _resolve_session_file_path(sid, str(self.store.workspace))
            if path:
                self.store.remember_path(self.record, path, sid)

    async def disconnect(self):
        if self.client:
            await self.client.disconnect()
            self.client = None
        self.track()

    async def connect(self):
        if self.client:
            return
        # API billing must be explicitly selected, never chosen by inherited keys.
        env = {
            "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1", "CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1",
            "CLAUDE_CODE_DISABLE_BUNDLED_SKILLS": "1", "CLAUDE_AGENT_SDK_DISABLE_BUILTIN_AGENTS": "1",
            "DISABLE_DOCTOR_COMMAND": "1",
            "CLAUDE_CODE_AUTO_CONNECT_IDE": "false", "CLAUDE_CODE_DISABLE_ATTACHMENTS": "1",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "CLAUDE_CODE_DISABLE_BACKGROUND_TASKS": "1",
            "CLAUDE_CODE_DISABLE_TERMINAL_TITLE": "1", "CLAUDE_CODE_DISABLE_ADVISOR_TOOL": "1",
            "CLAUDE_CODE_PLUGIN_DIRS": "", "DISABLE_AUTO_COMPACT": "1",
            "CLAUDE_CODE_MAX_OUTPUT_TOKENS": str(OUTPUT_RESERVE), "MAX_THINKING_TOKENS": "0",
            "CLAUDE_CODE_EFFORT_LEVEL": self.config.get("effort") or "",
            "ANTHROPIC_MODEL": self.config["model"], "ANTHROPIC_DEFAULT_MODEL": self.config["model"],
            "ANTHROPIC_SMALL_FAST_MODEL": self.config["model"],
        }
        if self.config.get("billing", "subscription") == "subscription":
            for key in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_PROFILE",
                        "ANTHROPIC_FEDERATION_RULE_ID", "ANTHROPIC_ORGANIZATION_ID",
                        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"):
                env[key] = ""
        settings = {"disableAllHooks": True, "autoMemoryEnabled": False,
                    "autoConnectIde": False, "enableAllProjectMcpServers": False,
                    "enabledPlugins": {"cc-plugin-agents-md@builtin": False,
                                       "cc-plugin-plugin-authoring@builtin": False}}
        sid = self.record.get("session_id")
        if sid and not _resolve_session_file_path(sid, str(self.store.workspace)):
            sid = None  # A model-menu handshake need not have written a transcript.
        options = ClaudeAgentOptions(
            model=self.config["model"], effort=self.config.get("effort"),
            thinking={"type": "disabled"}, tools=[], mcp_servers={}, strict_mcp_config=True,
            setting_sources=[], skills=[], agents={}, plugins=[],
            system_prompt={"type": "custom", "prompt": self.prompt, "snapshot": False},
            cwd=str(self.store.workspace), env=env, settings=encode(settings),
            include_partial_messages=True, resume=sid,
            session_id=None if sid else str(uuid.uuid4()),
            extra_args={"no-chrome": None, "safe-mode": None},
        )
        self.record["session_id"] = sid or options.session_id
        self.store.write(self.record)
        self.client = ClaudeSDKClient(options)
        try:
            await self.client.connect()
            self.server = await self.client.get_server_info() or {}
            self.context = await self.client.get_context_usage()
            self.check_isolation(self.context)
            if (await self.client.get_mcp_status()).get("mcpServers"):
                raise ValueError("Runtime exposed unexpected MCP servers; refusing model access")
            if self.server.get("agents"):
                raise ValueError("Runtime exposed unexpected agents")
            account = self.server.get("account") or {}
            if account.get("subscriptionType") and self.config.get("billing", "subscription") == "subscription":
                self.billing = "subscription credentials; overage status not yet known"
            elif self.config.get("billing") == "api":
                self.billing = "explicit API/provider environment credentials"
            self.validate_effort(self.config)
        except BaseException:
            await self.disconnect()
            raise

    @staticmethod
    def check_isolation(context):
        for field in ("memoryFiles", "mcpTools", "agents", "systemTools", "deferredBuiltinTools"):
            if context.get(field):
                raise ValueError(f"No-tools isolation failed: runtime supplied {field}")
        if context.get("skills", {}).get("totalTokens", 0):
            raise ValueError("Runtime supplied unexpected skill context")
        # Context metadata is an estimate, so leave an intentionally large fixed
        # allowance and fail closed if even that cannot cover reported overhead.
        overhead = sum(c["tokens"] for c in context.get("categories", [])
                       if c.get("kind") == "used" and c.get("id") not in ("messages", "system_prompt"))
        if overhead > OVERHEAD:
            raise ValueError("Unsupported strict budget: runtime overhead exceeds the safety allowance")

    def model_metadata(self, config):
        return next((m for m in self.server.get("models", [])
                     if config["model"] in (m.get("value"), m.get("resolvedModel"))), None)

    def validate_effort(self, config):
        metadata = self.model_metadata(config)
        effort = config.get("effort")
        if effort and metadata:
            if not metadata.get("supportsEffort") or effort not in metadata.get("supportedEffortLevels", []):
                raise ValueError(f"Runtime does not announce effort {effort!r} for this model")
        elif effort and config["model"] != DEFAULT["model"]:
            raise ValueError("Unknown effort support for this manual model; configure effort=null explicitly")

    async def fresh(self, resume=None):
        if resume == self.record["id"]:
            return
        await self.disconnect()
        old = self.record
        if resume:
            # Acquire before deleting or replacing current state.
            record = self.store.load(resume)
        else:
            self.store.release()
            record = self.store.new(self.config, self.sticky)
        self.store.delete(old)
        self.record = record
        self.config = dict(record["config"])
        self.baselines.clear()
        self.event("context_reset", reason="conversation changed")

    async def expired(self):
        if not self.record["saved"] and self.record["last_used"] and time.time() - self.record["last_used"] >= self.cache_ttl:
            await self.fresh()

    async def stream(self, text, compact=False):
        self.track()
        self.record["last_used"] = time.time()  # TTL starts when the request reads its prefix.
        self.store.write(self.record)
        await self.client.query(text)
        partial, final, boundary, result = "", "", False, None
        async for message in self.client.receive_response():
            if isinstance(message, SystemMessage):
                data = message.data
                if message.subtype == "init":
                    self.record["session_id"] = data["session_id"]
                    self.track()
                    unexpected = {k: data.get(k) for k in ("tools", "mcp_servers", "agents", "skills") if data.get(k)}
                    if unexpected:
                        await self.client.interrupt()
                        raise ValueError(f"Runtime violated no-tools contract: {list(unexpected)}")
                    if data.get("plugins"):
                        await self.client.interrupt()
                        raise ValueError("Runtime loaded plugins despite isolation; refusing output")
                    self.billing = data.get("apiKeySource", "unknown") + "; " + (
                        "explicit API/provider credentials" if self.config.get("billing") == "api"
                        else "subscription requested; no API-key fallback")
                if message.subtype == "compact_boundary":
                    boundary = True
                    self.baselines.clear()
                if message.subtype == "status":
                    self.event("status", status=data.get("status") or ("compacting" if compact else "running"))
            elif isinstance(message, StreamEvent) and not message.parent_tool_use_id:
                event = message.event
                if event.get("type") == "content_block_delta" and event.get("delta", {}).get("type") == "text_delta":
                    delta = event["delta"]["text"]
                    partial += delta
                    if not compact and not self.cancelled:
                        self.event("text", text=normalize(delta, self.punctuation, self.punctuation_map))
                if event.get("type") == "message_start":
                    usage = event["message"].get("usage", {})
                    measured = sum(usage.get(k, 0) for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
                    if self.last_bound and measured > self.last_bound:
                        self.event("budget_violation", measured=measured, bound=self.last_bound)
                        self.cancelled = True
                        await self.client.interrupt()
                        raise ValueError("Runtime exceeded the established byte bound; strict budgeting unsupported")
            elif isinstance(message, AssistantMessage) and not message.parent_tool_use_id:
                if message.error:
                    raise ValueError(f"Model request failed: {message.error}")
                final += "".join(block.text for block in message.content if isinstance(block, TextBlock))
            elif isinstance(message, RateLimitEvent):
                raw_limit = message.rate_limit_info.raw or {}
                if raw_limit.get("isUsingOverage") is False and self.config.get("billing", "subscription") == "subscription":
                    self.cache_ttl = 3600
                    self.cache_provenance = "one-hour included-subscription estimate from runtime rate-limit metadata"
                elif raw_limit.get("isUsingOverage") is True:
                    self.cache_ttl = 300
                    self.cache_provenance = "five-minute usage-credit estimate from runtime rate-limit metadata"
            elif isinstance(message, ResultMessage):
                result = message
        self.track()
        if self.cancelled:
            raise ValueError("Request canceled; no source edit applied")
        if result is None or result.is_error or result.subtype != "success":
            raise ValueError(f"SDK request failed: {getattr(result, 'result', None) or getattr(result, 'subtype', 'no result')}. "
                             "Use :NvClaude login for the bundled runtime's supported login flow.")
        raw = final or result.result or partial
        if not partial and raw and not compact:
            self.event("text", text=normalize(raw, self.punctuation, self.punctuation_map))
        costs = self.record.setdefault("runtime_costs", {})
        prior = costs.get(result.session_id, 0)
        self.record["cost_usd"] += max(0, (result.total_cost_usd or 0) - prior)
        costs[result.session_id] = result.total_cost_usd or prior
        for key, value in (result.usage or {}).items():
            if isinstance(value, (int, float)):
                self.record["usage"][key] = self.record["usage"].get(key, 0) + value
        self.store.write(self.record)
        return raw, boundary

    def compacted_history(self):
        self.track()
        # Runtime compaction writes a boundary followed by a summary user message.
        # Count every retained serialized message, including reasoning, rather
        # than estimating the summary from a success banner.
        history, seen = [], False
        for path in self.record["paths"]:
            for line in Path(path).read_text().splitlines():
                entry = json.loads(line)
                if entry.get("type") == "system" and entry.get("subtype") == "compact_boundary":
                    history, seen = [], True
                if seen and entry.get("type") in ("user", "assistant"):
                    history.append(encode(entry.get("message", {})))
        if not seen or not history:
            raise ValueError("Runtime did not expose its retained compaction summary; cannot establish a safe next-request bound")
        return history

    async def compact(self):
        await self.connect()
        physical = self.context["rawMaxTokens"]
        self.last_bound = enforce_budget(self.prompt, self.record["history"], "\n/compact\n" + "x" * COMPACT_RESERVE,
                                         self.config["context_limit_tokens"], physical)
        self.event("status", status="compacting")
        _, boundary = await self.stream("/compact", compact=True)
        if not boundary:
            raise ValueError("Runtime did not report compact_boundary; compaction not confirmed")
        self.record["history"] = self.compacted_history()
        self.baselines.clear()
        self.store.write(self.record)
        self.context = await self.client.get_context_usage()
        self.event("context_reset", reason="runtime compaction; file baselines invalidated")
        return {"compacted": True, "memory": "lossy runtime summary"}

    async def turn(self, request):
        await self.expired()
        await self.connect()
        self.event("status", status="continued" if self.record["history"] else "new")
        physical = self.context["rawMaxTokens"]
        limit = min(self.config["context_limit_tokens"] or physical, physical - OUTPUT_RESERVE)
        # Proactively compact before the summary request itself is too large.
        if self.record["history"] and prompt_bound(self.prompt, self.record["history"], "") + COMPACT_RESERVE + OUTPUT_RESERVE >= limit:
            await self.compact()
        payload, baseline = make_context(request, self.baselines)
        mandatory = prompt_bound(self.prompt, self.record["history"], "")
        if prompt_bound(self.prompt, self.record["history"], encode(payload)) > limit:
            if self.record["history"]:
                await self.compact()
                payload, baseline = make_context(request, self.baselines)
                mandatory = prompt_bound(self.prompt, self.record["history"], "")
            payload = excerpt(payload, limit - mandatory)
        text = encode(payload)
        self.last_bound = enforce_budget(self.prompt, self.record["history"], text,
                                         self.config["context_limit_tokens"], physical)
        if not self.record["first_prompt"]:
            self.record["first_prompt"] = request["instruction"]
        raw, boundary = await self.stream(text)
        self.record["history"].extend([text, raw])
        if boundary:
            self.record["history"] = self.compacted_history()
            self.baselines.clear()
        elif baseline and payload.get("context", {}).get("kind") != "excerpt":
            doc, revision, buffer_text = baseline
            self.baselines[doc] = (revision, buffer_text)
        self.store.write(self.record)
        self.context = await self.client.get_context_usage()
        self.check_isolation(self.context)
        response = {"raw": raw, "operation": request["operation"], "bound": self.last_bound,
                    "context_kind": payload.get("context", {}).get("kind")}
        if request["operation"] == "ask":
            response["text"] = normalize(raw, self.punctuation, self.punctuation_map)
        else:
            value = edit_result(raw, request["targets"])
            if value["status"] == "ok":
                for replacement in value["replacements"]:
                    replacement["text"] = normalize(replacement["text"], self.punctuation, self.punctuation_map)
            response["edit"] = value
        return response

    async def handle(self, method, params):
        if method == "initialize":
            config = params.get("config", {})
            self.config.update(config)
            self.record["config"] = dict(self.config)
            self.store.write(self.record)
            return {"protocol": 1, "python": sys.version.split()[0],
                    "sdk": importlib.metadata.version("claude-agent-sdk"),
                    "capabilities": ["stream", "cancel", "sessions", "byte-budget", "targets"]}
        if method == "turn":
            return await self.turn(params)
        if method == "models":
            await self.connect()
            return {"models": self.server.get("models", []), "presets": PRESETS, "config": self.config}
        if method == "configure":
            await self.connect()
            native = {m["value"] for m in self.server.get("models", []) if "[" in m.get("value", "")}
            native.update({"claude-opus-4-6[1m]", "claude-sonnet-4-6[1m]"})
            config = parse_model(params["expression"], self.config, native) if "expression" in params else {**self.config, **params}
            self.validate_effort(config)
            await self.disconnect()
            self.config = config
            self.record["config"] = dict(config)
            self.baselines.clear()
            self.store.write(self.record)
            return config
        if method in ("new", "clear", "resume"):
            await self.fresh(params.get("id") if method == "resume" else None)
            return {"id": self.record["id"]}
        if method == "save":
            self.record["saved"] = True
            self.store.write(self.record)
            return {"saved": self.record["id"]}
        if method == "sticky":
            self.sticky = params.get("enabled", not self.sticky)
            if self.sticky:
                self.record["saved"] = True
                self.store.write(self.record)
            return {"sticky": self.sticky}
        if method == "list":
            return self.store.list()
        if method == "compact":
            return await self.compact()
        if method == "system":
            await self.disconnect()
            self.prompt = params.get("text") or (ROOT / "prompts/system.txt").read_text()
            self.baselines.clear()
            return {"system": "updated; SDK session will resume with snapshot=False", "cache": "prefix invalidated"}
        if method == "watermarks":
            if params["mode"] not in ("allow", "remove", "replace"):
                raise ValueError("Use watermarks allow, remove, or replace")
            self.punctuation = params["mode"]
            self.punctuation_map = params.get("map")
            return {"punctuation": self.punctuation}
        if method == "login":
            import claude_agent_sdk
            return {"argv": [str(Path(claude_agent_sdk.__file__).parent / "_bundled" / "claude"), "auth", "login"]}
        if method == "info":
            if self.client:
                self.context = await self.client.get_context_usage()
            return {"config": self.config, "conversation": self.record["id"], "saved": self.record["saved"],
                    "sticky": self.sticky, "occupancy": self.context.get("totalTokens"),
                    "occupancy_provenance": "runtime estimate, not cumulative billed tokens",
                    "physical_context": self.context.get("rawMaxTokens"), "last_prompt_byte_bound": self.last_bound,
                    "budget": "conservative UTF-8 byte bound plus 16,384 runtime/framing tokens; not a provider-side cap",
                    "output_reserve": OUTPUT_RESERVE, "cumulative_usage": self.record["usage"],
                    "cumulative_cost_usd": self.record["cost_usd"], "billing": self.billing,
                    "cache": {"ttl_seconds": self.cache_ttl, "provenance": self.cache_provenance,
                              "remaining_estimate": max(0, self.cache_ttl - (time.time() - self.record["last_used"]))},
                    "python": sys.version.split()[0], "sdk": importlib.metadata.version("claude-agent-sdk"),
                    "cli": self.server.get("claude_code_version"), "session_id": self.record["session_id"]}
        raise ValueError(f"Unknown bridge method: {method}")

    async def worker(self):
        try:
            while True:
                frame = await self.queue.get()
                if frame is None:
                    break
                self.active, self.cancelled = frame.get("id"), False
                self.epoch = frame.get("params", {}).pop("epoch", self.epoch)
                method, params = frame["method"], frame.get("params", {})
                try:
                    result = await self.handle(method, params)
                    send({"jsonrpc": "2.0", "id": self.active, "result": result})
                except Exception as error:
                    self.baselines.clear()
                    # Invalid edit envelopes retain raw output for inspection.
                    send({"jsonrpc": "2.0", "id": self.active, "error": {"code": -32000, "message": str(error)}})
                finally:
                    self.active = None
                    self.busy = False
        finally:
            await self.disconnect()
            self.store.close(self.record)

    async def run(self):
        worker = asyncio.create_task(self.worker())
        try:
            while True:
                frame = await asyncio.to_thread(read_frame)
                if frame is None:
                    break
                method = frame.get("method")
                if method in ("cancel", "shutdown"):
                    self.cancelled = True
                    self.baselines.clear()
                    if self.client and self.active:
                        await self.client.interrupt()
                    if "id" in frame:
                        send({"jsonrpc": "2.0", "id": frame["id"], "result": {"canceled": True}})
                    if method == "shutdown":
                        break
                elif self.busy:
                    send({"jsonrpc": "2.0", "id": frame.get("id"), "error": {
                        "code": -32001, "message": "Conversation busy; draft retained. Cancel the active request before switching state."}})
                else:
                    self.busy = True
                    await self.queue.put(frame)
        finally:
            self.cancelled = True
            if self.client and self.active:
                with contextlib.suppress(Exception):
                    await self.client.interrupt()
            await self.queue.put(None)
            await worker


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", required=True)
    args = parser.parse_args()
    asyncio.run(Bridge(args.state).run())


if __name__ == "__main__":
    main()
