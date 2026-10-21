"""Pure request contracts, independent of the SDK and editor."""
import json
import re

EFFORTS = {'low', 'medium', 'high', 'xhigh', 'max'}
# Native selectors documented by the runtime, not arbitrary numeric suffixes.
NATIVE_1M = {'claude-opus-4-6', 'claude-sonnet-4-6', 'opus', 'sonnet'}
PUNCTUATION = {'—': '-', '–': '-', '‘': "'", '’': "'", '“': '"', '”': '"', '…': '...', '\u00a0': ' '}


def number(value):
    match = re.fullmatch(r'(\d+(?:\.\d+)?)([km]?)', value.lower())
    if not match:
        raise ValueError('Expected a positive token count, optionally suffixed k or m')
    result = float(match[1]) * {'': 1, 'k': 1000, 'm': 1000000}[match[2]]
    if result <= 0 or not result.is_integer():
        raise ValueError('Token budget must be a positive integer')
    return int(result)


def parse_model(expression, current):
    config = dict(current)
    model = expression.strip()
    if not model:
        raise ValueError('Model cannot be empty')
    prefix, sep, suffix = model.rpartition(':')
    if sep and suffix in EFFORTS:
        model, config['effort'] = prefix, suffix
    explicit = re.search(r'\[limit=([^\]]+)\]$', model)
    if explicit:
        config['context_limit_tokens'] = number(explicit[1])
        model = model[:explicit.start()]
    else:
        groups = list(re.finditer(r'\[(\d+(?:\.\d+)?[km]?)\]', model, re.I))
        if groups and groups[-1].end() == len(model):
            last = groups[-1]
            native = last[1].lower() == '1m' and model[:last.start()] in NATIVE_1M
            if len(groups) > 1 or not native:
                config['context_limit_tokens'] = number(last[1])
                model = model[:last.start()]
    if not model:
        raise ValueError('Model cannot be empty')
    config['model'] = model
    return config


def normalize(text, policy):
    if policy == 'allow':
        return text
    return ''.join(PUNCTUATION.get(c, c) if policy == 'replace' else ('' if c in PUNCTUATION else c) for c in text)


def edit_result(raw, targets, block=False):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('Duplicate JSON field: ' + key)
            result[key] = value
        return result
    result = json.loads(raw, object_pairs_hook=unique)
    if not isinstance(result, dict):
        raise ValueError('Edit response must be an object')
    if result.get('status') == 'needs_input':
        if not isinstance(result.get('message'), str) or 'replacements' in result:
            raise ValueError('Invalid clarification envelope')
        return result
    if result.get('status') != 'ok' or not isinstance(result.get('replacements'), list):
        raise ValueError('Expected an ok edit envelope')
    expected = {t['id'] for t in targets}
    seen = set()
    for item in result['replacements']:
        if not isinstance(item, dict) or not isinstance(item.get('text'), str):
            raise ValueError('Every replacement needs a string text')
        ident = item.get('id')
        if not isinstance(ident, str) or ident not in expected or ident in seen:
            raise ValueError('Unknown or duplicate target ID')
        if '\x00' in item['text'] or (block and ('\n' in item['text'] or '\r' in item['text'])):
            raise ValueError('Invalid character in replacement')
        seen.add(ident)
    if seen != expected:
        raise ValueError('Missing replacement target')
    return result


def byte_bound(system, history, prompt, turns):
    # UTF-8 bytes bound text-token count. The fixed reserve covers runtime
    # framing/attachments, and a per-turn reserve covers message separators.
    return len(system.encode()) + history + len(prompt.encode()) + 16384 + 256 * (turns + 1)
