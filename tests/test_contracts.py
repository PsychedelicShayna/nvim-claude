import sys
from pathlib import Path
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'python'))
from contracts import parse_model, envelope, validate_edit


class Contracts(unittest.TestCase):
    def test_model_expression_preserves_native_selector_and_colon(self):
        current = {'model': 'claude-haiku-5-5', 'effort': 'low', 'context_limit_tokens': 100000}
        parsed = parse_model('claude-opus-4-6[1m][500k]:high', current, [])
        self.assertEqual(parsed, {'model': 'claude-opus-4-6[1m]', 'effort': 'high', 'context_limit_tokens': 500000})
        self.assertEqual(parse_model('gateway:model', current, [])['model'], 'gateway:model')
        self.assertIsNone(parse_model('claude-opus-4-6[1m]:high', current, [])['context_limit_tokens'])
        with self.assertRaises(ValueError):
            parse_model('unknown[1m]', current, [])
        self.assertEqual(parse_model('unknown[limit=1m]', current, [])['context_limit_tokens'], 1000000)

    def test_general_ask_does_not_attach_document(self):
        self.assertEqual(envelope({'operation':'ask','instruction':'hello'}, {'b': {'text':'secret','revision':'1'}}), {'operation':'ask','instruction':'hello'})

    def test_baselines_are_explicit_and_not_mutated(self):
        p = {'operation':'replace','instruction':'x','document':{'id':'b'},'snapshot':'abc\n','revision':'2','targets':[]}
        base = {'b':{'text':'abc\n','revision':'1'}}
        self.assertEqual(envelope(p, base)['context'], {'kind':'unchanged','revision':'1'})
        self.assertEqual(envelope(p, {})['context']['kind'], 'snapshot')
        self.assertEqual(base['b']['revision'], '1')

    def test_edits_reject_missing_duplicate_extra_and_block_newline(self):
        targets = [{'id':'a','block':True}]
        for raw in ('{"status":"ok","replacements":[]}', '{"status":"ok","replacements":[{"id":"b","text":"x"}]}', '{"status":"ok","replacements":[{"id":"a","text":"x"},{"id":"a","text":"y"}]}', '{"status":"ok","replacements":[{"id":"a","text":"x\\ny"}]}'):
            with self.assertRaises(ValueError):
                validate_edit(raw, targets)
        self.assertEqual(validate_edit('{"status":"ok","replacements":[{"id":"a","text":""}]}', targets)['replacements'][0]['text'], '')


if __name__ == '__main__':
    unittest.main()
