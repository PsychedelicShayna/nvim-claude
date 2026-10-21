"""Pure request and model contracts shared by the bridge and focused checks."""
import difflib
import json
import re

EFFORTS = {'low', 'medium', 'high', 'xhigh', 'max'}


def number(value):
    m = re.fullmatch(r'(\d+(?:\.\d+)?)([km]?)', value.lower())
    if not m:
        raise ValueError('Budget must be a positive token count with optional k/m suffix')
    result = float(m[1]) * {'': 1, 'k': 1000, 'm': 1000000}[m[2]]
    if result <= 0 or not result.is_integer():
        raise ValueError('Budget must be a positive whole number of tokens')
    return int(result)


def parse_model(expression, current, models):
    result = dict(current)
    value = expression.strip()
    if not value:
        raise ValueError('Model cannot be empty')
    base, sep, effort = value.rpartition(':')
    if sep and effort in EFFORTS:
        result['effort'], value = effort, base
    groups = re.findall(r'\[([^\]]+)\]', value)
    suffix = re.search(r'\[([^\]]+)\]$', value)
    native = {m['value'] for m in models}
    # This documented native selector predates runtime picker changes.
    native.add('claude-opus-4-6[1m]')
    if suffix:
        part = suffix[1]
        if part.startswith('limit='):
            result['context_limit_tokens'] = number(part[6:])
            value = value[:suffix.start()]
        elif re.fullmatch(r'\d+(?:\.\d+)?[km]?', part, re.I) and (len(groups) > 1 or value not in native):
            if part.lower() == '1m' and len(groups) == 1 and value not in native:
                raise ValueError('Unverified native [1m] selector; use raw model fields or [limit=1m]')
            result['context_limit_tokens'] = number(part)
            value = value[:suffix.start()]
        elif value in native and len(groups) == 1:
            result['context_limit_tokens'] = None
    result['model'] = value
    metadata = next((m for m in models if value in (m['value'], m.get('resolvedModel'))), None)
    if metadata and not metadata.get('supportsEffort'):
        if sep and effort in EFFORTS:
            raise ValueError('Runtime does not advertise effort for this model')
        result['effort'] = None
    elif metadata and result.get('effort') is not None and result['effort'] not in metadata.get('supportedEffortLevels', []):
        raise ValueError('Effort is not announced for this model')
    return result


def envelope(params, baselines):
    out = {k: params[k] for k in ('operation', 'instruction', 'document', 'targets') if k in params}
    if 'document' in params:
        key, text, revision = params['document']['id'], params['snapshot'], params['revision']
        old = baselines.get(key)
        context = {'kind': 'snapshot', 'revision': revision, 'text': text}
        if old and old['text'] == text:
            context = {'kind': 'unchanged', 'revision': old['revision']}
        elif old:
            diff = ''.join(difflib.unified_diff(old['text'].splitlines(True), text.splitlines(True), fromfile=old['revision'], tofile=revision))
            # Missing terminal newlines make unified diffs ambiguous.
            if len(diff) < len(text) and text.endswith('\n') and old['text'].endswith('\n'):
                context = {'kind': 'diff', 'document_id': key, 'base_revision': old['revision'], 'revision': revision, 'text': diff}
        out['context'] = context
    return out


def validate_edit(raw, targets):
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise ValueError('Edit response must be an object')
    if value.get('status') == 'needs_input' and isinstance(value.get('message'), str) and 'replacements' not in value:
        return value
    items = value.get('replacements')
    if value.get('status') != 'ok' or not isinstance(items, list):
        raise ValueError('Invalid edit result status or replacements')
    expected = {t['id']: t for t in targets}
    seen = set()
    for item in items:
        if not isinstance(item, dict) or not isinstance(item.get('text'), str):
            raise ValueError('Replacement text must be a string')
        key = item.get('id')
        if key not in expected or key in seen:
            raise ValueError('Duplicate or unknown target')
        if expected[key].get('block') and '\n' in item['text']:
            raise ValueError('Blockwise replacements cannot contain newlines')
        seen.add(key)
    if seen != set(expected):
        raise ValueError('Missing replacement target')
    return value
