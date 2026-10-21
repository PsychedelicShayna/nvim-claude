"""Pure request encoding, model-expression parsing, and response validation."""
import difflib
import json
import re

EFFORTS = ('low', 'medium', 'high', 'xhigh', 'max')
PRESETS = [50000, 90000, 100000, 124000, 150000, 164000, 200000, 224000, 256000, 258000, 274000, 278000, 300000, 374000, 378000, 384000, 412000, 456000, 500000, 512000, 600000, 650000, 700000, 750000, 800000, 850000, 900000, 950000, 980000]
PUNCTUATION = {'\u2014': '-', '\u2013': '-', '\u2018': "'", '\u2019': "'", '\u201c': '"', '\u201d': '"', '\u2026': '...', '\u00a0': ' '}


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'))


def parse_model(expression, current, catalogue):
    result = dict(current)
    model = expression.strip()
    match = re.search(r':(low|medium|high|xhigh|max)$', model)
    if match:
        result['effort'] = match[1]
        model = model[:match.start()]
    groups = list(re.finditer(r'\[(limit=)?(\d+(?:\.\d+)?)([km]?)\]', model, re.I))
    if groups and groups[-1].end() == len(model):
        last = groups[-1]
        native = any(m.get('value') == model or m.get('resolvedModel') == model for m in catalogue)
        # The specification explicitly recognizes Opus 4.6's native 1m selector.
        native = native or model == 'claude-opus-4-6[1m]'
        if last[1] or len(groups) > 1 or not native:
            limit = int(float(last[2]) * {'': 1, 'k': 1000, 'm': 1000000}[last[3].lower()])
            if limit <= 0:
                raise ValueError('Context limit must be positive')
            result['context_limit_tokens'] = limit
            model = model[:last.start()]
        else:
            result['context_limit_tokens'] = None
    if not model:
        raise ValueError('A model ID is required')
    if model != current.get('model') and not match:
        entry = next((m for m in catalogue if model in (m.get('value'), m.get('resolvedModel'))), {})
        if result.get('effort') not in entry.get('supportedEffortLevels', []):
            result['effort'] = None
    result['model'] = model
    return result


def present(text, mode, mapping=None):
    mapping = PUNCTUATION if mapping is None else mapping
    if mode == 'allow':
        return text
    return ''.join(('' if mode == 'remove' else mapping[c]) if c in mapping else c for c in text)


def validate_edit(raw, targets, block=False):
    data = json.loads(raw)
    if not isinstance(data, dict):
        raise ValueError('Edit response must be an object')
    if data.get('status') == 'needs_input':
        if not isinstance(data.get('message'), str) or data.get('replacements'):
            raise ValueError('Invalid clarification response')
        return data
    if data.get('status') != 'ok' or not isinstance(data.get('replacements'), list):
        raise ValueError('Expected an ok response with replacements')
    ids = [t['id'] for t in targets]
    replacements = data['replacements']
    found = []
    for item in replacements:
        if not isinstance(item, dict) or not isinstance(item.get('text'), str) or not isinstance(item.get('id'), str):
            raise ValueError('Every replacement needs a string ID and text')
        if '\x00' in item['text'] or (block and ('\n' in item['text'] or '\r' in item['text'])):
            raise ValueError('NUL or multiline block replacement is not valid buffer text')
        found.append(item['id'])
    if len(found) != len(ids) or len(set(found)) != len(found) or set(found) != set(ids):
        raise ValueError('Missing, duplicate, or unexpected replacement target')
    return data


def context_for(document, baseline):
    text, revision = document['text'], document['revision']
    snapshot = {'kind': 'snapshot', 'revision': revision, 'text': text}
    if not baseline:
        return snapshot
    if baseline['text'] == text:
        return {'kind': 'unchanged', 'revision': baseline['revision']}
    diff = ''.join(difflib.unified_diff(baseline['text'].splitlines(keepends=True), text.splitlines(keepends=True), fromfile=baseline['revision'], tofile=revision))
    # A final line without newline makes a unified diff ambiguous; send a snapshot.
    if len(diff) >= len(text) or not text.endswith('\n') or not baseline['text'].endswith('\n'):
        return snapshot
    return {'kind': 'diff', 'base_revision': baseline['revision'], 'revision': revision, 'format': 'unified', 'text': diff}


def make_envelope(request, baselines):
    data = {k: request[k] for k in ('operation', 'instruction')}
    if request.get('document'):
        doc = request['document']
        data['document'] = {k: doc[k] for k in ('id', 'filetype')}
        data['context'] = context_for(doc, baselines.get(doc['id']))
        data['targets'] = request['targets']
    return data
