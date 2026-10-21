"""Exact plugin-owned SDK session records with process-held ownership locks."""
import fcntl
import json
import os
from pathlib import Path
import shutil
import time
import uuid
from claude_agent_sdk import delete_session


class Store:
    def __init__(self, root):
        self.root = Path(root).resolve()
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.lease = None
        self.record = None
        self.cleanup_abandoned()

    def lock(self, directory):
        lease = (directory / 'owner.lock').open('a')
        try:
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            lease.close()
            return None
        return lease

    def cleanup_abandoned(self):
        for path in self.root.glob('*/manifest.json'):
            directory = path.parent
            lease = self.lock(directory)
            if lease is None:
                continue
            try:
                record = json.loads(path.read_text())
                if not record['saved']:
                    self.delete(record, directory)
            except (ValueError, KeyError):
                # A corrupt record is not authority to delete runtime data.
                pass
            finally:
                lease.close()

    def delete(self, record, directory):
        if record['id'] != directory.name or Path(record['cwd']).resolve() != directory / 'work':
            raise ValueError('Session ownership manifest mismatch')
        for session in record['sessions']:
            try:
                delete_session(session, directory=record['cwd'])
            except FileNotFoundError:
                pass
        shutil.rmtree(directory)

    def release(self):
        if self.record:
            if not self.record['saved']:
                self.delete(self.record, self.root / self.record['id'])
            self.lease.close()
        self.record, self.lease = None, None

    def create(self, config, saved=False):
        self.release()
        identity = str(uuid.uuid4())
        directory = self.root / identity
        directory.mkdir(mode=0o700)
        self.lease = self.lock(directory)
        cwd = directory / 'work'
        cwd.mkdir()
        self.record = {'id': identity, 'sessions': [identity], 'cwd': str(cwd), 'created': time.time(), 'first_prompt': '', 'saved': saved, 'config': config, 'turns': 0, 'last_request': 0, 'history_bytes': 0, 'cumulative_usage': {}, 'sdk_session': identity}
        self.write()
        return self.record

    def resume(self, identity):
        identity = str(uuid.UUID(identity))
        directory = self.root / identity
        lease = self.lock(directory)
        if lease is None:
            raise ValueError('This conversation is open in another editor')
        try:
            record = json.loads((directory / 'manifest.json').read_text())
            if not record['saved']:
                raise ValueError('Conversation is not saved')
        except Exception:
            lease.close()
            raise
        self.release()
        self.lease, self.record = lease, record
        return record

    def write(self):
        path = self.root / self.record['id'] / 'manifest.json'
        temporary = path.with_suffix('.new')
        temporary.write_text(json.dumps(self.record, ensure_ascii=False))
        os.chmod(temporary, 0o600)
        temporary.replace(path)

    def list(self):
        records = []
        for path in self.root.glob('*/manifest.json'):
            try:
                record = json.loads(path.read_text())
                if record['saved']:
                    records.append({k: record[k] for k in ('id', 'created', 'first_prompt')})
            except (ValueError, KeyError, OSError):
                continue
        return sorted(records, key=lambda r: r['created'], reverse=True)
