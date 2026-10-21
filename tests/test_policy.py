import pathlib
import sys
import unittest
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'python'))
from policy import (OVERHEAD, edit_result, encode, enforce_budget, excerpt, make_context,
                    normalize, parse_model, prompt_bound)


class RequestPolicy(unittest.TestCase):
    def test_model_expression_preserves_native_variants_and_colons(self):
        current = {'model': 'old', 'effort': 'low', 'context_limit_tokens': 100000}
        native = {'claude-opus-4-6[1m]'}
        self.assertEqual(parse_model('claude-haiku-5-5[100k]:low', current)['model'], 'claude-haiku-5-5')
        value = parse_model('claude-opus-4-6[1m][500k]:high', current, native)
        self.assertEqual(value, {'model': 'claude-opus-4-6[1m]', 'effort': 'high', 'context_limit_tokens': 500000})
        self.assertIsNone(parse_model('claude-opus-4-6[1m]:high', current, native)['context_limit_tokens'])
        self.assertEqual(parse_model('provider:model:variant', current)['model'], 'provider:model:variant')
        self.assertEqual(parse_model('custom[unknown]', current)['model'], 'custom[unknown]')
        self.assertIsNone(parse_model('custom[limit=default]', current)['context_limit_tokens'])

    def test_literal_deletion_and_code_fences_survive_decoding(self):
        targets = [{'id': 'a'}]
        self.assertEqual(edit_result('{"status":"ok","replacements":[{"id":"a","text":""}]}', targets)['replacements'][0]['text'], '')
        raw = encode({'status': 'ok', 'replacements': [{'id': 'a', 'text': '  ```\ncode\n```\n'}]})
        self.assertEqual(edit_result(raw, targets)['replacements'][0]['text'], '  ```\ncode\n```\n')

    def test_invalid_envelopes_cannot_edit(self):
        targets = [{'id': 'a', 'blockwise': True}]
        for raw in [
            '{"status":"ok","replacements":[]}',
            '{"status":"ok","replacements":[{"id":"b","text":"x"}]}',
            '{"status":"ok","replacements":[{"id":"a","text":"x"},{"id":"a","text":"y"}]}',
            '{"status":"ok","replacements":[{"id":"a","text":null}]}',
            '{"status":"ok","replacements":[{"id":"a","text":"x\\ny"}]}',
            '{"status":"ok","status":"needs_input","message":"x"}',
        ]:
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                edit_result(raw, targets)
        self.assertEqual(edit_result('{"status":"needs_input","message":"Which language?"}', targets)['status'], 'needs_input')

    def test_budget_accounts_for_history_utf8_and_runtime(self):
        bound = prompt_bound('system', ['αβ', 'answer'], 'new')
        self.assertEqual(bound, OVERHEAD + 6 + 4 + 128 + 6 + 128 + 3)
        self.assertEqual(enforce_budget('system', ['αβ', 'answer'], 'new', bound, 1000000), bound)
        with self.assertRaises(ValueError):
            enforce_budget('system', ['αβ', 'answer'], 'new', bound - 1, 1000000)
        with self.assertRaises(ValueError):
            enforce_budget('', [], 'x' * 100000, 100000, 1000000)
        with self.assertRaises(ValueError):
            enforce_budget('', [], 'x' * 90000, None, 100000)

    def test_confirmed_baselines_and_explicit_excerpts(self):
        request = {'operation': 'replace', 'instruction': 'edit', 'document': {'id': 'b'},
                   'buffer_text': ('unchanged line\n' * 100) + 'target\n',
                   'targets': [{'id': 'a', 'start': [100, 0], 'end': [100, 6], 'text': 'target'}]}
        first, baseline = make_context(request, {})
        self.assertEqual(first['context']['kind'], 'snapshot')
        doc, revision, text = baseline
        same, _ = make_context(request, {doc: (revision, text)})
        self.assertEqual(same['context']['kind'], 'unchanged')
        request['buffer_text'] = text.replace('target', 'edited')
        changed, _ = make_context(request, {doc: (revision, text)})
        self.assertEqual(changed['context']['kind'], 'diff')
        bounded = excerpt(first, 100)
        self.assertEqual(bounded['context']['kind'], 'excerpt')
        self.assertEqual(bounded['targets'][0]['text'], 'target')
        whole = {**first, 'whole_document': True}
        self.assertEqual(excerpt(whole, 100)['context']['kind'], 'snapshot')
        self.assertNotIn('context', make_context({'operation': 'ask', 'instruction': 'hello'}, {})[0])

    def test_normalization_keeps_other_unicode_and_raw_history(self):
        raw = 'α—β…\u00a0“字”'
        self.assertEqual(normalize(raw, 'replace'), 'α-β... "字"')
        self.assertEqual(normalize(raw, 'remove'), 'αβ字')
        self.assertEqual(normalize(raw, 'allow'), raw)


if __name__ == '__main__':
    unittest.main()
