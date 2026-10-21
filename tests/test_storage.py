import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
import uuid
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'python'))
from storage import Store


class OwnedStorage(unittest.TestCase):
    def setUp(self):
        scratch = Path(os.environ.get('XDG_CACHE_HOME', Path.home() / '.cache')) / 'npi-canary'
        scratch.mkdir(parents=True, exist_ok=True)
        temporary = tempfile.TemporaryDirectory(dir=scratch, prefix='nvim-claude-storage-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def store(self):
        store = Store(self.root)
        record = store.new({'model': 'claude-haiku-5-5'})
        self.addCleanup(store.close, record)
        return store, record

    def transcript(self, store, record):
        sid = str(uuid.uuid4())
        path = self.root / (sid + '.jsonl')
        path.write_text(json.dumps({'cwd': str(store.workspace)}) + '\n')
        store.remember_path(record, path, sid)
        return path

    def test_cleanup_removes_every_registered_runtime_id_only(self):
        store, record = self.store()
        first = self.transcript(store, record)
        second = self.transcript(store, record)
        unrelated = self.root / (str(uuid.uuid4()) + '.jsonl')
        unrelated.write_text('unrelated runtime record')
        store.close(record)
        self.assertFalse(first.exists())
        self.assertFalse(second.exists())
        self.assertTrue(unrelated.exists())

    def test_startup_sweep_preserves_a_live_bridge(self):
        first, record = self.store()
        path = self.transcript(first, record)
        second, _ = self.store()
        second.sweep()
        self.assertTrue(path.exists())
        self.assertTrue(first.manifest_path(record['id']).exists())

    def test_saved_checkpoint_survives_detach_and_shutdown(self):
        store, record = self.store()
        path = self.transcript(store, record)
        record['saved'] = True
        store.write(record)
        store.close(record)
        self.assertTrue(path.exists())
        self.assertTrue(store.manifest_path(record['id']).exists())


if __name__ == '__main__':
    unittest.main()
