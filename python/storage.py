"""Per-conversation advisory locks and manifests, never a global session sweep."""
import fcntl
import json
import os
from pathlib import Path
import time
import uuid
from claude_agent_sdk import delete_session


class Store:
    def __init__(self, root):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.lock = None
        self.current = None
        for path in self.root.glob('*/manifest.json'):
            lock = (path.parent / 'owner.lock').open('a')
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                data = json.loads(path.read_text())
                if not data['saved']:
                    self.delete(data, path)
            except (BlockingIOError, ValueError, KeyError):
                pass
            finally:
                lock.close()

    def delete(self, data, path):
        for session in data.get('sessions', []):
            try:
                delete_session(session, directory=data['cwd'])
            except FileNotFoundError:
                pass
        path.unlink(missing_ok=True)

    def release(self):
        if self.current and not self.current['saved']:
            self.delete(self.current, self.path)
        if self.lock:
            self.lock.close()
        self.lock = self.current = None

    def create(self, config, saved=False):
        self.release()
        key = str(uuid.uuid4())
        directory = self.root / key
        directory.mkdir(mode=0o700)
        cwd = directory / 'work'
        cwd.mkdir()
        self.path = directory / 'manifest.json'
        self.lock = (directory / 'owner.lock').open('a')
        fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        session = str(uuid.uuid4())
        self.current = {'id': key, 'created': time.time(), 'last_request': 0, 'first_prompt': '', 'saved': saved,
                        'cwd': str(cwd), 'sessions': [session], 'session': session, 'started': False,
                        'config': dict(config), 'baselines': {}, 'turns': [], 'usage': {}, 'occupancy': None}
        self.flush()
        return self.current

    def resume(self, key):
        uuid.UUID(key)
        path = self.root / key / 'manifest.json'
        lock = (path.parent / 'owner.lock').open('a')
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            data = json.loads(path.read_text())
            if not data['saved']:
                raise ValueError('Conversation is not saved')
        except Exception:
            lock.close()
            raise
        self.release()
        self.lock, self.current, self.path = lock, data, path
        self.current['baselines'] = {}
        return data

    def flush(self):
        tmp = self.path.with_suffix('.new')
        tmp.write_text(json.dumps(self.current, ensure_ascii=False))
        os.chmod(tmp, 0o600)
        os.replace(tmp, self.path)

    def list(self):
        items = []
        for path in self.root.glob('*/manifest.json'):
            try:
                data = json.loads(path.read_text())
                if data['saved']:
                    title = time.strftime('%y:%m:%d:%H:%M:%S', time.localtime(data['created'])) + ' - ' + data['first_prompt'].replace('\n', ' ')[:80]
                    items.append({'id': data['id'], 'title': title, 'created': data['created']})
            except (ValueError, KeyError):
                continue
        return sorted(items, key=lambda item: item['created'], reverse=True)
