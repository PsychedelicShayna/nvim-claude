"""Atomic manifests and advisory leases for exactly the sessions we create."""
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
        self.root.mkdir(parents=True, exist_ok=True)
        self.lease = None
        self.current = None
        self.cleanup_abandoned()

    def lock(self, ident):
        uuid.UUID(ident)
        lease = (self.root / (ident + '.lock')).open('a')
        try:
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            lease.close()
            raise ValueError('Conversation is open in another Neovim instance')
        return lease

    def path(self, ident):
        return self.root / (ident + '.json')

    def write(self):
        data = self.current
        temp = self.root / (data['id'] + '.json.new')
        temp.write_text(json.dumps(data, ensure_ascii=False), encoding='utf-8')
        os.chmod(temp, 0o600)
        os.replace(temp, self.path(data['id']))

    def delete(self, data):
        # The SDK validates UUID and removes only this session, including its sidecars.
        if data.get('started'):
            try:
                delete_session(data['id'], directory=data['cwd'])
            except FileNotFoundError:
                # Cancellation can arrive after init but before a transcript is written.
                pass
        self.path(data['id']).unlink(missing_ok=True)
        directory = Path(data['cwd'])
        try:
            directory.rmdir()
        except OSError:
            pass

    def cleanup_abandoned(self):
        for path in self.root.glob('*.json'):
            try:
                lease = self.lock(path.stem)
            except ValueError:
                continue
            try:
                data = json.loads(path.read_text())
                if not data['saved']:
                    self.delete(data)
            finally:
                lease.close()

    def release(self):
        if self.current and not self.current['saved']:
            self.delete(self.current)
        if self.lease:
            self.lease.close()
        self.current = self.lease = None

    def create(self, config, saved=False):
        self.release()
        ident = str(uuid.uuid4())
        self.lease = self.lock(ident)
        cwd = self.root / ident
        cwd.mkdir(mode=0o700)
        self.current = {'id': ident, 'created': time.time(), 'first_prompt': '',
                        'saved': saved, 'config': dict(config), 'cwd': str(cwd),
                        'started': False, 'last_request': 0, 'usage': {}, 'turns': 0}
        self.write()
        return self.current

    def resume(self, ident):
        lease = self.lock(ident)
        try:
            data = json.loads(self.path(ident).read_text())
            if not data['saved']:
                raise ValueError('Conversation is not saved')
        except Exception:
            lease.close()
            raise
        self.release()
        self.lease, self.current = lease, data
        return data

    def saved(self):
        rows = []
        for path in self.root.glob('*.json'):
            data = json.loads(path.read_text())
            if data['saved']:
                rows.append({'id': data['id'], 'created': data['created'],
                             'title': time.strftime('%y:%m:%d:%H:%M:%S', time.localtime(data['created']))
                             + ' - ' + data['first_prompt'][:80]})
        return sorted(rows, key=lambda r: r['created'], reverse=True)
