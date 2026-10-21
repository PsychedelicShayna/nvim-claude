"""One-instance JSON-RPC bridge. Stdout is reserved for Content-Length frames."""
import asyncio
import importlib.metadata
import json
from pathlib import Path
import sys
import time
from claude_agent_sdk import (
    AssistantMessage, ClaudeAgentOptions, ClaudeSDKClient, ResultMessage,
    StreamEvent, SystemMessage, TextBlock,
)

ROOT = Path(__file__).resolve().parents[1]
STATE = Path(sys.argv[1])
STATE.mkdir(parents=True, exist_ok=True)
MANIFEST = STATE / "sessions.json"
SYSTEM = (ROOT / "resources/system.txt").read_text()
EFFORTS = {"low", "medium", "high", "xhigh", "max"}


def send(message):
    payload = json.dumps(message, ensure_ascii=False).encode()
    sys.stdout.buffer.write(b"Content-Length: " + str(len(payload)).encode() + b"\r\n\r\n" + payload)
    sys.stdout.buffer.flush()


def load_manifest():
    try:
        return json.loads(MANIFEST.read_text())
    except (FileNotFoundError, ValueError):
        return {}


def save_manifest(records):
    temporary = MANIFEST.with_suffix(".new")
    temporary.write_text(json.dumps(records, ensure_ascii=False))
    temporary.replace(MANIFEST)


class Bridge:
    def __init__(self):
        self.records = load_manifest()
        self.client = None
        self.session = None
        self.active = None
        self.epoch = 0
        self.config = {"model": "claude-haiku-5-5", "effort": "low", "limit": 100000}
        self.prompt = SYSTEM
        self.server = {}
        self.usage = None
        self.last_turn = 0
        self.sticky = False
        self.baselines = {}
        self.occupancy = 0

    async def stop(self):
        if self.active:
            self.active.cancel()
            self.active = None
        if self.client:
            await self.client.disconnect()
            self.client = None

    def record(self):
        if not self.session:
            return
        old = self.records.get(self.session, {})
        old.update({"id": self.session, "model": self.config.copy(), "last": self.last_turn,
                    "saved": old.get("saved", False) or self.sticky, "title": old.get("title", "")})
        self.records[self.session] = old
        save_manifest(self.records)

    async def connect(self):
        if self.client:
            return
        opts = ClaudeAgentOptions(
            model=self.config["model"], effort=self.config["effort"],
            tools=[], allowed_tools=[], mcp_servers={}, strict_mcp_config=True,
            setting_sources=[], skills=[], plugins=[], agents={},
            system_prompt={"type": "custom", "prompt": self.prompt, "snapshot": False},
            include_partial_messages=True, cwd=STATE, resume=self.session,
        )
        self.client = ClaudeSDKClient(opts)
        await self.client.connect()
        self.server = await self.client.get_server_info() or {}
        send({"method": "capabilities", "params": {"server": self.server,
              "sdk": importlib.metadata.version("claude-agent-sdk")}})

    async def cancel(self):
        self.epoch += 1
        if self.active:
            self.active.cancel()
            self.active = None
        if self.client:
            try:
                await self.client.interrupt()
            except Exception as exc:
                print(f"interrupt failed: {exc}", file=sys.stderr)

    async def dispatch(self, request):
        ident = request.get("id")
        method = request.get("method")
        args = request.get("params") or {}
        if method == "cancel":
            await self.cancel()
            send({"id": ident, "result": {"epoch": self.epoch}})
            return
        if method == "turn":
            if self.active:
                send({"id": ident, "error": "Conversation busy; draft preserved"})
                return
            self.active = asyncio.create_task(self.turn(ident, args, self.epoch))
            self.active.add_done_callback(lambda _: setattr(self, "active", None))
            return
        if self.active:
            send({"id": ident, "error": "Conversation busy; cancel or finish this turn first"})
            return
        try:
            if method in ("new", "clear"):
                await self.stop()
                self.session, self.baselines, self.occupancy = None, {}, 0
                self.epoch += 1
                result = {"epoch": self.epoch}
            elif method == "save":
                if not self.session:
                    raise ValueError("No completed session to save")
                self.record()
                self.records[self.session]["saved"] = True
                save_manifest(self.records)
                result = {"session": self.session}
            elif method == "sticky":
                self.sticky = bool(args["enabled"])
                if self.sticky and self.session:
                    self.record()
                result = {"sticky": self.sticky}
            elif method == "list":
                result = sorted((v for v in self.records.values() if v.get("saved")),
                                key=lambda v: v.get("last", 0), reverse=True)
            elif method == "resume":
                target = args["session"]
                entry = self.records.get(target)
                if not entry or not entry.get("saved"):
                    raise ValueError("Unknown saved session")
                await self.stop()
                self.session = target
                self.config = entry["model"]
                self.baselines, self.occupancy = {}, 0
                self.epoch += 1
                result = {"epoch": self.epoch, "model": self.config}
            elif method == "configure":
                config = args["config"]
                if not isinstance(config.get("model"), str) or not config["model"]:
                    raise ValueError("Model slug required")
                if config.get("effort") is not None and config["effort"] not in EFFORTS:
                    raise ValueError("Unknown effort")
                if config.get("limit") is not None and (not isinstance(config["limit"], int) or config["limit"] < 1):
                    raise ValueError("Invalid token budget")
                await self.stop()
                self.config = config
                self.baselines = {}
                result = self.config
            elif method == "system":
                await self.stop()
                self.prompt = args.get("prompt") or SYSTEM
                self.baselines = {}
                result = {"changed": True}
            elif method == "info":
                await self.connect()
                try:
                    context = await self.client.get_context_usage()
                    self.occupancy = context.get("totalTokens", 0)
                except Exception:
                    context = None
                result = {"config": self.config, "session": self.session,
                          "saved": bool(self.records.get(self.session, {}).get("saved")),
                          "sticky": self.sticky, "last": self.last_turn,
                          "occupancy_estimate": self.occupancy, "context": context,
                          "usage": self.usage, "server": self.server,
                          "sdk": importlib.metadata.version("claude-agent-sdk"),
                          "cli": self.server.get("claude_code_version"),
                          "auth": self.server.get("account"),
                          "budget_enforced": False}
            elif method == "compact":
                await self.connect()
                await self.client.query("/compact")
                result = None
                async for msg in self.client.receive_response():
                    if isinstance(msg, ResultMessage):
                        if msg.is_error:
                            raise RuntimeError(msg.result or str(msg.errors))
                        result = msg.result
                self.baselines = {}
                self.occupancy = 0
            else:
                raise ValueError("Unknown method: " + str(method))
            send({"id": ident, "result": result})
        except Exception as exc:
            send({"id": ident, "error": str(exc)})

    async def turn(self, ident, payload, epoch):
        try:
            # The SDK reports occupied context, but does not expose an exact
            # preflight count for the next runtime-expanded request. Refuse
            # inputs whose UTF-8 byte upper estimate plus reserved runtime
            # overhead would approach the chosen local ceiling.
            limit = self.config.get("limit")
            now = time.time()
            if self.session and not self.records.get(self.session, {}).get("saved") and now - self.last_turn > 300:
                await self.stop()
                self.session, self.baselines, self.occupancy = None, {}, 0
                self.epoch += 1
                epoch = self.epoch
            await self.connect()
            data = payload["input"]
            document = data.get("document")
            if document:
                key = document["id"]
                context = data.get("context")
                if context and context.get("kind") in ("diff", "unchanged") and self.baselines.get(key) != context.get("base_revision", context.get("revision")):
                    raise ValueError("Context baseline unavailable; retry with a snapshot")
            encoded = json.dumps(data, ensure_ascii=False)
            if limit is not None:
                usage = await self.client.get_context_usage()
                occupied = int(usage.get("totalTokens", 0))
                if occupied + len(encoded.encode("utf-8")) + 20000 >= limit:
                    raise RuntimeError("Local budget guard refused this request: occupied context + input bytes + 20k runtime reserve approaches the chosen limit. Compact or reduce context; strict upstream preflight accounting remains unavailable.")
            await self.client.query(encoded)
            partial = ""
            final = ""
            completed = None
            async for msg in self.client.receive_response():
                if epoch != self.epoch:
                    return
                if isinstance(msg, StreamEvent):
                    ev = msg.event
                    if ev.get("type") == "content_block_delta" and ev.get("delta", {}).get("type") == "text_delta":
                        chunk = ev["delta"]["text"]
                        partial += chunk
                        send({"method": "partial", "params": {"id": ident, "epoch": epoch, "text": partial}})
                elif isinstance(msg, AssistantMessage):
                    final = "".join(block.text for block in msg.content if isinstance(block, TextBlock))
                elif isinstance(msg, SystemMessage) and msg.subtype == "init":
                    tools = msg.data.get("tools", [])
                    if tools:
                        raise RuntimeError("Runtime exposed tools despite no-tools configuration: " + str(tools))
                    self.session = msg.data.get("session_id", self.session)
                    self.server = msg.data
                elif isinstance(msg, ResultMessage):
                    if msg.is_error:
                        raise RuntimeError(msg.result or str(msg.errors or msg.subtype))
                    completed = msg
            if not completed:
                raise RuntimeError("SDK did not return a successful result")
            self.session = completed.session_id
            self.last_turn = time.time()
            self.usage = completed.usage
            self.occupancy = 0
            if document and data.get("context"):
                self.baselines[document["id"]] = data["context"]["revision"]
            if self.session:
                self.record()
                if not self.records[self.session].get("title"):
                    self.records[self.session]["title"] = data["instruction"][:100]
                    save_manifest(self.records)
            send({"id": ident, "result": {"text": final or completed.result or partial,
                  "epoch": epoch, "session": self.session, "usage": self.usage}})
        except asyncio.CancelledError:
            send({"id": ident, "error": "Canceled", "epoch": epoch})
        except Exception as exc:
            self.baselines = {}
            send({"id": ident, "error": str(exc), "epoch": epoch})


async def main():
    bridge = Bridge()
    loop = asyncio.get_running_loop()
    async def read_frame():
        def blocking():
            headers = {}
            while True:
                line = sys.stdin.buffer.readline()
                if not line:
                    return None
                if line in (b"\r\n", b"\n"):
                    break
                key, _, val = line.partition(b":")
                headers[key.strip().lower()] = val.strip()
            size = int(headers[b"content-length"])
            if size > 16 * 1024 * 1024:
                raise ValueError("Frame too large")
            data = sys.stdin.buffer.read(size)
            return json.loads(data) if len(data) == size else None
        return await loop.run_in_executor(None, blocking)
    try:
        while (request := await read_frame()) is not None:
            await bridge.dispatch(request)
    finally:
        await bridge.stop()


if __name__ == "__main__":
    asyncio.run(main())
