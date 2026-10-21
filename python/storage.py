"""Per-bridge ownership locks protect saved and ephemeral SDK transcripts."""
import fcntl
import json
import os
from pathlib import Path
import uuid
from claude_agent_sdk import delete_session


class Storage:
    def __init__(self, root):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.locks = {}
        # A lock, not a PID check, survives PID reuse and identifies live owners.
        for path in self.root.glob('*.json'):
            identity = path.stem
            if self.claim(identity):
                record = self.read(identity)
                if record and not record.get('saved'):
                    self.delete(record)
                self.release(identity)

    def claim(self, identity):
        if identity in self.locks:
            return True
        lock = (self.root / (identity + '.lock')).open('a')
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            lock.close()
            return False
        self.locks[identity] = lock
        return True

    def release(self, identity):
        lock = self.locks.pop(identity, None)
        if lock:
            lock.close()

    def read(self, identity):
        # IDs are UUIDs created by this plugin, never arbitrary caller paths.
        uuid.UUID(identity)
        path = self.root / (identity + '.json')
        return json.loads(path.read_text()) if path.exists() else None

    def write(self, record):
        path = self.root / (record['id'] + '.json')
        temporary = path.with_suffix('.json.' + str(os.getpid()))
        temporary.write_text(json.dumps(record, ensure_ascii=False))
        temporary.chmod(0o600)
        temporary.replace(path)

    def delete(self, record):
        # The logical UUID is also the reserved first SDK session ID. It covers
        # a crash after CLI creation but before its init event reaches the bridge.
        sid = record.get('sdk_id') or record['id']
        try:
            delete_session(sid, directory=record['cwd'])
        except FileNotFoundError:
            pass
        (self.root / (record['id'] + '.json')).unlink(missing_ok=True)

    def saved(self):
        records = []
        for path in self.root.glob('*.json'):
            record = self.read(path.stem)
            if record and record.get('saved'):
                records.append(record)
        return sorted(records, key=lambda r: r['created'], reverse=True)
