"""Exact session ownership, cross-editor locks, and saved checkpoints."""
import fcntl
import json
import os
from pathlib import Path
import shutil
import time
import uuid


class Storage:
    def __init__(self, root):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        config = Path(os.environ.get('CLAUDE_CONFIG_DIR', str(Path.home() / '.claude')))
        self.projects = config / 'projects'
        self.workspace = self.root / 'workspace'
        self.workspace.mkdir(exist_ok=True)
        self.locks = {}
        self.cleanup_abandoned()

    def path(self, ident):
        # IDs are generated UUIDs, never paths accepted from the editor.
        return self.root / (str(uuid.UUID(ident)) + '.json')

    def transcript(self, ident):
        uuid.UUID(ident)
        matches = list(self.projects.glob('*/' + ident + '.jsonl'))
        if len(matches) > 1:
            raise ValueError('Ambiguous owned SDK transcript')
        return matches[0] if matches else None


    def lock(self, ident):
        if ident in self.locks:
            return
        handle = self.path(ident).with_suffix('.lock').open('a')
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            handle.close()
            raise ValueError('Conversation is owned by another live editor')
        self.locks[ident] = handle

    def unlock(self, ident):
        handle = self.locks.pop(ident, None)
        if handle:
            handle.close()

    def write(self, record):
        path = self.path(record['id'])
        temporary = path.with_suffix('.new')
        temporary.write_text(json.dumps(record, ensure_ascii=False))
        temporary.replace(path)

    def create(self, config, persistent=False):
        ident = str(uuid.uuid4())
        self.lock(ident)
        record = {'id': ident, 'session_ids': [ident], 'session_id': ident, 'created_at': time.time(), 'last_request': None, 'first_prompt': '', 'persistent': persistent, 'config': dict(config), 'baselines': {}, 'raw': [], 'bound': 0, 'usage': {}, 'occupancy': None, 'has_turns': False}
        self.write(record)
        return record

    def load(self, ident):
        self.lock(ident)
        record = json.loads(self.path(ident).read_text())
        if not record['persistent']:
            self.unlock(ident)
            raise ValueError('Only saved conversations may be resumed')
        # No editor target survives restart. Snapshot again after resumption.
        record['baselines'] = {}
        return record

    def discard(self, record):
        if not record['persistent']:
            for ident in record['session_ids']:
                uuid.UUID(ident)
                path = self.transcript(ident)
                if path:
                    path.unlink(missing_ok=True)
                    shutil.rmtree(path.with_suffix(''), ignore_errors=True)
            self.path(record['id']).unlink(missing_ok=True)
        self.unlock(record['id'])

    def cleanup_abandoned(self):
        for path in self.root.glob('*.json'):
            record = json.loads(path.read_text())
            if record.get('persistent'):
                continue
            try:
                self.lock(record['id'])
            except ValueError:
                continue
            self.discard(record)

    def saved(self):
        records = [json.loads(p.read_text()) for p in self.root.glob('*.json')]
        records = sorted((r for r in records if r['persistent']), key=lambda r: r['created_at'], reverse=True)
        return [{'id': r['id'], 'created_at': r['created_at'], 'first_prompt': r['first_prompt'], 'title': time.strftime('%y:%m:%d:%H:%M:%S', time.localtime(r['created_at'])) + ' - ' + r['first_prompt'][:70] + ' [' + r['id'][:8] + ']'} for r in records]
