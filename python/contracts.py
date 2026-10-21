"""Pure model-input, output, and budget rules. No editor or SDK state."""
import difflib
import json
import re

EFFORTS = ('low', 'medium', 'high', 'xhigh', 'max')
PRESETS = [50000, 90000, 100000, 124000, 150000, 164000, 200000, 224000,
           256000, 258000, 274000, 278000, 300000, 374000, 378000, 384000,
           412000, 456000, 500000, 512000, 600000, 650000, 700000, 750000,
           800000, 850000, 900000, 950000, 980000]
NORMALIZE = {'\u2014': '-', '\u2013': '-', '\u2018': "'", '\u2019': "'",
             '\u201c': '"', '\u201d': '"', '\u2026': '...', '\u00a0': ' '}
# Reserve covers runtime message wrappers, compact instructions, and framing.
# Text is bounded by UTF-8 bytes rather than a chars/4 token estimate.
OVERHEAD = 8192
OUTPUT_RESERVE = 8192


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'))


def byte_bound(value):
    return len(value.encode('utf-8'))


def parse_model(expression, current, native=()):
    result = dict(current)
    model = expression.strip()
    if not model:
        raise ValueError('Model must not be empty')
    head, sep, tail = model.rpartition(':')
    if sep and tail in EFFORTS:
        model, result['effort'] = head, tail
    match = re.search(r'\[(limit=)?(\d+(?:\.\d+)?)([km]?)\]$', model, re.I)
    if match:
        groups = re.findall(r'\[(?:limit=)?\d+(?:\.\d+)?[km]?\]', model, re.I)
        recognized = model in native or model in ('claude-opus-4-6[1m]',)
        if match[1] or len(groups) > 1 or not recognized:
            value = float(match[2]) * {'': 1, 'k': 1000, 'm': 1000000}[match[3].lower()]
            if value < 1 or int(value) != value:
                raise ValueError('Context budget must be a positive integer')
            result['context_limit_tokens'] = int(value)
            model = model[:match.start()]
        else:
            result['context_limit_tokens'] = None
    result['model'] = model
    if not model:
        raise ValueError('Model must not be empty')
    return result


def normalize(text, policy):
    if policy == 'allow':
        return text
    return ''.join(NORMALIZE.get(c, c) if policy == 'replace' else
                   ('' if c in NORMALIZE else c) for c in text)


def edit_result(raw, targets, block=False):
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise ValueError('Edit response must be an object')
    if value.get('status') == 'needs_input':
        if not isinstance(value.get('message'), str) or value.get('replacements'):
            raise ValueError('Invalid clarification envelope')
        return value
    replacements = value.get('replacements')
    if value.get('status') != 'ok' or not isinstance(replacements, list):
        raise ValueError('Expected a completed edit or clarification')
    ids = [t['id'] for t in targets]
    seen = []
    for replacement in replacements:
        if not isinstance(replacement, dict) or not isinstance(replacement.get('text'), str):
            raise ValueError('Each replacement needs an ID and string text')
        seen.append(replacement.get('id'))
        if block and ('\n' in replacement['text'] or '\r' in replacement['text']):
            raise ValueError('Block replacements must stay on their rows')
    if len(seen) != len(ids) or len(set(seen)) != len(seen) or set(seen) != set(ids):
        raise ValueError('Replacement IDs do not match the captured targets')
    return value


def context_for(document, baseline):
    revision, text = document['revision'], document['text']
    snapshot = {'kind': 'snapshot', 'revision': revision, 'text': text}
    if not baseline:
        return snapshot
    old_revision, old_text = baseline
    if text == old_text:
        return {'kind': 'unchanged', 'revision': old_revision}
    chunks = difflib.unified_diff(old_text.splitlines(True), text.splitlines(True),
                                  fromfile=old_revision, tofile=revision)
    patch = ''.join(chunk if chunk.endswith('\n') else
                    chunk + '\n\\ No newline at end of file\n' for chunk in chunks)
    diff = {'kind': 'diff', 'document_id': document['id'], 'base_revision': old_revision,
            'revision': revision, 'text': patch}
    return diff if byte_bound(encode(diff)) < byte_bound(encode(snapshot)) else snapshot


def excerpt(document, targets, max_bytes):
    """Bound context around intact targets. Whole-document instructions opt out."""
    lines = document['text'].split('\n')
    first = min(t['start'][0] for t in targets)
    last = max(t['end'][0] for t in targets)
    start, end = max(0, first - 12), min(len(lines), last + 13)
    while True:
        value = {'kind': 'excerpt', 'revision': document['revision'],
                 'start_row': start, 'end_row': end, 'total_rows': len(lines),
                 'omitted_before': start > 0, 'omitted_after': end < len(lines),
                 'text': '\n'.join(lines[start:end])}
        if byte_bound(encode(value)) <= max_bytes:
            return value
        if start < first:
            start += 1
        elif end > last + 1:
            end -= 1
        else:
            raise ValueError('The intact target and mandatory context exceed the budget')
