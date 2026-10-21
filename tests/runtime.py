"""Opt-in real SDK acceptance run. One runtime, sequential Haiku requests."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument('--state', required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
process = subprocess.Popen([sys.executable, str(root / 'python/bridge.py'), '--state', args.state],
                           stdin=subprocess.PIPE, stdout=subprocess.PIPE)
serial = 0
statuses = []


def call(method, params=None, error=False):
    global serial
    serial += 1
    body = json.dumps({'jsonrpc': '2.0', 'id': serial, 'method': method, 'params': params or {}}).encode()
    process.stdin.write(f'Content-Length: {len(body)}\r\n\r\n'.encode() + body)
    process.stdin.flush()
    while True:
        headers = {}
        while True:
            line = process.stdout.readline()
            if not line:
                raise RuntimeError('Bridge exited unexpectedly')
            if line == b'\r\n':
                break
            name, value = line.decode().split(':', 1)
            headers[name.lower()] = value.strip()
        message = json.loads(process.stdout.read(int(headers['content-length'])))
        if message.get('method') == 'status':
            statuses.append(message['params']['message'])
        if message.get('id') == serial:
            if error:
                assert 'error' in message, message
                return message['error']
            if 'error' in message:
                raise RuntimeError(message['error']['message'])
            return message['result']


try:
    info = call('initialize')
    assert info['versions']['cli'] == '2.1.306', info['versions']
    models = call('models')['models']
    assert any(m.get('resolvedModel') == 'claude-haiku-5-5' for m in models)
    refusal = call('request', {'operation': 'ask', 'instruction': 'x' * 100001, 'generation': 1}, error=True)
    assert 'exceeds' in refusal['message']
    result = call('request', {'operation': 'replace', 'instruction': 'Replace the dots with quick. Return the edit envelope.',
        'document': {'id': 'test-buffer', 'filetype': 'text', 'revision': 'r1', 'text': 'The ... brown fox.'},
        'targets': [{'id': 't', 'start': [0, 4], 'end': [0, 7], 'text': '...', 'coordinates': 'zero-based UTF-8 bytes; end-exclusive'}], 'generation': 2})
    assert result['edit']['replacements'] == [{'id': 't', 'text': 'quick'}], result
    assert result['budget']['actual_prompt_tokens'] <= result['budget']['conservative_bound'] <= 100000
    saved = call('save')['saved']
    original = json.loads((Path(args.state) / 'conversations' / (saved + '.json')).read_text())
    sid = original['sdk_id']
    assert original['runtime_init']['tools'] == []
    call('new')
    call('resume', {'id': saved})
    answer = call('request', {'operation': 'ask', 'instruction': 'What word did you just put in place of the dots? Answer with that word only.', 'generation': 3})
    assert 'quick' in answer['text'].lower(), answer
    resumed = json.loads((Path(args.state) / 'conversations' / (saved + '.json')).read_text())
    assert resumed['sdk_id'] == sid
    assert resumed['raw'][0] == original['raw'][0]
    call('compact')
    call('system', {'prompt': 'For every user request, reply with exactly override-ok. You have no tools.'})
    answer = call('request', {'operation': 'ask', 'instruction': 'Respond now.', 'generation': 4})
    assert answer['text'].strip() == 'override-ok', answer
    call('system')
    call('new')
    large = call('request', {'operation': 'ask', 'instruction': 'Reply exactly boundary-ok. Ignore the following padding: ' + 'abc ' * 19000, 'generation': 5})
    assert 'boundary-ok' in large['text'], large
    assert large['budget']['conservative_bound'] <= 100000
    before = statuses.count('compacting')
    small = call('request', {'operation': 'ask', 'instruction': 'Reply exactly after-compact.', 'generation': 6})
    assert 'after-compact' in small['text'], small
    assert statuses.count('compacting') > before
    print(json.dumps({'versions': info['versions'], 'catalogue_models': len(models),
                      'replacement_budget': result['budget'], 'large_fresh_budget': large['budget'],
                      'continued_budget': small['budget'], 'manual_and_automatic_compaction': True,
                      'exact_sdk_session_resumed': True, 'next_request_prompt_override': True}))
finally:
    process.stdin.close()
    try:
        process.wait(timeout=15)
    except subprocess.TimeoutExpired:
        process.terminate()
        process.wait(timeout=5)
    from claude_agent_sdk import delete_session
    for path in (Path(args.state) / 'conversations').glob('*.json'):
        record = json.loads(path.read_text())
        if record.get('sdk_id'):
            delete_session(record['sdk_id'], directory=record['cwd'])
        path.unlink()
assert process.returncode == 0, process.returncode
