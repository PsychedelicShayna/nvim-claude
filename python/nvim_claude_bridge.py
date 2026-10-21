#!/usr/bin/env python3
"""JSON-RPC bridge between Neovim and the Claude Agent SDK."""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import fcntl
import importlib.metadata
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import uuid
from typing import Any

PROTOCOL_VERSION = 1
SDK_PACKAGE = "claude-agent-sdk"
RUNTIME_OVERHEAD_TOKENS = 16_384
OUTPUT_RESERVE_TOKENS = 8_192
DEFAULT_CACHE_TTL_SECONDS = 3600
API_CACHE_TTL_SECONDS = 300


def _pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _acquire_install_lock(path: Path, timeout: float = 600.0) -> int:
    deadline = time.monotonic() + timeout
    while True:
        try:
            fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            os.write(fd, str(os.getpid()).encode())
            return fd
        except FileExistsError:
            try:
                owner = int(path.read_text().strip())
            except (OSError, ValueError):
                owner = 0
            if owner and not _pid_alive(owner):
                with contextlib.suppress(OSError):
                    path.unlink()
                continue
            if time.monotonic() >= deadline:
                raise RuntimeError(f"timed out waiting for SDK installation lock: {path}")
            time.sleep(0.25)


def provision(root: Path, update: bool = False) -> None:
    root.mkdir(parents=True, exist_ok=True)
    lock_path = root / "install.lock"
    fd = _acquire_install_lock(lock_path)
    try:
        venv = root / "venv"
        python = venv / "bin" / "python"
        if python.exists() and not update:
            check = subprocess.run(
                [str(python), "-c", "import claude_agent_sdk"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
            if check.returncode == 0:
                print(json.dumps({"status": "ready", "python": str(python)}), flush=True)
                return

        if python.exists() and update:
            command = [str(python), "-m", "pip", "install", "--disable-pip-version-check", "--upgrade", SDK_PACKAGE]
            subprocess.run(command, check=True)
        else:
            staging = root / f"venv.staging-{os.getpid()}"
            shutil.rmtree(staging, ignore_errors=True)
            subprocess.run([sys.executable, "-m", "venv", str(staging)], check=True)
            staging_python = staging / "bin" / "python"
            subprocess.run(
                [str(staging_python), "-m", "pip", "install", "--disable-pip-version-check", SDK_PACKAGE],
                check=True,
            )
            if venv.exists():
                shutil.rmtree(venv)
            os.replace(staging, venv)
        print(json.dumps({"status": "ready", "python": str(python)}), flush=True)
    finally:
        os.close(fd)
        with contextlib.suppress(OSError):
            lock_path.unlink()


class Manifest:
    def __init__(self, state_dir: Path) -> None:
        self.path = state_dir / "conversations.json"
        self.lock_path = state_dir / "conversations.lock"
        state_dir.mkdir(parents=True, exist_ok=True)

    def _locked(self):
        handle = self.lock_path.open("a+", encoding="utf-8")
        fcntl.flock(handle, fcntl.LOCK_EX)
        return handle

    def read(self) -> dict[str, Any]:
        handle = self._locked()
        try:
            if not self.path.exists():
                return {"sticky": False, "conversations": {}}
            try:
                data = json.loads(self.path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                return {"sticky": False, "conversations": {}}
            data.setdefault("sticky", False)
            data.setdefault("conversations", {})
            return data
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)
            handle.close()

    def update(self, mutator) -> dict[str, Any]:
        handle = self._locked()
        try:
            if self.path.exists():
                try:
                    data = json.loads(self.path.read_text(encoding="utf-8"))
                except (OSError, json.JSONDecodeError):
                    data = {}
            else:
                data = {}
            data.setdefault("sticky", False)
            data.setdefault("conversations", {})
            mutator(data)
            tmp = self.path.with_suffix(f".tmp-{os.getpid()}")
            tmp.write_text(json.dumps(data, indent=2, sort_keys=True), encoding="utf-8")
            os.replace(tmp, self.path)
            return data
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)
            handle.close()


class RpcWriter:
    def __init__(self) -> None:
        self.lock = asyncio.Lock()

    async def send(self, message: dict[str, Any]) -> None:
        raw = json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        frame = f"Content-Length: {len(raw)}\r\n\r\n".encode("ascii") + raw
        async with self.lock:
            sys.stdout.buffer.write(frame)
            sys.stdout.buffer.flush()


class Engine:
    def __init__(self, state_dir: Path, system_prompt_path: Path, writer: RpcWriter) -> None:
        self.state_dir = state_dir
        self.runtime_cwd = state_dir / "workspace"
        self.runtime_cwd.mkdir(parents=True, exist_ok=True)
        self.prompt_path = system_prompt_path
        self.system_prompt = system_prompt_path.read_text(encoding="utf-8")
        self.writer = writer
        self.manifest = Manifest(state_dir)
        self.client = None
        self.server_info: dict[str, Any] = {}
        self.active_task: asyncio.Task | None = None
        self.active_request_id: Any = None
        self.generation = 0
        self.model = "claude-haiku-5-5"
        self.effort = "low"
        self.context_limit_tokens: int | None = 100_000
        self.logical_id = str(uuid.uuid4())
        self.session_id: str | None = None
        self.created_at = time.time()
        self.first_prompt = ""
        self.persistent = False
        self.last_turn_at: float | None = None
        self.cache_ttl = DEFAULT_CACHE_TTL_SECONDS
        self.transcript: str | None = None
        self.resolved_model: str | None = None
        self.cumulative_usage: dict[str, Any] = {}
        self._cleanup_abandoned()
        manifest = self.manifest.read()
        self.sticky = bool(manifest.get("sticky", False))
        self.persistent = self.sticky

    def _cleanup_abandoned(self) -> None:
        stale_paths: list[str] = []

        def mutate(data: dict[str, Any]) -> None:
            conversations = data.setdefault("conversations", {})
            for key, item in list(conversations.items()):
                owner = int(item.get("owner_pid") or 0)
                if not item.get("saved") and owner != os.getpid() and not _pid_alive(owner):
                    if item.get("transcript"):
                        stale_paths.append(item["transcript"])
                    conversations.pop(key, None)

        self.manifest.update(mutate)
        for path in stale_paths:
            self._delete_transcript(path)

    @staticmethod
    def _delete_transcript(path_text: str | None) -> None:
        if not path_text:
            return
        path = Path(path_text).expanduser()
        root = (Path.home() / ".claude" / "projects").resolve()
        try:
            resolved = path.resolve()
            if resolved.is_relative_to(root) and resolved.suffix == ".jsonl":
                resolved.unlink(missing_ok=True)
        except OSError:
            pass

    def _find_transcript(self, session_id: str) -> str | None:
        root = Path.home() / ".claude" / "projects"
        if not root.exists():
            return None
        matches = list(root.rglob(f"{session_id}.jsonl"))
        return str(matches[0]) if len(matches) == 1 else None

    def _record(self) -> None:
        item = {
            "logical_id": self.logical_id,
            "session_id": self.session_id,
            "created_at": self.created_at,
            "last_turn_at": self.last_turn_at,
            "first_prompt": self.first_prompt,
            "saved": self.persistent,
            "model": self.model,
            "effort": self.effort,
            "context_limit_tokens": self.context_limit_tokens,
            "owner_pid": os.getpid(),
            "transcript": self.transcript,
            "resolved_model": self.resolved_model,
            "cumulative_usage": self.cumulative_usage,
        }

        def mutate(data: dict[str, Any]) -> None:
            data.setdefault("conversations", {})[self.logical_id] = item
            data["sticky"] = self.sticky

        self.manifest.update(mutate)

    def _remove_record(self, logical_id: str) -> None:
        self.manifest.update(lambda data: data.setdefault("conversations", {}).pop(logical_id, None))

    def _new_logical(self) -> None:
        self.logical_id = str(uuid.uuid4())
        self.session_id = None
        self.created_at = time.time()
        self.first_prompt = ""
        self.persistent = self.sticky
        self.last_turn_at = None
        self.transcript = None
        self.resolved_model = None
        self.cumulative_usage = {}
        self.generation += 1
        self._record()

    async def _disconnect(self) -> None:
        if self.client is not None:
            with contextlib.suppress(Exception):
                await self.client.disconnect()
            self.client = None

    async def _ensure_client(self) -> None:
        if self.client is not None:
            return
        from claude_agent_sdk import ClaudeAgentOptions, ClaudeSDKClient

        options = ClaudeAgentOptions(
            tools=[],
            allowed_tools=[],
            mcp_servers={},
            strict_mcp_config=True,
            setting_sources=[],
            skills=[],
            plugins=[],
            agents={},
            system_prompt={"type": "custom", "prompt": self.system_prompt, "snapshot": False},
            model=self.model,
            effort=self.effort,
            resume=self.session_id,
            cwd=self.runtime_cwd,
            include_partial_messages=True,
        )
        self.client = ClaudeSDKClient(options)
        await self.client.connect()
        info = await self.client.get_server_info()
        self.server_info = info or {}
        account = self.server_info.get("account") or {}
        if account.get("apiProvider") and account.get("apiProvider") != "firstParty":
            self.cache_ttl = API_CACHE_TTL_SECONDS
        else:
            self.cache_ttl = DEFAULT_CACHE_TTL_SECONDS

    async def initialize(self) -> dict[str, Any]:
        await self._ensure_client()
        import claude_agent_sdk

        cli = Path(claude_agent_sdk.__file__).parent / "_bundled" / "claude"
        return {
            "protocolVersion": PROTOCOL_VERSION,
            "sdkVersion": importlib.metadata.version(SDK_PACKAGE),
            "cliVersion": self.server_info.get("claude_code_version"),
            "cliPath": str(cli),
            "pythonVersion": sys.version.split()[0],
            "models": self.server_info.get("models") or [],
            "account": self.server_info.get("account"),
            "capabilities": self.server_info.get("capabilities") or [],
            "mcp": await self.client.get_mcp_status(),
            "noTools": True,
        }

    async def _usage(self) -> dict[str, Any]:
        await self._ensure_client()
        try:
            return await self.client.get_context_usage()
        except Exception as exc:
            return {"unavailable": str(exc)}

    async def _receive_turn(self, request_id: Any, emit_text: bool = True) -> tuple[str, Any]:
        from claude_agent_sdk import AssistantMessage, ResultMessage, StreamEvent, SystemMessage, TextBlock

        streamed: list[str] = []
        complete = ""
        result = None
        async for message in self.client.receive_response():
            if isinstance(message, StreamEvent):
                event = message.event or {}
                delta = event.get("delta") or {}
                if event.get("type") == "content_block_delta" and delta.get("type") == "text_delta":
                    text = delta.get("text") or ""
                    if text:
                        streamed.append(text)
                        if emit_text:
                            await self.writer.send({"jsonrpc": "2.0", "method": "request/partial", "params": {"requestId": request_id, "text": text, "generation": self.generation}})
            elif isinstance(message, SystemMessage) and message.subtype == "init":
                announced_tools = message.data.get("tools") or []
                if announced_tools:
                    raise RuntimeError("No-tools contract failed; runtime announced tools: " + ", ".join(announced_tools))
                self.resolved_model = message.data.get("model") or self.resolved_model
            elif isinstance(message, AssistantMessage):
                text = "".join(block.text for block in message.content if isinstance(block, TextBlock))
                if text:
                    complete = text
                self.resolved_model = message.model or self.resolved_model
            elif isinstance(message, ResultMessage):
                result = message
        raw = complete or "".join(streamed) or (getattr(result, "result", None) or "")
        if result is None:
            raise RuntimeError("Claude runtime ended the turn without a result")
        if result.is_error:
            details = "; ".join(result.errors or []) or result.result or result.subtype
            raise RuntimeError(details)
        return raw, result

    async def _compact(self, request_id: Any) -> dict[str, Any]:
        await self._ensure_client()
        usage = await self._usage()
        occupied = int(usage.get("totalTokens") or 0)
        if self.context_limit_tokens and occupied + RUNTIME_OVERHEAD_TOKENS + OUTPUT_RESERVE_TOKENS > self.context_limit_tokens:
            raise RuntimeError("The active context is too close to the local budget to compact safely. Start a new conversation or raise the explicit budget.")
        await self.writer.send({"jsonrpc": "2.0", "method": "request/status", "params": {"requestId": request_id, "status": "compacting", "generation": self.generation}})
        await self.client.query("/compact Preserve the user's requests, the assistant's raw replies, decisions, and unresolved questions. File baselines will be resent by the editor.")
        _, result = await self._receive_turn(request_id, emit_text=False)
        if result.session_id:
            self.session_id = result.session_id
        return await self._usage()

    def _request_upper_bound(self, serialized: str) -> int:
        # Claude tokenizes UTF-8 bytes into no more than one token per byte. The
        # fixed margin covers runtime framing and metadata not present here.
        return len(serialized.encode("utf-8")) + len(self.system_prompt.encode("utf-8")) + RUNTIME_OVERHEAD_TOKENS + OUTPUT_RESERVE_TOKENS

    async def request(self, request_id: Any, params: dict[str, Any]) -> dict[str, Any]:
        if self.active_task is not None and self.active_task is not asyncio.current_task():
            raise RuntimeError("The active conversation is busy")
        now = time.time()
        if not self.persistent and self.last_turn_at and now - self.last_turn_at > self.cache_ttl:
            old_transcript = self.transcript
            old_id = self.logical_id
            await self._disconnect()
            self._remove_record(old_id)
            self._delete_transcript(old_transcript)
            self._new_logical()
        await self._ensure_client()

        envelope = params["envelope"]
        serialized = json.dumps(envelope, ensure_ascii=False, separators=(",", ":"))
        requested_limit = params.get("contextLimitTokens", self.context_limit_tokens)
        self.context_limit_tokens = int(requested_limit) if requested_limit else None
        usage = await self._usage()
        occupied = int(usage.get("totalTokens") or 0)
        upper = self._request_upper_bound(serialized)
        if self.context_limit_tokens:
            predicted = occupied + upper
            if occupied and predicted > int(self.context_limit_tokens * 0.72):
                usage = await self._compact(request_id)
                occupied = int(usage.get("totalTokens") or 0)
                predicted = occupied + upper
            if predicted > self.context_limit_tokens:
                raise RuntimeError(
                    f"Request refused: conservative upper bound {predicted:,} tokens exceeds the configured {self.context_limit_tokens:,}-token budget."
                )

        if not self.first_prompt:
            self.first_prompt = str(envelope.get("instruction") or "")[:160]
        await self.writer.send({"jsonrpc": "2.0", "method": "request/status", "params": {"requestId": request_id, "status": "continued" if self.session_id else "new", "generation": self.generation}})
        await self.client.query(serialized)
        raw, result = await self._receive_turn(request_id, emit_text=True)
        self.session_id = result.session_id or self.session_id
        self.last_turn_at = time.time()
        if self.session_id:
            self.transcript = self._find_transcript(self.session_id)
        self.cumulative_usage = getattr(result, "usage", None) or self.cumulative_usage
        self._record()
        final_usage = await self._usage()
        return {
            "raw": raw,
            "sessionId": self.session_id,
            "logicalId": self.logical_id,
            "usage": final_usage,
            "generation": self.generation,
            "resolvedModel": self.resolved_model,
            "cumulativeUsage": self.cumulative_usage,
        }

    async def cancel(self) -> dict[str, Any]:
        self.generation += 1
        if self.client is not None:
            with contextlib.suppress(Exception):
                await self.client.interrupt()
        if self.active_task and self.active_task is not asyncio.current_task():
            self.active_task.cancel()
        return {"cancelled": True, "generation": self.generation}

    async def configure(self, params: dict[str, Any]) -> dict[str, Any]:
        changed_runtime = False
        for key, attr in (("model", "model"), ("effort", "effort"), ("contextLimitTokens", "context_limit_tokens")):
            if key in params:
                value = params[key]
                if getattr(self, attr) != value:
                    setattr(self, attr, value)
                    changed_runtime = changed_runtime or key in ("model", "effort")
        if changed_runtime:
            await self._disconnect()
        self._record()
        return {"model": self.model, "effort": self.effort, "contextLimitTokens": self.context_limit_tokens}

    async def session_command(self, params: dict[str, Any], request_id: Any) -> Any:
        action = params.get("action")
        if action in ("new", "clear"):
            old = {"id": self.logical_id, "saved": self.persistent, "transcript": self.transcript}
            await self._disconnect()
            if not self.persistent:
                self._remove_record(self.logical_id)
                self._delete_transcript(self.transcript)
            self._new_logical()
            return {"action": action, "generation": self.generation, "preservedCheckpoint": bool(old["saved"])}
        if action == "save":
            self.persistent = True
            self._record()
            return {"saved": True, "logicalId": self.logical_id}
        if action == "sticky":
            value = params.get("value")
            self.sticky = (not self.sticky) if value is None else bool(value)
            if self.sticky:
                self.persistent = True
            self._record()
            return {"sticky": self.sticky, "saved": self.persistent}
        if action == "list":
            values = [item for item in self.manifest.read().get("conversations", {}).values() if item.get("saved")]
            values.sort(key=lambda item: item.get("last_turn_at") or item.get("created_at") or 0, reverse=True)
            return values
        if action == "resume":
            item = self.manifest.read().get("conversations", {}).get(params.get("logicalId"))
            if not item or not item.get("saved"):
                raise RuntimeError("Saved conversation was not found")
            await self._disconnect()
            self.logical_id = item["logical_id"]
            self.session_id = item.get("session_id")
            self.created_at = item.get("created_at") or time.time()
            self.first_prompt = item.get("first_prompt") or ""
            self.persistent = True
            self.last_turn_at = item.get("last_turn_at")
            self.model = item.get("model") or self.model
            self.effort = item.get("effort") or self.effort
            self.context_limit_tokens = item.get("context_limit_tokens")
            self.transcript = item.get("transcript")
            self.resolved_model = item.get("resolved_model")
            self.cumulative_usage = item.get("cumulative_usage") or {}
            self.generation += 1
            self._record()
            return {"resumed": True, "generation": self.generation, "logicalId": self.logical_id}
        if action == "compact":
            usage = await self._compact(request_id)
            self.generation += 1
            self._record()
            return {"compacted": True, "generation": self.generation, "usage": usage}
        if action == "info":
            usage = await self._usage()
            return {
                "logicalId": self.logical_id,
                "sessionId": self.session_id,
                "model": self.model,
                "resolvedModel": self.resolved_model,
                "effort": self.effort,
                "contextLimitTokens": self.context_limit_tokens,
                "usage": usage,
                "cumulativeUsage": self.cumulative_usage,
                "saved": self.persistent,
                "sticky": self.sticky,
                "lastTurnAt": self.last_turn_at,
                "cacheTtlSeconds": self.cache_ttl,
                "cacheProvenance": "runtime account mode estimate",
                "sdkVersion": importlib.metadata.version(SDK_PACKAGE),
                "cliVersion": self.server_info.get("claude_code_version"),
                "pythonVersion": sys.version.split()[0],
                "account": self.server_info.get("account"),
                "budgetEnforcement": "conservative byte upper bound with runtime occupancy and fixed overhead reserve",
            }
        raise RuntimeError(f"Unknown session action: {action}")

    async def set_system_prompt(self, prompt: str) -> dict[str, Any]:
        if not prompt.strip():
            raise RuntimeError("System prompt cannot be empty")
        self.system_prompt = prompt
        await self._disconnect()
        self.generation += 1
        return {"updated": True, "generation": self.generation}

    async def shutdown(self) -> None:
        await self.cancel()
        await self._disconnect()
        if not self.persistent:
            self._remove_record(self.logical_id)
            self._delete_transcript(self.transcript)


async def read_message() -> dict[str, Any] | None:
    def blocking_read() -> dict[str, Any] | None:
        headers: dict[str, str] = {}
        while True:
            line = sys.stdin.buffer.readline()
            if not line:
                return None
            if line in (b"\r\n", b"\n"):
                break
            name, _, value = line.decode("ascii").partition(":")
            headers[name.lower()] = value.strip()
        length = int(headers.get("content-length", "0"))
        if length <= 0:
            raise ValueError("missing Content-Length")
        body = sys.stdin.buffer.read(length)
        if len(body) != length:
            return None
        return json.loads(body.decode("utf-8"))

    return await asyncio.to_thread(blocking_read)


async def serve(state_dir: Path, prompt_path: Path) -> None:
    writer = RpcWriter()
    engine = Engine(state_dir, prompt_path, writer)
    tasks: set[asyncio.Task] = set()

    async def dispatch(message: dict[str, Any]) -> None:
        request_id = message.get("id")
        method = message.get("method")
        params = message.get("params") or {}
        try:
            if method == "initialize":
                result = await engine.initialize()
            elif method == "request":
                engine.active_task = asyncio.current_task()
                engine.active_request_id = request_id
                try:
                    result = await engine.request(request_id, params)
                finally:
                    engine.active_task = None
                    engine.active_request_id = None
            elif method == "cancel":
                result = await engine.cancel()
            elif method == "configure":
                result = await engine.configure(params)
            elif method == "session":
                result = await engine.session_command(params, request_id)
            elif method == "system_prompt":
                result = await engine.set_system_prompt(params["prompt"])
            elif method == "shutdown":
                result = {"shutdown": True}
                await engine.shutdown()
            else:
                raise RuntimeError(f"Unknown method: {method}")
            if request_id is not None:
                await writer.send({"jsonrpc": "2.0", "id": request_id, "result": result})
        except asyncio.CancelledError:
            if request_id is not None:
                await writer.send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32800, "message": "Request cancelled"}})
        except Exception as exc:
            if request_id is not None:
                await writer.send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32000, "message": str(exc)}})

    try:
        while True:
            message = await read_message()
            if message is None:
                break
            task = asyncio.create_task(dispatch(message))
            tasks.add(task)
            task.add_done_callback(tasks.discard)
            if message.get("method") == "shutdown":
                await task
                break
    finally:
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        await engine.shutdown()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--provision", type=Path)
    parser.add_argument("--update", action="store_true")
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--state-dir", type=Path)
    parser.add_argument("--system-prompt", type=Path)
    args = parser.parse_args()
    if args.provision:
        provision(args.provision, update=args.update)
        return
    if not args.serve or not args.state_dir or not args.system_prompt:
        parser.error("--serve requires --state-dir and --system-prompt")
    asyncio.run(serve(args.state_dir, args.system_prompt))


if __name__ == "__main__":
    main()
