"""One lazy SDK client per editor, with request epochs and owned transcripts."""
import argparse
import asyncio
import dataclasses
import difflib
import json
import os
from pathlib import Path
import sys
import time

import claude_agent_sdk as sdk
from contracts import byte_bound, edit_result, normalize, parse_model, EFFORTS
from storage import Store

DEFAULT = {'model': 'claude-haiku-5-5', 'effort': 'low', 'context_limit_tokens': 100000}
PROMPT = (Path(__file__).resolve().parent.parent / 'resources/system.txt').read_text()
CLI = Path(sdk.__file__).parent / '_bundled' / 'claude'
MAX_FRAME = 16 * 1024 * 1024


def send(message):
    raw = json.dumps({'jsonrpc': '2.0', **message}, ensure_ascii=False).encode()
    sys.stdout.buffer.write(f'Content-Length: {len(raw)}\r\n\r\n'.encode() + raw)
    sys.stdout.buffer.flush()


def read_frame():
    headers = {}
    while True:
        line = sys.stdin.buffer.readline(8192)
        if not line:
            return None
        if line in (b'\r\n', b'\n'):
            break
        key, value = line.decode('ascii').split(':', 1)
        headers[key.lower()] = value.strip()
    size = int(headers['content-length'])
    if not 0 <= size <= MAX_FRAME:
        raise ValueError('RPC frame too large')
    body = sys.stdin.buffer.read(size)
    if len(body) != size:
        return None
    return json.loads(body)


class Bridge:
    def __init__(self, state):
        self.store = Store(Path(state) / 'conversations', sdk.delete_session)
        self.config = dict(DEFAULT)
        self.system = PROMPT
        self.client = None
        self.metadata = {}
        self.context = {}
        self.baselines = {}
        self.sticky = False
        self.policy = 'allow'
        self.epoch = 0
        self.active = None
        self.cancelled = False
        self.queue = asyncio.Queue()
        self.billing = 'subscription'
        self.budget_mode = 'strict'

    def event(self, kind, **data):
        if self.active:
            send({'method': 'event', 'params': {'id': self.active['id'], 'epoch': self.active.get('params', {}).get('epoch', self.epoch), 'kind': kind, **data}})

    async def close_client(self):
        if self.client:
            client, self.client = self.client, None
            await client.disconnect()

    def record(self):
        return self.store.record or self.store.new(self.config, self.sticky)

    async def connect(self, compaction=False):
        if self.client:
            return
        record = self.record()
        # Never allow an inherited paid credential to silently replace login.
        paid = ['ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_FOUNDRY_API_KEY', 'ANTHROPIC_AWS_API_KEY']
        if self.billing != 'environment' and any(os.environ.get(k) for k in paid):
            raise ValueError('API credentials are present. Set billing="environment" explicitly to use environment billing, or remove those variables and use :NvClaude login.')
        env = {
            'CLAUDE_CODE_SAFE_MODE': '1', 'CLAUDE_CODE_DISABLE_CLAUDE_MDS': '1',
            'CLAUDE_CODE_DISABLE_AUTO_MEMORY': '1', 'CLAUDE_CODE_DISABLE_BUNDLED_SKILLS': '1',
            'CLAUDE_AGENT_SDK_DISABLE_BUILTIN_AGENTS': '1', 'CLAUDE_CODE_DISABLE_ATTACHMENTS': '1',
            'CLAUDE_CODE_AUTO_CONNECT_IDE': 'false', 'CLAUDE_CODE_DISABLE_TERMINAL_TITLE': '1',
            'CLAUDE_CODE_DISABLE_BACKGROUND_TASKS': '1', 'CLAUDE_CODE_DISABLE_CRON': '1',
            'CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK': '1', 'CLAUDE_CODE_DISABLE_ADVISOR_TOOL': '1',
            'CLAUDE_CODE_MAX_OUTPUT_TOKENS': '4096', 'CLAUDE_CODE_EFFORT_LEVEL': self.config.get('effort') or '',
            'CLAUDE_CODE_AUTO_COMPACT_WINDOW': str(max(100000, min(1000000, self.config.get('context_limit_tokens') or 1000000))),
            'CLAUDE_AUTOCOMPACT_PCT_OVERRIDE': '50', 'CLAUDE_CODE_SKIP_PROMPT_HISTORY': '',
        }
        options = sdk.ClaudeAgentOptions(
            model=self.config['model'], effort=self.config.get('effort'), thinking={'type': 'disabled'},
            tools=[], mcp_servers={}, strict_mcp_config=True, setting_sources=[], skills=[], plugins=[], agents={},
            system_prompt={'type': 'custom', 'prompt': self.system, 'snapshot': False},
            cwd=record['cwd'], cli_path=str(CLI), include_partial_messages=True,
            resume=record['session_id'] if record['started'] else None,
            session_id=None if record['started'] else record['session_id'],
            env=env, extra_args={'safe-mode': None, 'no-chrome': None, **({} if compaction else {'disable-slash-commands': None})},
            settings=json.dumps({'disableAllHooks': True, 'idleCompaction': False}),
            stderr=lambda line: print(line, file=sys.stderr),
        )
        self.client = sdk.ClaudeSDKClient(options)
        try:
            await self.client.connect()
            self.metadata = await self.client.get_server_info() or {}
            self.context = await self.client.get_context_usage()
            if any(self.context.get(k) for k in ('memoryFiles', 'mcpTools', 'mcpInstructions', 'agents')):
                raise ValueError('Runtime supplied unexpected memory, agents or MCP context; refusing no-tools operation')
            if self.metadata.get('agents'):
                raise ValueError('Runtime did not disable subagents')
            model = next((m for m in self.metadata.get('models', []) if self.config['model'] in (m.get('value'), m.get('resolvedModel'))), None)
            if model and self.config.get('effort') and self.config['effort'] not in model.get('supportedEffortLevels', []):
                raise ValueError('Selected model does not announce this effort; configure effort=false')
        except Exception:
            await self.close_client()
            raise

    async def reset(self):
        await self.close_client()
        self.store.new(self.config, self.sticky)
        self.baselines.clear()

    def info(self):
        record = self.store.record or {}
        return {'config': self.config, 'resolved_model': self.context.get('model'),
                'conversation': record.get('id'), 'saved': record.get('saved', False), 'sticky': self.sticky,
                'occupancy': {k: v for k, v in self.context.items() if k not in ('gridRows',)},
                'cumulative_usage': record.get('usage', {}), 'sdk': sdk.__version__,
                'python': sys.version.split()[0], 'runtime': self.metadata.get('claude_code_version'),
                'billing': self.billing, 'subscription_type': self.metadata.get('account', {}).get('subscriptionType'),
                'cache': {'seconds': record.get('cache_ttl', 300), 'provenance': 'last API cache_creation usage, otherwise conservative five-minute estimate',
                          'remaining_estimate': max(0, record.get('last_request', 0) + record.get('cache_ttl', 300) - time.time())},
                'budget': {'method': 'UTF-8 byte upper bound for supplied text plus 16384 runtime reserve and 256 per turn',
                           'verified_hard_ceiling': False, 'limitation': 'Runtime-added input has no authoritative preflight bound in the SDK'},
                'models': self.metadata.get('models', [])}

    async def consume(self, prompt, compact=False):
        if self.cancelled:
            raise ValueError('Request canceled before model dispatch')
        record = self.record()
        record['history_bytes'] += len(prompt.encode())
        record['turns'] += 1
        await self.client.query(prompt)
        record['started'] = True
        self.store.flush()
        text, streamed, boundary, result = '', False, False, None
        async for message in self.client.receive_response():
            if isinstance(message, sdk.StreamEvent):
                event = message.event
                if event.get('type') == 'content_block_delta' and event.get('delta', {}).get('type') == 'text_delta':
                    delta = event['delta']['text']
                    text += delta
                    record['history_bytes'] += len(delta.encode())
                    streamed = True
                    self.event('partial', text=normalize(text, self.policy))
            elif isinstance(message, sdk.AssistantMessage):
                if message.error:
                    raise ValueError(str(message.error))
                final = ''.join(block.text for block in message.content if isinstance(block, sdk.TextBlock))
                if not streamed:
                    text += final
                    record['history_bytes'] += len(final.encode())
                    self.event('partial', text=normalize(text, self.policy))
            elif isinstance(message, sdk.SystemMessage):
                if message.subtype == 'init':
                    data = message.data
                    if data.get('tools') or data.get('mcp_servers') or data.get('agents') or (data.get('skills') and not compact):
                        await self.client.interrupt()
                        raise ValueError('Unexpected model-accessible capability in runtime initialization')
                elif message.subtype == 'compact_boundary':
                    boundary = True
                    record['history_bytes'] = 0
                    record['turns'] = 1
                    self.baselines.clear()
                    self.event('status', text='compacted; fresh context required')
                elif message.subtype == 'status' and message.data.get('status'):
                    self.event('status', text=message.data['status'])
            elif isinstance(message, sdk.UserMessage) and boundary:
                record['history_bytes'] += len(json.dumps(dataclasses.asdict(message), ensure_ascii=False).encode())
            elif isinstance(message, sdk.ResultMessage):
                result = message
        if self.cancelled:
            raise ValueError('Request canceled; no source edit applied')
        if not result or result.is_error or result.subtype != 'success':
            raise ValueError((getattr(result, 'result', None) or 'SDK did not complete successfully') + '; use :NvClaude login if authentication is missing')
        if compact and not boundary:
            raise ValueError('Runtime did not report a compaction boundary')
        record['session_id'] = result.session_id
        if result.session_id not in record['session_ids']:
            record['session_ids'].append(result.session_id)
        usage = result.usage or {}
        for key in ('input_tokens', 'output_tokens', 'cache_read_input_tokens', 'cache_creation_input_tokens'):
            record['usage'][key] = record['usage'].get(key, 0) + usage.get(key, 0)
        cache = usage.get('cache_creation', {})
        if cache.get('ephemeral_1h_input_tokens', 0):
            record['cache_ttl'] = 3600
        elif cache.get('ephemeral_5m_input_tokens', 0):
            record['cache_ttl'] = 300
        record['raw'].append({'prompt': prompt, 'response': text, 'compaction': compact, 'usage': usage})
        self.context = await self.client.get_context_usage()
        self.store.flush()
        return text, boundary

    def envelope(self, params):
        envelope = {k: params[k] for k in ('operation', 'instruction', 'targets') if k in params}
        document = params.get('document')
        baseline = None
        if document:
            ident, text, revision = document['id'], document['text'], document['revision']
            envelope['document'] = {k: document[k] for k in ('id', 'filetype')}
            prior = self.baselines.get(ident)
            context = {'kind': 'snapshot', 'revision': revision, 'text': text}
            if prior and prior['text'] == text:
                context = {'kind': 'unchanged', 'revision': prior['revision']}
            elif prior:
                diff = ''.join(difflib.unified_diff(prior['text'].splitlines(True), text.splitlines(True), fromfile=prior['revision'], tofile=revision))
                if len(diff.encode()) < len(text.encode()):
                    context = {'kind': 'diff', 'base_revision': prior['revision'], 'revision': revision, 'text': diff}
            envelope['context'] = context
            baseline = (ident, {'text': text, 'revision': revision})
        return envelope, baseline

    def prepare(self, params, limit):
        envelope, baseline = self.envelope(params)
        prompt = json.dumps(envelope, ensure_ascii=False)
        if limit and byte_bound(self.system, 0, prompt, 0) > limit:
            targets = envelope.get('targets', [])
            if envelope.get('context') and targets and not params.get('whole_file'):
                doc = params['document']['text'].splitlines(keepends=True)
                first = max(0, min(t['start'][0] for t in targets) - 4)
                last = min(len(doc), max(t['end'][0] for t in targets) + 5)
                envelope['context'] = {
                    'kind': 'excerpt', 'revision': params['document']['revision'],
                    'start_row': first, 'end_row': last, 'omitted_before': first,
                    'omitted_after': len(doc) - last, 'text': ''.join(doc[first:last]),
                }
                baseline = None
                prompt = json.dumps(envelope, ensure_ascii=False)
                if byte_bound(self.system, 0, prompt, 0) > limit:
                    envelope['context'] = {
                        'kind': 'excerpt', 'revision': params['document']['revision'],
                        'included': 'Only the intact targets and their explicit before/after boundary text in targets',
                        'omitted': 'All other document text',
                    }
                    prompt = json.dumps(envelope, ensure_ascii=False)
            if byte_bound(self.system, 0, prompt, 0) > limit:
                raise ValueError('Mandatory instruction and intact target cannot fit this budget; no request sent')
        return prompt, baseline

    async def compact(self):
        if self.config.get('context_limit_tokens') and self.budget_mode != 'conservative':
            raise ValueError('Unsupported hard budget for compaction: no authoritative runtime preflight bound; no request sent')
        # The CLI's disable-slash-commands flag also disables /compact.
        # Reopen this exact session only for the built-in compaction command.
        # tools=[] still prevents the summarizer from invoking any skill.
        await self.close_client()
        await self.connect(compaction=True)
        record = self.record()
        limit = self.config.get('context_limit_tokens')
        if limit and byte_bound(self.system, record['history_bytes'], '/compact', record['turns']) > limit:
            raise ValueError('Compaction itself cannot fit the conservative budget. Start :NvClaude new; saved history is retained.')
        self.event('status', text='compacting')
        record['last_request'] = time.time()
        await self.consume('/compact', compact=True)
        await self.close_client()
        await self.connect()
        self.baselines.clear()
        return self.info()

    async def turn(self, params):
        record = self.record()
        if not record['saved'] and record['last_request'] and time.time() - record['last_request'] > record['cache_ttl']:
            await self.reset()
            record = self.record()
        await self.connect()
        self.event('status', text=params['operation'] + (' · continued' if record['started'] else ' · new'))
        limit = self.config.get('context_limit_tokens')
        if limit and params.get('strict_budget', True):
            raise ValueError('Unsupported hard budget: the installed SDK exposes current usage but no authoritative bound on runtime-added input for the next request. No request sent. Explicitly choose budget_mode="conservative" to use the documented byte-bound estimate, or model default to remove the local ceiling.')
        prompt, baseline = self.prepare(params, limit)
        if limit:
            if byte_bound(self.system, record['history_bytes'], prompt, record['turns']) > limit * .70 and record['started']:
                await self.compact()
                prompt, baseline = self.prepare(params, limit)
            if byte_bound(self.system, record['history_bytes'], prompt, record['turns']) > limit:
                raise ValueError('Request does not fit after compaction; no edit request sent')
        if not record['first_prompt']:
            record['first_prompt'] = params['instruction']
        record['last_request'] = time.time()
        raw, compacted = await self.consume(prompt)
        if baseline and not compacted:
            self.baselines[baseline[0]] = baseline[1]
        elif params.get('document'):
            self.baselines.pop(params['document']['id'], None)
        if params['operation'] == 'ask':
            return {'text': normalize(raw, self.policy), 'raw': raw, 'info': self.info()}
        result = edit_result(raw, params['targets'], params.get('block', False))
        for replacement in result.get('replacements', []):
            replacement['text'] = normalize(replacement['text'], self.policy)
        return {**result, 'raw': raw, 'info': self.info()}

    async def dispatch(self, method, params):
        if method == 'initialize':
            self.config.update(params.get('config', {}))
            if self.config.get('effort') is False:
                self.config['effort'] = None
            self.billing = params.get('billing', 'subscription')
            self.budget_mode = params.get('budget_mode', 'strict')
            return {'protocol': 1, 'sdk': sdk.__version__, 'capabilities': ['stream', 'cancel', 'sessions', 'models', 'compact'], 'system': self.system}
        if method == 'turn':
            return await self.turn(params)
        if method in ('new', 'clear'):
            await self.reset()
        elif method == 'save':
            self.record()['saved'] = True
            self.store.flush()
        elif method == 'sticky':
            self.sticky = params.get('enabled', not self.sticky)
            if self.sticky:
                self.record()['saved'] = True
                self.store.flush()
        elif method == 'list':
            return self.store.saved()
        elif method == 'resume':
            await self.close_client()
            if self.store.record and self.store.record['id'] == params['id']:
                return self.info()
            self.config = dict(self.store.resume(params['id'])['config'])
            self.baselines.clear()
        elif method == 'models':
            await self.connect()
            return self.metadata.get('models', [])
        elif method == 'configure':
            config = parse_model(params['expression'], self.config) if 'expression' in params else {**self.config, **params}
            if config.get('effort') is False:
                config['effort'] = None
            if config.get('effort') is not None and config['effort'] not in EFFORTS:
                raise ValueError('Unknown effort')
            limit = config.get('context_limit_tokens')
            if limit is not None and (not isinstance(limit, int) or limit <= 0):
                raise ValueError('Budget must be positive or null for model default')
            await self.close_client()
            self.config = config
            self.record()['config'] = dict(config)
            self.store.flush()
        elif method == 'system':
            await self.close_client()
            self.system = params.get('text', PROMPT)
            self.event('status', text='system prompt updated; next request resumes history with a new prefix')
        elif method == 'watermarks':
            if params['policy'] not in ('allow', 'replace', 'remove'):
                raise ValueError('Expected allow, replace or remove')
            self.policy = params['policy']
        elif method == 'compact':
            return await self.compact()
        elif method == 'info':
            if self.client:
                self.context = await self.client.get_context_usage()
        else:
            raise ValueError('Unknown method: ' + method)
        return self.info()

    async def worker(self):
        try:
            while True:
                request = await self.queue.get()
                if request is None:
                    break
                self.active, self.cancelled = request, False
                try:
                    result = await self.dispatch(request['method'], request.get('params', {}))
                    response = {'id': request['id'], 'result': result}
                except Exception as error:
                    self.baselines.clear()
                    self.store.flush()
                    response = {'id': request['id'], 'error': {'code': -32000, 'message': str(error)}}
                    await self.close_client()
                finally:
                    self.active = None
                send(response)
        finally:
            await self.close_client()
            self.store.release()

    async def cancel(self):
        self.cancelled = True
        retained = []
        while not self.queue.empty():
            queued = self.queue.get_nowait()
            if queued and queued['method'] in ('turn', 'compact'):
                send({'id': queued['id'], 'error': {'code': -32800, 'message': 'Request canceled before dispatch'}})
            else:
                retained.append(queued)
        for queued in retained:
            self.queue.put_nowait(queued)
        if self.client:
            try:
                await self.client.interrupt()
            except sdk.CLIConnectionError:
                # Connection startup has no active SDK query yet. consume()
                # checks the cancellation flag before its first model dispatch.
                pass

    async def run(self):
        worker = asyncio.create_task(self.worker())
        try:
            while True:
                request = await asyncio.to_thread(read_frame)
                if request is None:
                    break
                method = request.get('method')
                if method == 'cancel':
                    await self.cancel()
                    send({'id': request['id'], 'result': {'canceled': True}})
                elif self.active or not self.queue.empty():
                    if method in ('new', 'clear', 'resume'):
                        await self.cancel()
                        await self.queue.put(request)
                    else:
                        send({'id': request['id'], 'error': {'code': -32001, 'message': 'Conversation busy; draft retained'}})
                else:
                    await self.queue.put(request)
        finally:
            await self.cancel()
            await self.queue.put(None)
            await worker


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--state', required=True)
    parser.add_argument('--login', action='store_true')
    args = parser.parse_args()
    if args.login:
        os.execv(str(CLI), [str(CLI), 'auth', 'login'])
    asyncio.run(Bridge(args.state).run())


if __name__ == '__main__':
    main()
