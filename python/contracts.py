"""Pure model input/output rules; no editor or SDK state."""
import difflib
import json
import re

EFFORTS = ('low', 'medium', 'high', 'xhigh', 'max')
PRESETS = [50000, 90000, 100000, 124000, 150000, 164000, 200000, 224000,
           256000, 258000, 274000, 278000, 300000, 374000, 378000, 384000,
           412000, 456000, 500000, 512000, 600000, 650000, 700000, 750000,
           800000, 850000, 900000, 950000, 980000]
PUNCTUATION = {'—': '-', '–': '-', '‘': "'", '’': "'", '“': '"', '”': '"',
               '…': '...', '\u00a0': ' '}
# Runtime-documented opt-in selectors, not a model picker catalogue.
NATIVE_1M = {'claude-opus-4-6', 'claude-sonnet-4-6', 'claude-sonnet-4-5',
             'claude-sonnet-4-5-20250929', 'claude-sonnet-4', 'claude-sonnet-4-20250514'}


def parse_model(expression, current):
    result = dict(current)
    model = expression.strip()
    if not model:
        raise ValueError('Model must not be empty')
    suffix = model.rsplit(':', 1)
    if len(suffix) == 2 and suffix[1] in EFFORTS:
        model, result['effort'] = suffix
    groups = list(re.finditer(r'\[(limit=)?(\d+(?:\.\d+)?)([km]?)\]', model))
    if groups and groups[-1].end() == len(model):
        last = groups[-1]
        native = (len(groups) == 1 and model[:last.start()] in NATIVE_1M
                  and last.group(0) == '[1m]')
        if native:
            result['context_limit_tokens'] = None
        if last.group(1) or not native:
            number = float(last.group(2)) * {'': 1, 'k': 1000, 'm': 1000000}[last.group(3)]
            if number <= 0 or number != int(number):
                raise ValueError('Context budget must be a positive whole number')
            result['context_limit_tokens'] = int(number)
            model = model[:last.start()]
    if not model:
        raise ValueError('Model must not be empty')
    result['model'] = model
    return result


def normalize(text, policy):
    if policy == 'allow':
        return text
    if policy not in ('replace', 'remove'):
        raise ValueError('Punctuation policy must be allow, replace, or remove')
    return ''.join(PUNCTUATION.get(c, c) if policy == 'replace'
                   else ('' if c in PUNCTUATION else c) for c in text)


def edit_result(raw, targets, block=False):
    result = json.loads(raw)
    if not isinstance(result, dict):
        raise ValueError('Edit response must be a JSON object')
    if result.get('status') == 'needs_input':
        if not isinstance(result.get('message'), str) or result.get('replacements'):
            raise ValueError('Invalid clarification envelope')
        return result
    replacements = result.get('replacements')
    if result.get('status') != 'ok' or not isinstance(replacements, list):
        raise ValueError('Invalid edit status or replacements')
    expected = {t['id'] for t in targets}
    seen = set()
    for item in replacements:
        if (not isinstance(item, dict) or item.get('id') not in expected
                or item['id'] in seen or not isinstance(item.get('text'), str)):
            raise ValueError('Missing, duplicate, or unknown replacement target')
        if '\x00' in item['text'] or (block and '\n' in item['text']):
            raise ValueError('Replacement contains an invalid line boundary')
        seen.add(item['id'])
    if seen != expected:
        raise ValueError('Response omitted a target')
    return result


def context_for(document, baseline):
    text, revision = document['text'], document['revision']
    snapshot = {'kind': 'snapshot', 'revision': revision, 'text': text}
    if not baseline:
        return snapshot
    old_revision, old_text = baseline
    if text == old_text:
        return {'kind': 'unchanged', 'revision': old_revision}
    diff = ''.join(difflib.unified_diff(old_text.splitlines(True), text.splitlines(True),
                                      fromfile=old_revision, tofile=revision))
    # A missing final newline makes unified diffs ambiguous without extra markers.
    if len(diff) >= len(text) or not old_text.endswith('\n') or not text.endswith('\n'):
        return snapshot
    return {'kind': 'diff', 'base_revision': old_revision, 'revision': revision,
            'document_id': document['id'], 'text': diff}


def encode_request(params, baseline):
    request = {k: params[k] for k in ('operation', 'instruction')}
    if params.get('targets'):
        request['targets'] = params['targets']
    if params.get('block'):
        request['blockwise'] = True
    document = params.get('document')
    if document:
        request['document'] = {'id': document['id'], 'filetype': document['filetype']}
        request['context'] = context_for(document, baseline)
    return request
