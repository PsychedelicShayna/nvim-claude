"""Private JSON-RPC stdio bridge for nvim-claude. Stdout is protocol-only."""

from __future__ import annotations

import asyncio
import difflib
import fcntl
import importlib.metadata
import json
import os
from pathlib import Path
import re
import sqlite3
import sys
import time
import uuid

import claude_agent_sdk
from claude_agent_sdk import ClaudeAgentOptions, ClaudeSDKClient, delete_session
from claude_agent_sdk.types import AssistantMessage, ResultMessage, StreamEvent, SystemMessage, TextBlock

ROOT = Path(__file__).resolve().parent.parent
PROMPT = (ROOT / "resources" / "system.txt").read_text()
EFFORTS = {"low", "medium", "high", "xhigh", "max"}
BUDGET = 100_000
# Conservative reservation for CLI additions, tokenizer uncertainty and completion.
OVERHEAD = 16_384


def expression(value: str, current: dict) -> dict:
    """Parse the local budget suffix without changing native model selectors."""
    value = value.strip()
    if not value:
        raise ValueError("Enter a model ID")
    out = dict(current)
    head, sep, suffix = value.rpartition(":")
    if sep and suffix in EFFORTS:
        value, out["effort"] = head, suffix
    match = re.search(r"\[(?:limit=)?([1-9][0-9]*)([km]?)\]$", value, re.I)
    if match:
        number = int(match.group(1)) * {"": 1, "k": 1000, "m": 1_000_000}[match.group(2).lower()]
        prefix = value[: match.start()]
        # The documented [1m] suffix of Opus is a native model variant.
        if match.group(0).lower().startswith("[limit=") or not (match.group(0).lower() == "[1m]" and "opus" in prefix):
            out["context_limit_tokens"] = number
            value = prefix
    if not value:
        raise ValueError("Missing runtime model ID")
    out["model"] = value
    return out


def edit_result(raw: str, targets: list[dict]) -> dict:
    try:
        result = json.loads(raw)
    except (ValueError, TypeError) as exc:
        raise ValueError("The edit reply is not a JSON object") from exc
    if not isinstance(result, dict):
        raise ValueError("The edit reply is not a JSON object")
    if result.get("status") == "needs_input" and isinstance(result.get("message"), str) and not result.get("replacements"):
        return result
    if result.get("status") != "ok" or not isinstance(result.get("replacements"), list):
        raise ValueError("Invalid edit status or replacements")
    ids = [target["id"] for target in targets]
    items = result["replacements"]
    if len(items) != len(ids) or any(not isinstance(item, dict) or not isinstance(item.get("id"), str) or not isinstance(item.get("text"), str) for item in items):
        raise ValueError("Missing or invalid target replacement")
    if set(item["id"] for item in items) != set(ids) or len({item["id"] for item in items}) != len(items):
        raise ValueError("Replacement IDs must match the selected targets exactly")
    if any("\n" in item["text"] or "\r" in item["text"] for item in items if next(t for t in targets if t["id"] == item["id"]).get("block")):
        raise ValueError("Blockwise replacements must stay on their original rows")
    return result


class TranscriptStore:
    """Only transcripts mirrored from this bridge are stored here."""

    def __init__(self, path: Path):
        self.path = path
        path.parent.mkdir(parents=True, exist_ok=True)
        with sqlite3.connect(path) as db:
            db.execute("CREATE TABLE IF NOT EXISTS lines (session TEXT, project TEXT, ord INTEGER PRIMARY KEY AUTOINCREMENT, payload TEXT)")
            db.execute("CREATE INDEX IF NOT EXISTS lines_session ON lines(session, project)")

    async def append(self, key: dict, entries: list[dict]) -> None:
        def work():
            with sqlite3.connect(self.path) as db:
                db.executemany("INSERT INTO lines(session,project,payload) VALUES(?,?,?)", ((key["session_id"], key["project_key"], json.dumps(e, ensure_ascii=False)) for e in entries))
        await asyncio.to_thread(work)

    async def load(self, key: dict) -> list[dict] | None:
        def work():
            with sqlite3.connect(self.path) as db:
                return [json.loads(row[0]) for row in db.execute("SELECT payload FROM lines WHERE session=? AND project=? ORDER BY ord", (key["session_id"], key["project_key"]))]
        rows = await asyncio.to_thread(work)
        return rows or None

    async def delete(self, key: dict) -> None:
        def work():
            with sqlite3.connect(self.path) as db:
                db.execute("DELETE FROM lines WHERE session=? AND project=?", (key["session_id"], key["project_key"]))
        await asyncio.to_thread(work)


class Bridge:
    def __init__(self, data: Path):
        self.data = data
        data.mkdir(parents=True, exist_ok=True)
        self.store = TranscriptStore(data / "sessions.sqlite3")
        self.manifest_path = data / "manifest.json"
        self.manifest = self.load_manifest()
        self.deleted: set[str] = set()
        self.active: dict | None = None
        self.client: ClaudeSDKClient | None = None
        self.busy: asyncio.Task | None = None
        self.epoch = 0
        self.prompt = PROMPT
        self.config = {"model": "claude-haiku-5-5", "effort": "low", "context_limit_tokens": BUDGET}
        self.cli = Path(claude_agent_sdk.__file__).parent / "_bundled" / ("claude.exe" if os.name == "nt" else "claude")
        self.sticky = False
        self.info: dict = {}
        self.send_lock = asyncio.Lock()

    def load_manifest(self):
        try:
            return json.loads(self.manifest_path.read_text())
        except (FileNotFoundError, ValueError):
            return {"conversations": {}}

    def save_manifest(self):
        # Multiple editors share this directory. Merge only our active record and
        # explicit removals, never replace another live editor's manifest entries.
        with (self.data / "manifest.lock").open("a+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            merged = self.load_manifest()
            for ident in self.deleted:
                merged["conversations"].pop(ident, None)
            self.deleted.clear()
            if self.active:
                merged["conversations"][self.active["id"]] = self.active
            temp = self.data / f"manifest.{os.getpid()}.{uuid.uuid4().hex}.new"
            temp.write_text(json.dumps(merged, ensure_ascii=False))
            os.replace(temp, self.manifest_path)
            self.manifest = merged

    async def clean_abandoned(self):
        self.manifest = self.load_manifest()
        for conv in list(self.manifest["conversations"].values()):
            if conv["saved"] or conv["owner_pid"] == os.getpid():
                continue
            try:
                os.kill(conv["owner_pid"], 0)
            except ProcessLookupError:
                await self.drop(conv)
            except PermissionError:
                pass

    async def send(self, message: dict):
        packet = json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode()
        async with self.send_lock:
            sys.stdout.buffer.write(b"Content-Length: " + str(len(packet)).encode() + b"\r\n\r\n" + packet)
            sys.stdout.buffer.flush()

    async def event(self, request: str, epoch: int, kind: str, **fields):
        await self.send({"jsonrpc": "2.0", "method": "event", "params": {"request": request, "epoch": epoch, "type": kind, **fields}})

    def new_conversation(self):
        conv = {"id": str(uuid.uuid4()), "session": None, "created": time.time(), "last": None,
                "title": "", "saved": self.sticky, "config": dict(self.config), "baselines": {},
                "usage": {}, "occupancy": None, "ttl": 300, "owner_pid": os.getpid()}
        self.manifest["conversations"][conv["id"]] = conv
        self.active = conv
        self.save_manifest()
        return conv

    async def drop(self, conv: dict):
        if conv["saved"]:
            return
        session = conv.get("session")
        if session:
            from claude_agent_sdk import project_key_for_directory
            await self.store.delete({"project_key": project_key_for_directory(self.data), "session_id": session})
            try:
                await asyncio.to_thread(delete_session, session, str(self.data))
            except FileNotFoundError:
                pass
        self.manifest["conversations"].pop(conv["id"], None)
        self.deleted.add(conv["id"])
        self.save_manifest()

    async def close_client(self):
        if self.client:
            client, self.client = self.client, None
            await client.disconnect()

    def options(self, resume=None):
        # Do not add a user/project settings source or a single tool, including Skill.
        return ClaudeAgentOptions(
            tools=[], allowed_tools=[], mcp_servers={}, strict_mcp_config=True,
            setting_sources=[], skills=[], plugins=[], agents={},
            model=self.config["model"], effort=self.config.get("effort"),
            fallback_model=None, system_prompt={"type": "custom", "prompt": self.prompt, "snapshot": False},
            include_partial_messages=True, resume=resume, session_store=self.store,
            cwd=str(self.data),
        )

    async def connect(self):
        if self.client:
            return self.client
        client = ClaudeSDKClient(self.options(self.active.get("session") if self.active else None))
        await client.connect()
        self.client = client
        self.info = await client.get_server_info() or {}
        return client

    async def transition(self, kind: str, value=None):
        await self.cancel()
        await self.close_client()
        self.epoch += 1
        old = self.active
        self.manifest = self.load_manifest()
        if kind == "resume":
            conv = self.manifest["conversations"].get(value)
            if not conv or not conv["saved"]:
                raise ValueError("Saved conversation not found")
            self.active = conv
            self.config = dict(conv["config"])
        elif kind == "clear" and old and old["saved"]:
            self.new_conversation()
        else:
            self.new_conversation()
        if old and old is not self.active:
            await self.drop(old)
        return self.state()

    async def cancel(self):
        if not self.busy or self.busy.done():
            return False
        self.epoch += 1
        task = self.busy
        if self.client:
            try:
                await self.client.interrupt()
            except Exception as exc:
                print(f"Interrupt failed: {exc}", file=sys.stderr)
        task.cancel()
        try:
            await task
        except (asyncio.CancelledError, Exception):
            pass
        self.busy = None
        if self.active:
            self.active["baselines"] = {}
        return True

    def state(self):
        conv = self.active
        return {"epoch": self.epoch, "conversation": conv["id"] if conv else None,
                "saved": bool(conv and conv["saved"]), "sticky": self.sticky,
                "config": self.config, "occupancy": conv.get("occupancy") if conv else None,
                "usage": conv.get("usage") if conv else {}, "runtime": self.info,
                "sdk": importlib.metadata.version("claude-agent-sdk"),
                "cache": f"Estimated prefix TTL: {conv.get('ttl', 300) if conv else 300}s since last completed turn; not proof of a live cache entry.",
                "budget": "Conservative preflight estimate, not a verified runtime-enforced ceiling",
                "cli": str(self.cli) if self.cli.is_file() else None}

    async def budget(self, client, payload: str) -> bool:
        limit = self.config.get("context_limit_tokens")
        if not limit:
            return False
        if limit <= OVERHEAD:
            raise ValueError("Local budget is smaller than the runtime overhead reservation")
        # UTF-8 bytes are a cautious input proxy, but the CLI does not expose
        # a request-size hard stop. Never describe this as a proven ceiling.
        required = len(payload.encode()) + len(self.prompt.encode()) + OVERHEAD
        if required >= limit:
            raise ValueError("The instruction and selected context cannot fit in an empty conversation at this budget")
        try:
            usage = await client.get_context_usage()
        except Exception as exc:
            raise ValueError("Cannot measure current context; request refused") from exc
        occupancy = usage.get("totalTokens")
        if not isinstance(occupancy, int) or occupancy < 0:
            raise ValueError("Runtime did not provide context occupancy")
        if self.active:
            self.active["occupancy"] = usage
        if occupancy + required < limit:
            return False
        if occupancy + 2 * OVERHEAD >= limit:
            raise ValueError("Too close to the budget to compact safely; start a new conversation or change the limit")
        return True

    async def compact_runtime(self, client):
        await client.query("/compact")
        completed = False
        async for message in client.receive_response():
            if isinstance(message, ResultMessage):
                if message.is_error:
                    raise ValueError(f"Runtime compaction failed: {message.errors or message.result}")
                completed = True
        if not completed:
            raise ValueError("Runtime did not confirm the compaction request")
        if self.active:
            self.active["baselines"] = {}
            self.save_manifest()

    def context(self, request: dict) -> dict:
        document = request.get("document")
        if not document:
            return {"operation": request["operation"], "instruction": request["instruction"]}
        source = request["text"]
        rev = request["revision"]
        previous = self.active["baselines"].get(document["id"]) if self.active else None
        snapshot = {"kind": "snapshot", "revision": rev, "text": source}
        limit = self.config.get("context_limit_tokens")
        allowance = max(0, (limit or 1_000_000) - 2 * OVERHEAD - len(self.prompt.encode()) - len(request["instruction"].encode()))
        if limit and len(source.encode()) > allowance and request.get("targets"):
            lines = source.splitlines(keepends=True)
            lo = min(target["start"][0] for target in request["targets"])
            hi = max(target["end"][0] for target in request["targets"]) + 1
            lo, hi = max(0, lo), min(len(lines), hi)
            if len("".join(lines[lo:hi]).encode()) > allowance:
                raise ValueError("The selected target alone exceeds the context budget")
            while lo > 0 and len("".join(lines[lo - 1:hi]).encode()) <= allowance:
                lo -= 1
            while hi < len(lines) and len("".join(lines[lo:hi + 1]).encode()) <= allowance:
                hi += 1
            snapshot = {"kind": "excerpt", "revision": rev, "text": "".join(lines[lo:hi]),
                        "first_row": lo, "end_row": hi, "total_rows": len(lines),
                        "omitted_before": lo > 0, "omitted_after": hi < len(lines)}
        if previous and previous["revision"] == rev and previous["text"] == source:
            context = {"kind": "unchanged", "revision": rev}
        elif previous:
            diff = "".join(difflib.unified_diff(previous["text"].splitlines(keepends=True), source.splitlines(keepends=True), fromfile=previous["revision"], tofile=rev))
            context = {"kind": "diff", "base_revision": previous["revision"], "revision": rev, "text": diff} if len(diff) < len(snapshot["text"]) else snapshot
        else:
            context = snapshot
        return {"operation": request["operation"], "instruction": request["instruction"],
                "document": document, "context": context, "targets": request.get("targets", []),
                "coordinates": "zero-based UTF-8 bytes; end-exclusive"}

    async def run(self, request_id: str, epoch: int, request: dict):
        operation = request["operation"]
        conv = self.active
        try:
            client = await self.connect()
            envelope = self.context(request)
            text = json.dumps(envelope, ensure_ascii=False)
            if await self.budget(client, text):
                await self.event(request_id, epoch, "status", message="compacting")
                await self.compact_runtime(client)
                envelope = self.context(request)
                text = json.dumps(envelope, ensure_ascii=False)
                if await self.budget(client, text):
                    raise ValueError("Conversation remains above the requested budget after compaction")
            await self.event(request_id, epoch, "status", message="continued" if conv.get("session") else "new")
            # client_composed prevents @file expansion and slash-command dispatch in data.
            async def prompt():
                yield {"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": text}]}, "client_composed": True}
            await client.query(prompt())
            chunks = []
            final = None
            result = None
            session = None
            async for message in client.receive_response():
                if epoch != self.epoch:
                    return
                if isinstance(message, StreamEvent):
                    event = message.event
                    delta = event.get("delta", {})
                    if event.get("type") == "content_block_delta" and delta.get("type") == "text_delta":
                        chunk = delta.get("text", "")
                        chunks.append(chunk)
                        if operation == "ask":
                            await self.event(request_id, epoch, "partial", text=chunk)
                elif isinstance(message, AssistantMessage):
                    if message.parent_tool_use_id is not None or any(type(b).__name__.endswith("ToolUseBlock") for b in message.content):
                        raise ValueError("Runtime exposed a tool despite the no-tools configuration")
                    final = "".join(block.text for block in message.content if isinstance(block, TextBlock))
                elif isinstance(message, SystemMessage) and message.subtype == "init":
                    tools = message.data.get("tools", [])
                    if tools:
                        raise ValueError(f"Runtime unexpectedly exposed tools: {tools}")
                    session = message.data.get("session_id")
                elif isinstance(message, ResultMessage):
                    result = message
                    session = message.session_id
            if result is None or result.is_error:
                raise ValueError("Runtime did not complete successfully" + (f": {result.errors or result.result}" if result else ""))
            raw = final if final is not None else result.result if result.result is not None else "".join(chunks)
            if not isinstance(raw, str):
                raise ValueError("Missing assistant text")
            if session:
                conv["session"] = session
            if not conv["title"]:
                conv["title"] = request["instruction"].splitlines()[0][:96]
            conv["last"] = time.time()
            conv["usage"] = result.usage or {}
            creation = conv["usage"].get("cache_creation") or {}
            conv["ttl"] = 3600 if creation.get("ephemeral_1h_input_tokens", 0) else 300
            try:
                conv["occupancy"] = await client.get_context_usage()
            except Exception:
                conv["occupancy"] = None
            if request.get("document"):
                document = request["document"]
                conv["baselines"][document["id"]] = {"revision": request["revision"], "text": request["text"]}
            self.save_manifest()
            if operation == "ask":
                await self.event(request_id, epoch, "complete", raw=raw, usage=conv["usage"])
            else:
                try:
                    parsed = edit_result(raw, request.get("targets", []))
                except ValueError as exc:
                    await self.event(request_id, epoch, "error", message=str(exc), raw=raw)
                else:
                    await self.event(request_id, epoch, "complete", result=parsed, raw=raw, usage=conv["usage"])
        except asyncio.CancelledError:
            await self.event(request_id, epoch, "canceled")
            raise
        except Exception as exc:
            if conv:
                conv["baselines"] = {}
            await self.event(request_id, epoch, "error", message=str(exc))
        finally:
            if self.busy is asyncio.current_task():
                self.busy = None

    async def handle(self, method: str, params: dict):
        if method == "initialize":
            await self.clean_abandoned()
            return {"version": 1, "capabilities": ["ask", "replace", "generate", "sessions", "streaming"], **self.state()}
        if method == "state":
            return self.state()
        if method == "configure":
            if self.busy:
                raise ValueError("Finish or cancel the active request before changing models")
            new = expression(params["expression"], self.config) if "expression" in params else {**self.config, **params}
            if new.get("effort") not in EFFORTS and new.get("effort") is not None:
                raise ValueError("Unrecognized effort")
            await self.close_client()
            self.config = new
            if self.active:
                self.active["config"] = dict(new)
                self.active["baselines"] = {}
            self.save_manifest()
            return self.state()
        if method == "models":
            client = await self.connect()
            self.info = await client.get_server_info() or {}
            return {"models": self.info.get("models", []), "runtime": self.info}
        if method == "begin":
            if self.busy and not self.busy.done():
                raise ValueError("Conversation busy; your draft has not been submitted")
            if self.active and not self.active["saved"] and self.active["last"] and time.time() - self.active["last"] > self.active.get("ttl", 300):
                await self.transition("new")
            if self.active is None:
                self.new_conversation()
            self.epoch += 1
            epoch = self.epoch
            request_id = str(params["request"])
            self.busy = asyncio.create_task(self.run(request_id, epoch, params))
            return {"epoch": epoch, "request": request_id}
        if method == "cancel":
            return {"canceled": await self.cancel(), **self.state()}
        if method in ("new", "clear", "resume"):
            return await self.transition(method, params.get("id"))
        if method == "save":
            if not self.active:
                self.new_conversation()
            self.active["saved"] = True
            self.save_manifest()
            return self.state()
        if method == "sticky":
            self.sticky = params.get("enabled", not self.sticky)
            if self.sticky and self.active:
                self.active["saved"] = True
            self.save_manifest()
            return self.state()
        if method == "list":
            self.manifest = self.load_manifest()
            return sorted(({"id": c["id"], "created": c["created"], "title": c["title"], "model": c["config"]["model"]} for c in self.manifest["conversations"].values() if c["saved"]), key=lambda c: c["created"], reverse=True)
        if method == "system_get":
            return {"text": self.prompt, "default": self.prompt == PROMPT}
        if method == "system":
            if self.busy:
                raise ValueError("Prompt cannot change during a request")
            self.prompt = params.get("text") or PROMPT
            await self.close_client()
            return {"text": self.prompt, "default": self.prompt == PROMPT}
        if method == "compact":
            if self.busy:
                raise ValueError("Conversation busy")
            # The bundled runtime processes /compact as a command, not a user edit.
            client = await self.connect()
            await self.compact_runtime(client)
            return self.state()
        raise ValueError(f"Unknown method: {method}")


async def read_frame():
    def read():
        headers = {}
        while True:
            line = sys.stdin.buffer.readline()
            if not line:
                return None
            if line in (b"\r\n", b"\n"):
                break
            key, _, value = line.partition(b":")
            headers[key.strip().lower()] = value.strip()
        size = int(headers.get(b"content-length", b"0"))
        if not 0 < size <= 16_000_000:
            raise ValueError("Invalid message length")
        body = sys.stdin.buffer.read(size)
        if len(body) != size:
            return None
        return json.loads(body)
    return await asyncio.to_thread(read)


async def main():
    if len(sys.argv) != 2:
        raise SystemExit("Usage: bridge.py <plugin-data-dir>")
    bridge = Bridge(Path(sys.argv[1]))
    while (request := await read_frame()) is not None:
        if "id" not in request:
            continue
        try:
            result = await bridge.handle(request["method"], request.get("params") or {})
            reply = {"jsonrpc": "2.0", "id": request["id"], "result": result}
        except Exception as exc:
            reply = {"jsonrpc": "2.0", "id": request["id"], "error": {"code": -32000, "message": str(exc)}}
        await bridge.send(reply)
    await bridge.cancel()
    await bridge.close_client()
    if bridge.active:
        await bridge.drop(bridge.active)


if __name__ == "__main__":
    asyncio.run(main())
