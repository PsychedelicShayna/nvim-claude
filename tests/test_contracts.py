import json
from pathlib import Path
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'python'))
from contracts import parse_model, edit_result, normalize, context_for, excerpt


class Contracts(unittest.TestCase):
    def setUp(self):
        self.config = {'model': 'claude-haiku-5-5', 'effort': 'low', 'context_limit_tokens': 100000}

    def test_native_variant_and_explicit_local_budget(self):
        value = parse_model('claude-opus-4-6[1m][500k]:high', self.config)
        self.assertEqual(value, {'model': 'claude-opus-4-6[1m]', 'effort': 'high', 'context_limit_tokens': 500000})
        self.assertEqual(parse_model('vendor:model[limit=90k]', self.config)['model'], 'vendor:model')
        self.assertEqual(parse_model('vendor:model:other', self.config)['model'], 'vendor:model:other')
        self.assertEqual(parse_model('unknown[variant]', self.config)['model'], 'unknown[variant]')

    def test_edit_ids_deletion_and_block_contract(self):
        targets = [{'id': 'a'}, {'id': 'b'}]
        self.assertEqual(edit_result('{"status":"ok","replacements":[{"id":"a","text":""},{"id":"b","text":"  x  "}]}', targets)['replacements'][0]['text'], '')
        for items in ([{'id': 'a', 'text': 'x'}], [{'id': 'a', 'text': 'x'}, {'id': 'a', 'text': 'y'}], [{'id': 'a', 'text': 'x'}, {'id': 'c', 'text': 'y'}]):
            with self.assertRaises(ValueError):
                edit_result(json.dumps({'status': 'ok', 'replacements': items}), targets)
        with self.assertRaises(ValueError):
            edit_result('{"status":"ok","replacements":[{"id":"a","text":"x\\ny"}]}', [{'id': 'a'}], True)

    def test_context_revision_and_normalization(self):
        document = {'id': 'b', 'revision': 'r2', 'text': 'x\n' * 100 + 'new\n'}
        context = context_for(document, ('r1', 'x\n' * 100 + 'old\n'))
        self.assertEqual(context['kind'], 'diff')
        self.assertEqual(context['base_revision'], 'r1')
        self.assertIn('+new', context['text'])
        raw = '“héllo”—世界…\u200d'
        self.assertEqual(normalize(raw, 'replace'), '"héllo"-世界...\u200d')
        self.assertEqual(normalize(raw, 'remove'), 'héllo世界\u200d')
        self.assertEqual(raw, '“héllo”—世界…\u200d')

    def test_excerpt_cannot_drop_target(self):
        doc = {'text': 'a' * 500, 'revision': 'r'}
        with self.assertRaises(ValueError):
            excerpt(doc, [{'start': [0, 0], 'end': [0, 500]}], 100)


if __name__ == '__main__':
    unittest.main()
