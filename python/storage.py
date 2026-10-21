"""Manifest ownership is protected by OS locks, never by a stale PID guess."""
import fcntl
import json
import os
from pathlib import Path
import shutil
import time
import uuid


def atomic_json(path, value):
    temporary = path.with_suffix(".writing")
    temporary.write_text(json.dumps(value, ensure_ascii=False))
    os.chmod(temporary, 0o600)
    temporary.replace(path)


class Store:
    def __init__(self, root):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.workspace = self.root / "workspace"
        self.workspace.mkdir(exist_ok=True)
        self.instance = str(uuid.uuid4())
        self.owner = (self.root / (self.instance + ".lock")).open("a")
        fcntl.flock(self.owner, fcntl.LOCK_EX)
        self.claim = None
        self.sweep()

    def manifest_path(self, key):
        return self.root / (str(uuid.UUID(key)) + ".json")

    def write(self, record):
        record["owner"] = self.instance
        atomic_json(self.manifest_path(record["id"]), record)

    def new(self, config, persistent=False):
        record = {"id": str(uuid.uuid4()), "session_id": None, "created": time.time(),
                  "first_prompt": "", "saved": persistent, "config": dict(config),
                  "paths": [], "history": [], "last_used": 0, "usage": {}, "cost_usd": 0}
        self.write(record)
        self.acquire(record["id"])
        return record

    def acquire(self, key):
        path = self.manifest_path(key).with_suffix(".session-lock")
        claim = path.open("a")
        try:
            fcntl.flock(claim, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            claim.close()
            raise ValueError("That saved conversation is active in another Neovim instance")
        self.release()
        self.claim = claim

    def release(self):
        if self.claim:
            self.claim.close()
            self.claim = None

    def load(self, key):
        record = json.loads(self.manifest_path(key).read_text())
        if not record["saved"]:
            raise ValueError("Only saved conversations can be resumed")
        self.acquire(key)
        self.write(record)
        return record

    def list(self):
        records = []
        for path in self.root.glob("*.json"):
            record = json.loads(path.read_text())
            if record.get("saved"):
                title = time.strftime("%y:%m:%d:%H:%M:%S", time.localtime(record["created"]))
                records.append({"id": record["id"], "title": title + " - " +
                                record["first_prompt"].replace("\n", " ")[:80], "created": record["created"]})
        return sorted(records, key=lambda r: (r["created"], r["id"]), reverse=True)

    def remember_path(self, record, path, session_id):
        path = Path(path).resolve()
        # The runtime tells us its exact path. Never accept a traversal, a path
        # for a different session, or a transcript belonging to another cwd.
        if path.name != session_id + ".jsonl":
            raise ValueError("Unexpected runtime transcript identity")
        if path.exists():
            for line in path.open():
                item = json.loads(line)
                cwd = item.get("cwd")
                if cwd and Path(cwd).resolve() != self.workspace.resolve():
                    raise ValueError("Runtime transcript does not belong to the plugin workspace")
        if str(path) not in record["paths"]:
            record["paths"].append(str(path))
        record["session_id"] = session_id
        self.write(record)

    def delete(self, record):
        if record["saved"]:
            return
        if not record["paths"] and record.get("session_id"):
            from claude_agent_sdk._internal.sessions import _resolve_session_file_path
            path = _resolve_session_file_path(record["session_id"], str(self.workspace))
            if path:
                self.remember_path(record, path, record["session_id"])
        for entry in record["paths"]:
            path = Path(entry)
            # Only exact paths registered from this plugin's runtime are removed.
            if path.name != record["session_id"] + ".jsonl":
                continue
            path.unlink(missing_ok=True)
            sidecar = path.with_suffix("")
            if sidecar.is_dir() and not sidecar.is_symlink():
                shutil.rmtree(sidecar)
        self.manifest_path(record["id"]).unlink(missing_ok=True)

    def sweep(self):
        for path in self.root.glob("*.json"):
            record = json.loads(path.read_text())
            if record.get("saved"):
                continue
            owner = record.get("owner")
            if not owner:
                continue
            with (self.root / (str(uuid.UUID(owner)) + ".lock")).open("a") as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    continue
                self.delete(record)

    def close(self, record):
        self.delete(record)
        self.release()
        self.owner.close()
        (self.root / (self.instance + ".lock")).unlink(missing_ok=True)
