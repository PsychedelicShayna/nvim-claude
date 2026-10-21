"""Pure protocol rules shared by all bridge operations."""
import copy
import difflib
import json
import re

EFFORTS = {'low', 'medium', 'high', 'xhigh', 'max'}
# These selectors are documented native variants, not local budget syntax.
NATIVE = {'claude-opus-4-6': {'1m'}, 'claude-sonnet-4-6': {'1m'}}
OVERHEAD = 16384
OUTPUT_RESERVE = 4096


def byte_bound(value):
    return len(value.encode('utf-8'))


def parse_expression(expression, current, models=()):
    result = dict(current)
    text = expression.strip()
    prefix, sep, suffix = text.rpartition(':')
    if sep and suffix in EFFORTS:
        text, result['effort'] = prefix, suffix
    groups = list(re.finditer(r'\[(?:limit=)?(\d+(?:\.\d+)?)([km]?)\]', text))
    if groups and groups[-1].end() == len(text):
        last = groups[-1]
        base = text[:last.start()]
        selector = last.group(1) + last.group(2)
        native = selector in NATIVE.get(base, set()) or any(m.get('value') == text for m in models)
        if last.group().startswith('[limit=') or len(groups) > 1 or not native:
            result['context_limit_tokens'] = int(float(last.group(1)) * {'': 1, 'k': 1000, 'm': 1000000}[last.group(2)])
            text = base
        else:
            result['context_limit_tokens'] = None
    if not text:
        raise ValueError('A runtime model ID is required')
    result['model'] = text
    if not (sep and suffix in EFFORTS):
        metadata = next((m for m in models if text in (m.get('value'), m.get('resolvedModel'))), {})
        if result.get('effort') not in metadata.get('supportedEffortLevels', []):
            result['effort'] = None
    return result


def validate_config(config, models):
    model = config['model']
    metadata = next((m for m in models if model in (m.get('value'), m.get('resolvedModel'))), None)
    effort = config.get('effort')
    if effort is not None:
        if effort not in EFFORTS:
            raise ValueError('Unknown effort')
        if metadata is None or effort not in metadata.get('supportedEffortLevels', []):
            raise ValueError('Runtime has not announced this effort for the selected model. Set effort=null for a manual model without verified effort support.')
    limit = config.get('context_limit_tokens')
    if limit is not None and (isinstance(limit, bool) or not isinstance(limit, int) or limit <= OVERHEAD + OUTPUT_RESERVE):
        raise ValueError('Budget must exceed the 16,384-token runtime allowance plus 4,096-token output reservation')
    return config


def edit_result(raw, envelope):
    if envelope['operation'] == 'ask':
        return {'status': 'ok', 'text': raw}
    try:
        result = json.loads(raw)
    except ValueError as error:
        raise ValueError('Invalid edit JSON; raw output retained in the result float') from error
    if not isinstance(result, dict):
        raise ValueError('Edit result must be an object')
    if result.get('status') == 'needs_input':
        if not isinstance(result.get('message'), str) or result.get('replacements'):
            raise ValueError('Invalid clarification envelope')
        return {**result, 'text': raw}
    expected = {t['id']: t for t in envelope['targets']}
    replacements = result.get('replacements')
    if result.get('status') != 'ok' or not isinstance(replacements, list) or len(replacements) != len(expected):
        raise ValueError('Edit must contain exactly one replacement per target')
    seen = set()
    for replacement in replacements:
        if not isinstance(replacement, dict):
            raise ValueError('Invalid replacement')
        ident, text = replacement.get('id'), replacement.get('text')
        if not isinstance(ident, str) or ident not in expected or ident in seen or not isinstance(text, str):
            raise ValueError('Missing, duplicate, extra or non-string replacement')
        if '\x00' in text or ('\n' in text and expected[ident].get('block')):
            raise ValueError('NUL or multiline blockwise replacement rejected')
        seen.add(ident)
    return {**result, 'text': raw}


def context_envelope(envelope, baselines):
    """Append a named diff only against confirmed, exact context."""
    value = copy.deepcopy(envelope)
    context = value.get('context')
    doc = value.get('document', {}).get('id')
    if not context or context.get('kind') != 'snapshot' or not doc:
        return value
    old = baselines.get(doc)
    if old:
        if old['text'] == context['text']:
            value['context'] = {'kind': 'unchanged', 'revision': old['revision']}
        else:
            patch = ''.join(difflib.unified_diff(old['text'].splitlines(True), context['text'].splitlines(True), fromfile=old['revision'], tofile=context['revision']))
            diff = {'kind': 'diff', 'document_id': doc, 'base_revision': old['revision'], 'revision': context['revision'], 'text': patch}
            if byte_bound(json.dumps(diff)) < byte_bound(json.dumps(context)):
                value['context'] = diff
    return value


def excerpt(envelope, available):
    """Retain targets exactly; bound only explicitly incomplete context."""
    value = copy.deepcopy(envelope)
    context = value.get('context', {})
    if context.get('kind') != 'snapshot' or not value.get('targets'):
        return value
    lines = context['text'].split('\n')
    first = min(t['start'][0] for t in value['targets'])
    last = max(t['end'][0] for t in value['targets'])
    # An all-file target must not turn into a silently partial whole-file task.
    if first == 0 and last >= len(lines) - 1:
        return value
    lo, hi = max(0, first - 3), min(len(lines), last + 4)
    value['context'] = {'kind': 'excerpt', 'revision': context['revision'], 'start_row': lo, 'end_row': hi, 'omitted_before': lo, 'omitted_after': len(lines) - hi, 'text': '\n'.join(lines[lo:hi])}
    return value
