#!/usr/bin/env python3
"""One editor's framed JSON-RPC connection to the official Claude Agent SDK."""
from __future__ import annotations

import argparse
import asyncio
import dataclasses
import fcntl
import importlib.metadata
import json
import os
from pathlib import Path
import re
import sys
import time
import uuid

from claude_agent_sdk import (
    AssistantMessage, ClaudeAgentOptions, ClaudeSDKClient, ResultMessage,
    StreamEvent, SystemMessage, TextBlock, delete_session, get_session_messages,
)
import claude_agent_sdk

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_PROMPT = ROOT / "resources" / "system.txt"
EFFORTS = {"low", "medium", "high", "xhigh", "max"}
PRESETS = [50000,90000,100000,124000,150000,164000,200000,224000,256000,
           258000,274000,278000,300000,374000,378000,384000,412000,456000,
           500000,512000,600000,650000,700000,750000,800000,850000,900000,
           950000,980000]
# A byte-level tokenizer cannot produce more text tokens than UTF-8 bytes.
# Reserve runtime framing and control content separately, never divide by four.
OVERHEAD = 16384
OUTPUT = 8192
MAX_FRAME = 32 * 1024 * 1024


def encoded(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def parse_model(expression, current, native_models=()):
    result = dict(current)
    model = expression.strip()
    if not model:
        raise ValueError("A model ID is required")
    head, sep, tail = model.rpartition(":")
    if sep and tail in EFFORTS:
        model, result["effort"] = head, tail
    groups = list(re.finditer(r"\[(?:limit=)?(\d+(?:\.\d+)?[km]?)\]", model, re.I))
    if groups and groups[-1].end() == len(model):
        last = groups[-1]
        explicit = last.group().startswith("[limit=")
        # Native [1m] selectors are recognized only for runtime-announced models
        # or the documented Opus/Sonnet selector families.
        native = model in native_models or (last.group().lower() == "[1m]" and
                 re.fullmatch(r"(?:claude-)?(?:opus|sonnet)(?:-[0-9]+)*\[1m\]", model))
        if explicit or len(groups) > 1 or not native:
            raw = last.group(1).lower()
            factor = 1000 if raw.endswith("k") else 1000000 if raw.endswith("m") else 1
            limit = float(raw[:-1] if factor > 1 else raw) * factor
            if not limit.is_integer() or limit < 1:
                raise ValueError("Context budget must be a positive integer")
            result["context_limit_tokens"] = int(limit)
            model = model[:last.start()]
    result["model"] = model
    return result


def frame(message):
    body = encoded(message).encode()
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
        key, value = line.decode("ascii").split(":", 1)
        headers[key.lower()] = value.strip()
    length = int(headers["content-length"])
    if not 0 < length <= MAX_FRAME:
        raise ValueError("Invalid frame length")
    body = sys.stdin.buffer.read(length)
    if len(body) != length:
        raise EOFError("Incomplete frame")
    return json.loads(body)


class Store:
    """Atomic manifests plus OS leases: only our exact SDK records are deleted."""
    def __init__(self, root):
        self.root = root
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.record = None
        self.lease = None
        for path in root.glob("*.json"):
            lock = path.with_suffix(".lock").open("a+")
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                item = json.loads(path.read_text())
                if not item["saved"]:
                    self.remove(item)
            except BlockingIOError:
                pass
            finally:
                lock.close()

    def write(self):
        path = self.root / (self.record["id"] + ".json")
        temp = path.with_suffix(".pending")
        temp.write_text(encoded(self.record))
        temp.chmod(0o600)
        temp.replace(path)

    def remove(self, item):
        if item.get("sdk_id"):
            try:
                delete_session(item["sdk_id"], directory=item["cwd"])
            except FileNotFoundError:
                pass
        (self.root / (item["id"] + ".json")).unlink(missing_ok=True)

    def release(self):
        if self.record and not self.record["saved"]:
            self.remove(self.record)
        if self.lease:
            self.lease.close()
        self.record = self.lease = None

    def activate(self, saved=None, sticky=False, config=None):
        ident = saved or str(uuid.uuid4())
        if not re.fullmatch(r"[0-9a-f-]{36}", ident):
            raise ValueError("Invalid conversation ID")
        if self.record and self.record["id"] == ident:
            return self.record
        lease = (self.root / (ident + ".lock")).open("a+")
        try:
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            lease.close()
            raise ValueError("Conversation is open in another editor")
        if saved:
            item = json.loads((self.root / (ident + ".json")).read_text())
            if not item["saved"]:
                lease.close()
                raise ValueError("Conversation is not saved")
        else:
            cwd = self.root / ident
            cwd.mkdir(mode=0o700, exist_ok=True)
            item = dict(id=ident, sdk_id=str(uuid.uuid4()), started=time.time(),
                        last=0, first_prompt="", saved=sticky, cwd=str(cwd),
                        config=dict(config), transcript=[], cumulative={})
        self.release()
        self.record, self.lease = item, lease
        self.write()
        return item

    def listing(self):
        rows = []
        for path in self.root.glob("*.json"):
            item = json.loads(path.read_text())
            if item["saved"]:
                title = time.strftime("%y:%m:%d:%H:%M:%S", time.localtime(item["started"]))
                rows.append(dict(id=item["id"], title=title + " - " + item["first_prompt"][:80], started=item["started"]))
        return sorted(rows, key=lambda x: x["started"], reverse=True)


class Bridge:
    def __init__(self, state):
        self.store = Store(state / "conversations")
        self.config = dict(model="claude-haiku-5-5", effort="low", context_limit_tokens=100000)
        self.prompt = DEFAULT_PROMPT.read_text()
        self.client = None
        self.metadata = {}
        self.context = {}
        self.baselines = {}
        self.sticky = False
        self.canceled = False
        self.busy = False
        self.queue = asyncio.Queue()
        self.cli = Path(claude_agent_sdk.__file__).parent / "_bundled" / "claude"
        self.versions = dict(python=sys.version.split()[0], sdk=importlib.metadata.version("claude-agent-sdk"))
        self.cache_ttl = 300
        self.cache_provenance = "estimated conservative five-minute TTL; billing mode not yet known"

    def notify(self, method, **params):
        frame(dict(jsonrpc="2.0", method=method, params=params))

    async def disconnect(self):
        if self.client:
            await self.client.disconnect()
            self.client = None
        self.baselines.clear()

    async def connect(self):
        if self.client:
            return
        record = self.store.record or self.store.activate(sticky=self.sticky, config=self.config)
        env = dict(CLAUDE_CODE_DISABLE_CLAUDE_MDS="1", CLAUDE_CODE_DISABLE_AUTO_MEMORY="1",
                   CLAUDE_CODE_DISABLE_BUNDLED_SKILLS="1", CLAUDE_AGENT_SDK_DISABLE_BUILTIN_AGENTS="1",
                   CLAUDE_CODE_AUTO_CONNECT_IDE="false", CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1",
                   CLAUDE_CODE_DISABLE_ATTACHMENTS="1", CLAUDE_CODE_DISABLE_CRON="1",
                   CLAUDE_CODE_SAFE_MODE="1", DISABLE_AUTO_COMPACT="1",
                   CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK="1",
                   DISABLE_DOCTOR_COMMAND="1",
                   CLAUDE_CODE_PLUGIN_DIRS="", CLAUDE_CODE_EXTRA_BODY="",
                   CLAUDE_CODE_MAX_OUTPUT_TOKENS=str(OUTPUT), CLAUDE_CODE_EFFORT_LEVEL=self.config.get("effort") or "low",
                   CLAUDE_CODE_AUTO_COMPACT_WINDOW=str(max(100000, self.config.get("context_limit_tokens") or 1000000)))
        # Never inherit an API key as a silent subscription fallback.
        if os.environ.get("ANTHROPIC_API_KEY"):
            raise ValueError("ANTHROPIC_API_KEY is set and overrides subscription billing. Unset it to use runtime login; the plugin does not silently opt into API billing.")
        options = ClaudeAgentOptions(
            model=self.config["model"], effort=self.config.get("effort"), thinking={"type":"disabled"},
            tools=[], mcp_servers={}, strict_mcp_config=True, setting_sources=[], agents={}, plugins=[], skills=[],
            system_prompt={"type":"custom", "prompt":self.prompt, "snapshot":False},
            resume=record["sdk_id"] if record["transcript"] else None,
            session_id=None if record["transcript"] else record["sdk_id"],
            cwd=record["cwd"], env=env, max_turns=1, include_partial_messages=True,
            settings=encoded({"disableAllHooks":True, "autoMemoryEnabled":False, "idleCompaction":False,
                              "enabledPlugins":{"cc-plugin-agents-md@builtin":False,"cc-plugin-plugin-authoring@builtin":False}}),
            stderr=lambda text: print(text, file=sys.stderr))
        self.client = ClaudeSDKClient(options)
        try:
            await self.client.connect()
            self.metadata = await self.client.get_server_info() or {}
            self.versions["cli"] = self.metadata.get("claude_code_version", "unknown")
            self.context = await self.client.get_context_usage()
            self.check_isolation()
        except BaseException:
            await self.disconnect()
            raise
        account = self.metadata.get("account", {})
        subscription = account.get("subscriptionType")
        if subscription and not os.environ.get("ANTHROPIC_AUTH_TOKEN"):
            self.cache_ttl = 3600
            self.cache_provenance = "estimated one-hour included-subscription TTL; usage credits can reduce this to five minutes"
        self.store.write()

    def check_isolation(self):
        unexpected = {key:self.context.get(key) for key in
                      ("memoryFiles", "mcpTools", "agents", "systemTools", "deferredBuiltinTools", "mcpInstructions")
                      if self.context.get(key)}
        if unexpected or self.metadata.get("agents"):
            raise ValueError("Runtime exposed unexpected context/tools; refusing request: " + encoded(unexpected))
        version = self.versions.get("cli", "0")
        parts = tuple(int(x) for x in re.findall(r"\d+", version)[:3])
        if parts < (2,1,306):
            raise ValueError("Runtime 2.1.306+ is required for verified verbatim input and context isolation. Run :NvClaude update.")

    def require_safe_budget(self):
        if self.config.get("context_limit_tokens") is not None:
            raise ValueError("Unsupported hard input budget: this SDK/runtime provides estimates but no authoritative final-request count or arbitrary hard input limit. No model request was sent. Keep the cap to refuse requests, or explicitly choose 'model default' in :NvClaude model to proceed without a local pricing ceiling.")

    def info(self):
        record = self.store.record or {}
        context = {k:v for k,v in self.context.items() if k not in ("gridRows", "memoryFiles")}
        return dict(config=self.config, versions=self.versions, conversation=record.get("id"),
                    sdk_session=record.get("sdk_id"), saved=record.get("saved",False), sticky=self.sticky,
                    occupancy=context, cumulative=record.get("cumulative",{}),
                    budget={"policy":"hard local input ceilings are unsupported and refused before dispatch; model default uses conservative physical-window planning", "ceiling":self.config.get("context_limit_tokens"), "runtime_overhead_allowance":OVERHEAD, "provider_verified_hard_ceiling":False},
                    cache={"ttl_seconds":self.cache_ttl, "provenance":self.cache_provenance,
                           "remaining_seconds":max(0, self.cache_ttl - (time.time()-record.get("last",0)))},
                    authentication={"subscription_type":self.metadata.get("account",{}).get("subscriptionType"),
                                    "provider":self.metadata.get("account",{}).get("apiProvider"),
                                    "api_key_environment":bool(os.environ.get("ANTHROPIC_API_KEY"))})

    def envelope(self, p):
        req = {"operation":p["operation"], "instruction":p["instruction"]}
        if req["operation"] not in ("ask", "replace", "generate"):
            raise ValueError("Unknown operation")
        doc = p.get("document")
        if doc:
            ident, text, revision = doc["id"], doc["text"], str(doc["revision"])
            req["document"] = dict(id=ident,filetype=doc.get("filetype",""))
            prev = self.baselines.get(ident)
            context = dict(kind="snapshot", revision=revision, text=text)
            if prev:
                if prev[1] == text:
                    context = dict(kind="unchanged", revision=prev[0])
                else:
                    old, new = prev[1].split("\n"), text.split("\n")
                    first = 0
                    while first < min(len(old),len(new)) and old[first] == new[first]:
                        first += 1
                    tail = 0
                    while tail < min(len(old),len(new))-first and old[-tail-1] == new[-tail-1]:
                        tail += 1
                    patch = dict(kind="diff",base_revision=prev[0],revision=revision,
                                 format="zero-based line splice",start_row=first,
                                 delete_lines=len(old)-first-tail,
                                 insert_lines=new[first:len(new)-tail] if tail else new[first:])
                    if len(encoded(patch)) < len(encoded(context)):
                        context = patch
            req["context"] = context
        if p.get("targets"):
            req["targets"] = p["targets"]
        return req

    def prompt_bound(self, prompt):
        history = self.store.record["transcript"]
        return len(self.prompt.encode()) + len(prompt.encode()) + sum(max(len(encoded(turn).encode()), turn.get("context_tokens",0)) + 256 for turn in history) + OVERHEAD

    async def consume(self, prompt, *, request=None, compact=False):
        async def messages():
            yield {"type":"user", "message":{"role":"user", "content":prompt}, "client_composed":not compact}
        await self.client.query(messages())
        final_text = ""
        streamed = False
        result = None
        compact_boundary = False
        async for event in self.client.receive_response():
            if isinstance(event, SystemMessage):
                if event.subtype == "init" and any(event.data.get(k) for k in ("tools","mcp_servers","agents","skills")):
                    await self.client.interrupt()
                    raise ValueError("Runtime announced tools/agents/skills despite isolation; no edit applied: " + encoded({k:event.data.get(k) for k in ("tools","mcp_servers","agents","skills")}))
                if event.subtype == "compact_boundary":
                    compact_boundary = True
            elif isinstance(event, StreamEvent):
                data = event.event
                if data.get("type") == "content_block_delta" and data.get("delta",{}).get("type") == "text_delta":
                    text = data["delta"]["text"]
                    streamed = True
                    if request and not self.canceled:
                        self.notify("text", request_id=request["request_id"], epoch=request["epoch"], text=text)
            elif isinstance(event, AssistantMessage):
                final_text += "".join(block.text for block in event.content if isinstance(block, TextBlock))
                if event.error:
                    raise ValueError("Claude runtime error: " + str(event.error))
            elif isinstance(event, ResultMessage):
                result = event
        if self.canceled:
            raise ValueError("Request canceled; source unchanged")
        if result is None or result.is_error or result.subtype != "success" or getattr(result,"terminal_reason",None) in ("aborted_streaming","aborted_tools"):
            raise ValueError("Claude request failed: " + (str(result.result) if result else "no completion boundary") + ". Use :NvClaude login if authentication is missing.")
        self.store.record["sdk_id"] = result.session_id
        record = self.store.record
        usage = record.setdefault("cumulative",{}).setdefault("usage",{})
        for key, value in result.usage.items():
            if isinstance(value,(int,float)):
                usage[key] = usage.get(key,0) + value
        record["cumulative"]["cost_usd_runtime_total"] = result.total_cost_usd
        self.last_output_tokens = result.usage.get("output_tokens",OUTPUT)
        if not final_text:
            final_text = result.result or ""
        if request and not streamed and final_text:
            self.notify("text", request_id=request["request_id"],epoch=request["epoch"],text=final_text)
        return final_text, compact_boundary

    async def compact(self):
        await self.connect()
        if not self.store.record["transcript"]:
            raise ValueError("There is no completed context to compact")
        self.require_safe_budget()
        if self.prompt_bound("/compact") + OUTPUT > self.context.get("rawMaxTokens",0):
            raise ValueError("Compaction would exceed physical context planning. Start a new conversation.")
        _, boundary = await self.consume("/compact", compact=True)
        self.baselines.clear()
        if not boundary:
            raise ValueError("Runtime did not announce an actual compact_boundary; compaction not confirmed")
        # Read the SDK's active chain after compaction, not a made-up summary.
        history = get_session_messages(self.store.record["sdk_id"], directory=self.store.record["cwd"])
        self.store.record["transcript"] = [dataclasses.asdict(m) for m in history]
        self.context = await self.client.get_context_usage()
        self.store.write()
        return self.info()

    async def turn(self, p):
        record = self.store.record
        if record and not record["saved"] and record["last"] and time.time()-record["last"] > self.cache_ttl:
            await self.disconnect()
            self.store.release()
        await self.connect()
        self.require_safe_budget()
        record = self.store.record
        req = self.envelope(p)
        payload = encoded(req)
        physical = self.context.get("rawMaxTokens",0)
        if not physical:
            raise ValueError("Unsupported budget: runtime did not report its physical context window")
        ceiling = physical-OUTPUT
        bound = self.prompt_bound(payload)
        # Compact before the next request, while the compact turn still fits.
        if record["transcript"] and bound > ceiling * 0.75:
            self.notify("status", request_id=p["request_id"],epoch=p["epoch"],message="compacting")
            await self.compact()
            req = self.envelope(p)
            payload = encoded(req)
            bound = self.prompt_bound(payload)
        if bound > ceiling:
            # Explicit excerpt is allowed only for local operations, never omit a target.
            if p.get("document") and p.get("targets") and req.get("context",{}).get("kind") == "snapshot" and not re.search(r"\b(?:whole|entire|full)\s+(?:file|document|buffer)\b", p["instruction"],re.I):
                lines = p["document"]["text"].split("\n")
                rows = [t["start"][0] for t in p["targets"]]+[t["end"][0] for t in p["targets"]]
                start, end = max(0,min(rows)-10),min(len(lines),max(rows)+11)
                req["context"] = dict(kind="excerpt",revision=str(p["document"]["revision"]),start_row=start,end_row=end,omitted_before=start,omitted_after=len(lines)-end,text="\n".join(lines[start:end]))
                payload = encoded(req)
                bound = self.prompt_bound(payload)
            if bound > ceiling:
                raise ValueError(f"Request refused before dispatch: conservative prompt bound {bound:,} exceeds {ceiling:,}. Target and instruction were not truncated. Start new, compact, or explicitly choose another budget.")
        self.check_isolation()
        self.notify("status",request_id=p["request_id"],epoch=p["epoch"],message="continued" if record["transcript"] else "new")
        if self.canceled:
            raise ValueError("Request canceled before dispatch; source unchanged")
        started = time.time()
        try:
            text, _ = await self.consume(payload, request=p)
        except BaseException:
            self.baselines.clear()
            # Resume the actual SDK history after an uncertain/canceled turn.
            record["transcript"].append({"uncertain_turn":payload,"context_tokens":len(payload.encode())+OUTPUT})
            record["last"] = started
            self.store.write()
            await self.disconnect()
            raise
        record["transcript"].extend([{"role":"user","content":payload},{"role":"assistant","content":text,"context_tokens":self.last_output_tokens}])
        record["last"] = started
        if not record["first_prompt"]:
            record["first_prompt"] = p["instruction"]
        if p.get("document") and req["context"]["kind"] != "excerpt":
            doc = p["document"]
            self.baselines[doc["id"]] = (str(doc["revision"]),doc["text"])
        self.context = await self.client.get_context_usage()
        self.store.write()
        return dict(text=text,session_id=record["id"],info=self.info())

    async def handle(self, method, p):
        if method == "initialize":
            self.config.update(p.get("config",{}))
            self.config = {k:v for k,v in self.config.items() if v is not None}
            return dict(versions=self.versions,config=self.config,capabilities={"streaming":True,"cancel":True})
        if method == "turn":
            return await self.turn(p)
        if method == "info":
            return self.info()
        if method == "models":
            await self.connect()
            models = []
            for model in self.metadata.get("models",[]):
                models.append(dict(model,display_name=model.get("displayName",model["value"]),supported_efforts=model.get("supportedEffortLevels",[])))
            return dict(models=models,config=self.config,presets=PRESETS)
        if method == "configure":
            candidate = parse_model(p["expression"],self.config,[m["value"] for m in self.metadata.get("models",[])]) if "expression" in p else dict(self.config,**p)
            if candidate.get("context_limit_tokens") is False:
                candidate["context_limit_tokens"] = None
            effort = candidate.get("effort")
            if effort is not None and effort not in EFFORTS:
                raise ValueError("Unsupported effort token")
            announced = next((m for m in self.metadata.get("models",[]) if candidate["model"] in (m.get("value"),m.get("resolvedModel"))),None)
            if announced and effort and effort not in announced.get("supportedEffortLevels",[]):
                raise ValueError("Runtime does not announce that effort for this model")
            if candidate.get("context_limit_tokens") is not None and (not isinstance(candidate["context_limit_tokens"],int) or candidate["context_limit_tokens"] < 1):
                raise ValueError("Budget must be a positive integer or model default")
            await self.disconnect()
            self.config = candidate
            if self.store.record:
                self.store.record["config"] = dict(candidate)
                self.store.write()
            return self.config
        if method == "system":
            await self.disconnect()
            self.prompt = DEFAULT_PROMPT.read_text() if p.get("reset") else p["text"]
            return True
        if method == "login":
            await self.disconnect()
            return dict(argv=[str(self.cli),"auth","login"])
        if method == "session":
            action = p["action"]
            if action == "compact":
                return await self.compact()
            if action == "list":
                return self.store.listing()
            if action in ("new","clear","resume"):
                await self.disconnect()
                if action == "resume":
                    record = self.store.activate(saved=p["id"])
                    self.config = dict(record["config"])
                else:
                    self.store.release()
                    self.store.activate(sticky=self.sticky,config=self.config)
            elif action in ("save","sticky"):
                if action == "sticky":
                    self.sticky = p.get("on",not self.sticky)
                if action == "save" or self.sticky:
                    record = self.store.record or self.store.activate(sticky=self.sticky,config=self.config)
                    record["saved"] = True
                    self.store.write()
            else:
                raise ValueError("Unknown session action")
            return self.info()
        raise ValueError("Unknown method: " + method)

    async def worker(self):
        try:
            while True:
                message = await self.queue.get()
                if message is None:
                    break
                ident, method, p = message.get("id"),message["method"],message.get("params",{})
                self.canceled = False
                try:
                    result = await self.handle(method,p)
                    frame(dict(jsonrpc="2.0",id=ident,result=result))
                except Exception as exc:
                    frame(dict(jsonrpc="2.0",id=ident,error=dict(code=-32000,message=str(exc))))
                finally:
                    if method == "turn":
                        self.busy = False
        finally:
            await self.disconnect()
            self.store.release()

    async def run(self):
        worker = asyncio.create_task(self.worker())
        try:
            while message := await asyncio.to_thread(read_frame):
                method = message.get("method")
                if method == "cancel":
                    self.canceled = True
                    if self.client and self.busy:
                        await self.client.interrupt()
                    frame(dict(jsonrpc="2.0",id=message.get("id"),result=True))
                elif method == "turn" and self.busy:
                    frame(dict(jsonrpc="2.0",id=message.get("id"),error=dict(code=-32001,message="Conversation busy; draft retained")))
                else:
                    if method == "turn":
                        self.busy = True
                    if method == "session" and self.busy:
                        self.canceled = True
                        if self.client:
                            await self.client.interrupt()
                    await self.queue.put(message)
        finally:
            self.canceled = True
            if self.client and self.busy:
                await self.client.interrupt()
            await self.queue.put(None)
            await worker


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state",type=Path,required=True)
    args = parser.parse_args()
    os.umask(0o077)
    asyncio.run(Bridge(args.state).run())


if __name__ == "__main__":
    main()
