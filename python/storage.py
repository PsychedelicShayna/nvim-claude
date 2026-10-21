"""Manifest locks establish ownership before deleting SDK session records."""
import fcntl
import json
import os
from pathlib import Path
import time
import uuid


class Store:
    def __init__(self, root, delete_session):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.delete_session = delete_session
        self.lock = None
        self.record = None
        self.cleanup_abandoned()

    def acquire(self, ident):
        lock = (self.root / (ident + '.lock')).open('a')
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            lock.close()
            raise ValueError('Conversation is open in another Neovim instance')
        return lock

    def cleanup_abandoned(self):
        for path in self.root.glob('*.json'):
            try:
                lock = self.acquire(path.stem)
            except ValueError:
                continue
            try:
                record = json.loads(path.read_text())
                if not record['saved']:
                    self.remove(record)
            finally:
                lock.close()

    def remove(self, record):
        for sid in record.get('session_ids', []):
            try:
                self.delete_session(sid, directory=record['cwd'])
            except FileNotFoundError:
                pass
        (self.root / (record['id'] + '.json')).unlink(missing_ok=True)
        # This directory is created empty by us. Never recursively delete it.
        try:
            Path(record['cwd']).rmdir()
        except OSError:
            pass

    def release(self):
        if self.record and not self.record['saved']:
            self.remove(self.record)
        if self.lock:
            self.lock.close()
        self.lock = self.record = None

    def new(self, config, sticky):
        self.release()
        ident = str(uuid.uuid4())
        self.lock = self.acquire(ident)
        cwd = self.root / ('work-' + ident)
        cwd.mkdir(mode=0o700)
        sid = str(uuid.uuid4())
        self.record = {'id': ident, 'created': time.time(), 'first_prompt': '', 'saved': sticky,
                       'config': dict(config), 'cwd': str(cwd), 'session_id': sid,
                       'session_ids': [sid], 'started': False, 'raw': [], 'history_bytes': 0,
                       'turns': 0, 'last_request': 0, 'usage': {}, 'cache_ttl': 300}
        self.flush()
        return self.record

    def resume(self, ident):
        if str(uuid.UUID(ident)) != ident:
            raise ValueError('Invalid conversation ID')
        lock = self.acquire(ident)
        try:
            record = json.loads((self.root / (ident + '.json')).read_text())
            if not record['saved']:
                raise ValueError('Only saved conversations can be resumed')
        except Exception:
            lock.close()
            raise
        self.release()
        self.lock, self.record = lock, record
        return record

    def flush(self):
        if self.record:
            path = self.root / (self.record['id'] + '.json')
            tmp = path.with_suffix('.pending')
            with tmp.open('w') as stream:
                os.chmod(tmp, 0o600)
                json.dump(self.record, stream, ensure_ascii=False)
                stream.flush()
                os.fsync(stream.fileno())
            tmp.replace(path)

    def saved(self):
        records = []
        for path in self.root.glob('*.json'):
            record = json.loads(path.read_text())
            if record['saved']:
                records.append({'id': record['id'], 'created': record['created'], 'first_prompt': record['first_prompt']})
        return sorted(records, key=lambda r: r['created'], reverse=True)
