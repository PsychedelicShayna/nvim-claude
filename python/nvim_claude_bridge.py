#!/usr/bin/env python3
"""One Neovim instance, one framed stdio bridge. Stdout is protocol only."""
import asyncio
import fcntl
import json
import os
from pathlib import Path
import re
import claude_agent_sdk
import sys
import time
import uuid

from claude_agent_sdk import (
    AssistantMessage, ClaudeAgentOptions, ClaudeSDKClient, ResultMessage,
    StreamEvent, SystemMessage, TextBlock,
)

ROOT = Path(__file__).resolve().parent.parent
PROMPT = (ROOT / "resources" / "system.txt").read_text()
STATE = Path(os.environ.get("NVCLAUDE_STATE", Path.home() / ".local/state/nvim-claude"))
STATE.mkdir(parents=True, exist_ok=True)
MANIFEST = STATE / "sessions.json"
EFFORTS = {"low", "medium", "high", "xhigh", "max"}


def send(message):
    payload = json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode()
    sys.stdout.buffer.write(b"Content-Length: " + str(len(payload)).encode() + b"\r\n\r\n" + payload)
    sys.stdout.buffer.flush()


def receive():
    headers = {}
    while line := sys.stdin.buffer.readline():
        if line in (b"\r\n", b"\n"):
            break
        key, _, value = line.decode("ascii").partition(":")
        headers[key.lower()] = value.strip()
    else:
        return None
    count = int(headers["content-length"])
    if count > 32 * 1024 * 1024:
        raise ValueError("RPC frame exceeds 32 MiB")
    data = sys.stdin.buffer.read(count)
    if len(data) != count:
        return None
    return json.loads(data)


def locked_manifest(change=None):
    with open(STATE / "sessions.lock", "a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            try:
                entries = json.loads(MANIFEST.read_text())
            except FileNotFoundError:
                entries = {}
            if change is not None:
                change(entries)
                temp = MANIFEST.with_name("sessions." + uuid.uuid4().hex + ".tmp")
                temp.write_text(json.dumps(entries, ensure_ascii=False))
                os.replace(temp, MANIFEST)
            return entries
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def remember(entry):
    locked_manifest(lambda entries: entries.__setitem__(entry["id"], entry.copy()))


def forget(entry):
    locked_manifest(lambda entries: entries.pop(entry["id"], None))

def delete_owned(entry):
    """Delete only the transcript with this plugin-recorded session UUID."""
    session = entry.get("session")
    if session and re.fullmatch(r"[0-9a-f-]{36}", session):
        root = Path.home() / ".claude" / "projects"
        if root.is_dir():
            for path in root.rglob(session + ".jsonl"):
                if path.is_file() and path.resolve().is_relative_to(root.resolve()):
                    path.unlink()
    forget(entry)


def cleanup_abandoned():
    for entry in locked_manifest().values():
        if entry.get("saved"):
            continue
        pid = entry.get("owner")
        if pid and pid != os.getpid():
            try:
                os.kill(pid, 0)
                continue
            except ProcessLookupError:
                pass
            except PermissionError:
                continue
        if pid != os.getpid():
            delete_owned(entry)


def fresh(sticky=False):
    return {"id": uuid.uuid4().hex, "session": None, "saved": sticky, "owner": os.getpid(),
            "created": time.time(), "last": 0, "title": "", "usage": {}, "baselines": {}}


def versions():
    from importlib.metadata import version
    import subprocess
    binary = Path(claude_agent_sdk.__file__).parent / "_bundled" / "claude"
    result = subprocess.run([str(binary), "--version"], capture_output=True, text=True, timeout=10)
    auth = subprocess.run([str(binary), "auth", "status"], capture_output=True, text=True, timeout=10)
    try:
        details = json.loads(auth.stdout)
        mode = details.get("authMethod", "unknown")
    except json.JSONDecodeError:
        mode = "unknown"
    return {"python": sys.version.split()[0], "sdk": version("claude-agent-sdk"),
            "cli": result.stdout.strip() or result.stderr.strip(),
            "cli_path": str(binary), "auth": mode}


class Bridge:
    def __init__(self):
        self.config = {"model": "claude-haiku-5-5", "effort": "low", "limit": 100000}
        self.sticky = False
        self.entry = fresh()
        cleanup_abandoned()
        self.client = None
        self.active = None
        self.epoch = 0
        self.server_info = None
        self.system = PROMPT
        self.runtime = versions()
        self.pending = None

    async def close_client(self):
        if self.client is not None:
            client, self.client = self.client, None
            await client.disconnect()

    async def connect(self):
        if self.client:
            return
        if (os.environ.get("ANTHROPIC_API_KEY") or self.runtime["auth"] in ("apiKey", "api-key", "api_key")) and os.environ.get("NVCLAUDE_ALLOW_API_KEY") != "1":
            raise ValueError("API-key billing detected. Unset ANTHROPIC_API_KEY for Claude login, or explicitly set NVCLAUDE_ALLOW_API_KEY=1.")
        options = ClaudeAgentOptions(
            model=self.config["model"], effort=self.config["effort"],
            system_prompt={"type": "custom", "prompt": self.system, "snapshot": False},
            tools=[], allowed_tools=[], mcp_servers={},
            strict_mcp_config=True, setting_sources=[], skills=[], agents={},
            include_partial_messages=True, resume=self.entry["session"],
            # The runtime must not search the source directory for context.
            cwd=str(STATE),
        )
        client = ClaudeSDKClient(options=options)
        await client.connect()
        self.client = client
        self.server_info = await client.get_server_info()
        send({"method": "catalogue", "params": {"server": self.server_info or {},
              "runtime": self.runtime}})

    async def end_active(self):
        self.epoch += 1
        if self.active:
            task = self.active[0]
            self.active = None
            if self.client:
                try:
                    await self.client.interrupt()
                except Exception as exc:
                    print("interrupt:", exc, file=sys.stderr)
            task.cancel()
            try:
                await task
            except (asyncio.CancelledError, Exception):
                pass

    async def transition(self, method, params):
        await self.end_active()
        if method == "save":
            self.entry["saved"] = True
            remember(self.entry)
        elif method == "sticky":
            self.sticky = params.get("enabled", not self.sticky)
            if self.sticky:
                self.entry["saved"] = True
                remember(self.entry)
        elif method in ("new", "clear"):
            # A saved checkpoint remains in the manifest. New turns do not mutate it.
            await self.close_client()
            if not self.entry["saved"]:
                delete_owned(self.entry)
            self.entry = fresh(self.sticky)
        elif method == "resume":
            saved = locked_manifest().get(params.get("id"))
            if not saved or not saved["saved"] or not saved["session"]:
                raise ValueError("Saved session is unavailable")
            await self.close_client()
            self.entry = saved
        elif method == "model":
            config = params["config"]
            if not isinstance(config["model"], str) or not config["model"]:
                raise ValueError("Model ID is required")
            if config.get("effort") is not None and config["effort"] not in EFFORTS:
                raise ValueError("Unrecognized effort")
            limit = config.get("limit")
            if limit is not None and (not isinstance(limit, int) or limit < 1000):
                raise ValueError("Invalid local budget")
            if self.server_info:
                announced = next((item for item in self.server_info.get("models", [])
                    if config["model"] in (item.get("value"), item.get("resolvedModel"))), None)
                if announced and config.get("effort"):
                    levels = announced.get("supportedEffortLevels") or []
                    if config["effort"] not in levels:
                        if params.get("explicit_effort"):
                            raise ValueError("The runtime does not announce this effort for the selected model")
                        config["effort"] = None
            await self.close_client()
            self.config = config
            self.entry["baselines"] = {}
        elif method == "system":
            await self.close_client()  # Reconnect with resume and the new prompt.
            self.system = params.get("text") or PROMPT
            self.entry["baselines"] = {}
        elif method == "compact":
            await self.connect()
            # /compact is a runtime command, not an ordinary edit request.
            await self.client.query("/compact")
            async for message in self.client.receive_response():
                if isinstance(message, ResultMessage) and message.is_error:
                    raise ValueError(message.result or "Compaction failed")
            self.entry["baselines"] = {}
        send({"method": "state", "params": self.status()})

    def status(self):
        return {"config": self.config, "sticky": self.sticky, "saved": self.entry["saved"],
                "session": self.entry["session"], "usage": self.entry["usage"],
                "runtime": self.runtime, "title": self.entry["title"],
                "last": self.entry["last"], "epoch": self.epoch,
                "budget": "conservative byte bound; runtime overhead unverified",
                "cache": "estimated: 1 hour subscription; 5 minutes API/credits"}

    def budget(self, envelope):
        limit = self.config.get("limit")
        if limit is None:
            return
        # Each UTF-8 byte is at most one input token in byte fallback encoding.
        # Reserve runtime overhead and output separately; do not claim proof of a
        # hard ceiling when the SDK does not expose preflight token counting.
        occupied = self.entry["usage"].get("context_tokens", 0)
        bytes_in = len(json.dumps(envelope, ensure_ascii=False).encode()) + len(self.system.encode())
        if occupied + bytes_in + 12000 > limit:
            raise ValueError("Local budget cannot safely contain the next request. Compact or reduce context; no request sent.")

    async def turn(self, request_id, params, epoch):
        text = ""
        seen_stream = False
        result = None
        try:
            ttl = 3600 if self.runtime["auth"] == "claude.ai" else 300
            envelope = params["envelope"]
            if not self.entry["saved"] and self.entry["last"] and time.time() - self.entry["last"] > ttl:
                await self.close_client()
                delete_owned(self.entry)
                self.entry = fresh(self.sticky)
                if envelope.get("context"):
                    if not params.get("fallback_context"):
                        raise ValueError("Expired context needs a fresh snapshot")
                    envelope["context"] = params["fallback_context"]
                send({"method": "state", "params": self.status()})
            await self.connect()
            occupied = self.entry["usage"].get("context_tokens", 0)
            if not (self.entry["session"] and self.config.get("limit") and occupied > self.config["limit"] * .7):
                self.budget(envelope)
            if self.entry["session"] and self.config.get("limit") and occupied > self.config["limit"] * .7:
                if occupied + 12000 >= self.config["limit"]:
                    raise ValueError("Not enough budget to compact safely; start a new conversation")
                send({"method": "status", "params": {"id": request_id, "epoch": epoch, "status": "compacting"}})
                await self.client.query("/compact")
                compact_result = None
                async for message in self.client.receive_response():
                    if isinstance(message, ResultMessage):
                        compact_result = message
                if not compact_result or compact_result.is_error:
                    raise ValueError("Automatic compaction failed")
                self.entry["baselines"] = {}
                fallback = params.get("fallback_context")
                if envelope.get("context") and not fallback:
                    raise ValueError("Compacted file context needs a new snapshot")
                if fallback:
                    envelope["context"] = fallback
                usage = await self.client.get_context_usage()
                self.entry["usage"]["context_tokens"] = usage.get("totalTokens", 0)
                self.budget(envelope)
            send({"method": "status", "params": {"id": request_id, "epoch": epoch,
                  "status": "continued" if self.entry["session"] else "new"}})
            await self.client.query(json.dumps(envelope, ensure_ascii=False))
            async for message in self.client.receive_response():
                if epoch != self.epoch:
                    return
                if isinstance(message, StreamEvent):
                    event = message.event
                    if event.get("type") == "content_block_delta" and event.get("delta", {}).get("type") == "text_delta":
                        chunk = event["delta"]["text"]
                        text += chunk
                        seen_stream = True
                        send({"method": "partial", "params": {"id": request_id, "epoch": epoch, "text": chunk}})
                elif isinstance(message, AssistantMessage) and not seen_stream:
                    text += "".join(block.text for block in message.content if isinstance(block, TextBlock))
                    if message.error:
                        raise ValueError(message.error)
                elif isinstance(message, ResultMessage):
                    result = message
                    if message.is_error:
                        raise ValueError(message.result or "; ".join(message.errors or []) or "SDK request failed")
            if result is None:
                raise ValueError("SDK ended without a successful result")
            if not seen_stream and not text and result.result:
                text = result.result
            self.entry["session"] = result.session_id
            self.entry["last"] = time.time()
            self.entry["title"] = self.entry["title"] or envelope.get("instruction", "")[:80]
            usage = result.usage or {}
            input_count = sum(usage.get(k, 0) for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))
            self.entry["usage"] = {"context_tokens": input_count,
                "cumulative": usage, "cost_usd": result.total_cost_usd}
            remember(self.entry)
            send({"method": "result", "params": {"id": request_id, "epoch": epoch,
                  "text": text, "session": result.session_id, "usage": self.entry["usage"]}})
        except asyncio.CancelledError:
            send({"method": "cancelled", "params": {"id": request_id, "epoch": epoch}})
        except Exception as exc:
            self.entry["baselines"] = {}
            send({"method": "error", "params": {"id": request_id, "epoch": epoch, "message": str(exc)}})
        finally:
            if self.active and self.active[0] is asyncio.current_task():
                self.active = None

    async def handle(self, message):
        method, params = message["method"], message.get("params") or {}
        request_id = message.get("id")
        try:
            if method == "initialize":
                value = self.status()
            elif method == "request":
                if self.active:
                    raise ValueError("Conversation busy; draft retained")
                self.epoch += 1
                self.active = (asyncio.create_task(self.turn(request_id, params, self.epoch)), request_id)
                value = {"epoch": self.epoch}
            elif method == "cancel":
                await self.end_active()
                value = self.status()
            elif method == "list":
                value = sorted((e for e in locked_manifest().values() if e.get("saved") and e.get("session")),
                               key=lambda e: e["created"], reverse=True)
            elif method == "info":
                value = self.status()
                if self.client:
                    try:
                        value["context"] = await self.client.get_context_usage()
                    except Exception as exc:
                        value["context_error"] = str(exc)
            elif method in ("new", "clear", "save", "sticky", "resume", "model", "system", "compact"):
                await self.transition(method, params)
                value = self.status()
            elif method == "catalogue":
                await self.connect()
                value = self.server_info
            else:
                raise ValueError("Unknown method: " + str(method))
            if request_id is not None and method != "request":
                send({"jsonrpc": "2.0", "id": request_id, "result": value})
            elif request_id is not None:
                send({"jsonrpc": "2.0", "id": request_id, "result": value})
        except Exception as exc:
            if request_id is not None:
                send({"jsonrpc": "2.0", "id": request_id, "error": {"message": str(exc)}})

    async def run(self):
        try:
            while message := await asyncio.to_thread(receive):
                await self.handle(message)
        finally:
            await self.end_active()
            await self.close_client()
            if not self.entry["saved"]:
                delete_owned(self.entry)


if __name__ == "__main__":
    asyncio.run(Bridge().run())
