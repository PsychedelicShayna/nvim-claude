#!/usr/bin/env python3
"""One serial SDK owner with a concurrent framed RPC reader for interruption."""
import asyncio
import importlib.metadata
import json
import os
from pathlib import Path
import sys
import time

from claude_agent_sdk import (ClaudeSDKClient, ClaudeAgentOptions, AssistantMessage,
                              ResultMessage, SystemMessage, TextBlock)
from claude_agent_sdk.types import StreamEvent
from contracts import encode_request, edit_result, normalize, parse_model, PRESETS
from storage import Store

SYSTEM = (Path(__file__).parent / 'system.txt').read_text()
MAX_FRAME = 16 * 1024 * 1024
# Includes message wrappers, request-time runtime attachments and compaction instructions.
OVERHEAD = 16384


def send(message):
    raw = json.dumps({'jsonrpc': '2.0', **message}, ensure_ascii=False).encode()
    sys.stdout.buffer.write(f'Content-Length: {len(raw)}\r\n\r\n'.encode() + raw)
    sys.stdout.buffer.flush()


def read_frame():
    length = None
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        if line in (b'\r\n', b'\n'):
            break
        name, _, value = line.partition(b':')
        if name.lower() == b'content-length':
            length = int(value)
    if length is None or not 0 < length <= MAX_FRAME:
        raise ValueError('Invalid Content-Length')
    raw = sys.stdin.buffer.read(length)
    if len(raw) != length:
        return None
    return json.loads(raw)


class Bridge:
    def __init__(self):
        self.queue = asyncio.Queue()
        self.client = None
        self.store = None
        self.active = None
        self.cancelled = set()
        self.config = {'model': 'claude-haiku-5-5', 'effort': 'low',
                       'context_limit_tokens': 100000, 'thinking': 'disabled'}
        self.prompt = SYSTEM
        self.policy = 'allow'
        self.sticky = False
        self.baselines = {}
        self.metadata = {}
        self.connection_usage = {}
        self.occupancy = None
        self.ttl = 300
        self.shutting_down = False

    def event(self, kind, **values):
        if self.active:
            params = self.active.get('params', {})
            send({'method': kind, 'params': {'id': self.active['id'],
                  'epoch': params.get('epoch'), **values}})

    def check_cancelled(self):
        if self.active and self.active['id'] in self.cancelled:
            raise ValueError('Request cancelled; source unchanged')

    async def disconnect(self):
        if self.client:
            client, self.client = self.client, None
            await client.disconnect()
        self.baselines.clear()
        self.occupancy = None

    async def connect(self):
        if self.client:
            return
        if self.store.current is None:
            self.store.create(self.config, self.sticky)
        data = self.store.current
        # Never inherit paid API/cloud credentials as a silent subscription fallback.
        for key in ('ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'ANTHROPIC_BASE_URL',
                    'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX', 'CLAUDE_CODE_USE_FOUNDRY'):
            os.environ.pop(key, None)
        runtime_env = {'DISABLE_AUTO_COMPACT': '1',
                       'CLAUDE_CODE_MAX_OUTPUT_TOKENS': '4096',
                       'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC': '1'}
        options = ClaudeAgentOptions(
            model=self.config['model'], effort=self.config.get('effort'),
            thinking={'type': self.config.get('thinking', 'disabled')},
            tools=[], mcp_servers={}, strict_mcp_config=True, setting_sources=[],
            permission_mode='dontAsk', include_partial_messages=True,
            system_prompt={'type': 'custom', 'prompt': self.prompt, 'snapshot': False},
            cwd=data['cwd'], resume=data['id'] if data['started'] else None,
            session_id=None if data['started'] else data['id'],
            extra_args={'safe-mode': None, 'no-chrome': None},
            settings=json.dumps({'disableAllHooks': True, 'autoMemoryEnabled': False}),
            env=runtime_env,
        )
        self.client = ClaudeSDKClient(options)
        self.connection_usage = {}
        try:
            await self.client.connect()
            self.metadata = await self.client.get_server_info() or {}
            self.ttl = 3600 if self.metadata.get('account', {}).get('subscriptionType') else 300
            await self.measure()
        except Exception:
            await self.disconnect()
            raise

    async def measure(self):
        self.occupancy = await self.client.get_context_usage()
        for key in ('memoryFiles', 'mcpTools', 'mcpInstructions', 'agents', 'skills'):
            if self.occupancy.get(key):
                raise ValueError('No-tools isolation failed: runtime announced ' + key)
        categories = self.occupancy.get('categories', [])
        if any(c.get('kind') == 'used' and c.get('id') not in ('system_prompt', 'messages')
               and c.get('tokens', 0) for c in categories):
            raise ValueError('Unexpected runtime context; refusing a narrowly scoped request')
        if not isinstance(self.occupancy.get('totalTokens'), int):
            raise ValueError('Runtime cannot count context; capped requests are unsupported')
        return self.occupancy['totalTokens']

    async def collect(self, prompt, compact=False):
        self.check_cancelled()
        if not self.metadata.get('account', {}).get('subscriptionType'):
            raise ValueError('Runtime has not confirmed subscription authentication. '
                             'Use :NvClaude login; this plugin will not fall back to API billing.')
        await self.client.query(prompt)
        partial = ''
        final = ''
        completed = False
        boundary = False
        async for message in self.client.receive_response():
            if isinstance(message, StreamEvent):
                event = message.event
                if event.get('type') == 'content_block_delta':
                    delta = event.get('delta', {})
                    if delta.get('type') == 'text_delta':
                        partial += delta['text']
                        if not compact:
                            self.event('partial', text=normalize(partial, self.policy))
            elif isinstance(message, AssistantMessage):
                if message.error:
                    raise ValueError('Runtime assistant error: ' + str(message.error))
                final += ''.join(b.text for b in message.content if isinstance(b, TextBlock))
            elif isinstance(message, SystemMessage):
                if message.subtype == 'init':
                    if message.data.get('tools') or message.data.get('mcp_servers'):
                        await self.client.interrupt()
                        raise ValueError('Runtime exposed tools despite isolation options')
                    self.store.current['started'] = True
                    self.store.write()
                if message.subtype == 'compact_boundary':
                    boundary = True
                    self.baselines.clear()
            elif isinstance(message, ResultMessage):
                if message.is_error:
                    raise ValueError(message.result or ('Runtime failed: ' + message.subtype))
                completed = True
                self.store.current['started'] = True
                totals = self.store.current['usage']
                for model, usage in (message.model_usage or {}).items():
                    previous = self.connection_usage.get(model, {})
                    total = totals.setdefault(model, {})
                    for key in ('inputTokens', 'outputTokens', 'cacheReadInputTokens',
                                'cacheCreationInputTokens', 'costUSD', 'webSearchRequests',
                                'thinkingTokens'):
                        if key in usage:
                            total[key] = total.get(key, 0) + max(0, usage[key] - previous.get(key, 0))
                    self.connection_usage[model] = dict(usage)
                self.store.write()
        self.check_cancelled()
        if not completed:
            raise ValueError('Runtime ended without successful completion')
        if compact and not boundary:
            raise ValueError('Runtime did not confirm a compaction boundary')
        return final or partial

    def require_supported_budget(self):
        if self.config.get('context_limit_tokens') is not None:
            raise ValueError(
                'Unsupported hard prompt budget: this SDK reports estimated current context, '
                'not a bounded next provider request. No model request was sent. '
                'The requested limit has not been raised or disabled. Model default is '
                'available as an explicit, uncapped choice in the model picker.')

    async def compact(self):
        self.require_supported_budget()
        await self.connect()
        count = await self.measure()
        limit = self.occupancy.get('maxTokens')
        if limit and count + OVERHEAD > limit:
            raise ValueError('Compaction itself cannot fit this budget; start a new conversation')
        self.event('status', text='compacting')
        await self.collect('/compact', compact=True)
        self.baselines.clear()
        await self.measure()
        return {'compacted': True}

    async def submit(self, params):
        self.require_supported_budget()
        data = self.store.current
        if data and not data['saved'] and data['last_request'] and time.time() - data['last_request'] > self.ttl:
            await self.disconnect()
            self.store.create(self.config, self.sticky)
        await self.connect()
        data = self.store.current
        self.event('status', text='continued' if data['turns'] else 'new')
        document = params.get('document')
        baseline = self.baselines.get(document['id']) if document else None
        request = encode_request(params, baseline)
        text = json.dumps(request, ensure_ascii=False)
        count = await self.measure()
        limit = self.occupancy.get('maxTokens')
        mandatory = {k: v for k, v in request.items() if k != 'context'}
        mandatory_bytes = len(json.dumps(mandatory, ensure_ascii=False).encode())
        if limit and len(self.prompt.encode()) + mandatory_bytes + OVERHEAD > limit:
            raise ValueError('Instruction and intact target cannot fit the selected budget')
        if limit and count + len(text.encode()) + OVERHEAD > limit and data['turns']:
            await self.compact()
            request = encode_request(params, None)
            text = json.dumps(request, ensure_ascii=False)
            count = await self.measure()
        # Keep the target intact. Excerpts are explicit and only for local operations.
        if limit and count + len(text.encode()) + OVERHEAD > limit and document and params['operation'] != 'ask':
            if any(word in params['instruction'].lower() for word in ('whole file', 'entire file', 'whole document', 'entire document')):
                raise ValueError('Whole-document request does not fit; choose a smaller task or a larger budget')
            rows = document['text'].split('\n')
            first = min(t['start'][0] for t in params['targets'])
            last = max(t['end'][0] for t in params['targets'])
            lo, hi = max(0, first - 3), min(len(rows), last + 4)
            request['context'] = {'kind': 'excerpt', 'revision': document['revision'],
                                  'start_row': lo, 'end_row': hi, 'total_rows': len(rows),
                                  'text': '\n'.join(rows[lo:hi]), 'omitted': True}
            text = json.dumps(request, ensure_ascii=False)
        if limit and count + len(text.encode()) + OVERHEAD > limit:
            raise ValueError('Request exceeds the conservative context budget before dispatch')
        self.check_cancelled()
        if not data['first_prompt']:
            data['first_prompt'] = params['instruction']
        data['last_request'] = time.time()
        self.store.write()
        raw = await self.collect(text)
        data['turns'] += 1
        if document and request['context']['kind'] != 'excerpt':
            self.baselines[document['id']] = (document['revision'], document['text'])
        self.store.write()
        if params['operation'] == 'ask':
            return {'text': normalize(raw, self.policy)}
        try:
            result = edit_result(raw, params['targets'], params.get('block', False))
        except (ValueError, TypeError) as exc:
            return {'text': raw, 'error': str(exc)}
        for replacement in result.get('replacements', []):
            replacement['text'] = normalize(replacement['text'], self.policy)
        return result

    def info(self):
        data = self.store.current or {}
        return {'config': self.config, 'conversation': data.get('id'),
                'retention': 'saved' if data.get('saved') else 'ephemeral',
                'sticky': self.sticky, 'occupancy': self.occupancy,
                'cumulative_usage': data.get('usage'),
                'cache': {'ttl_seconds': self.ttl, 'provenance': 'runtime account type; estimated',
                          'last_request': data.get('last_request')},
                'budget': {'method': 'local hard ceilings unsupported; capped requests fail closed',
                           'physical_window_estimate_allowance': OVERHEAD,
                           'strict_ceiling_verified': False},
                'python': sys.version.split()[0], 'sdk': importlib.metadata.version('claude-agent-sdk'),
                'cli': self.metadata.get('claude_code_version'),
                'account': {k: v for k, v in self.metadata.get('account', {}).items()
                            if k in ('subscriptionType', 'apiProvider')},
                'models': self.metadata.get('models', []), 'presets': PRESETS}

    async def handle(self, method, params):
        if method == 'initialize':
            self.store = Store(params['state_dir'])
            self.config.update(params.get('config', {}))
            return {'protocol': 1, 'capabilities': ['stream', 'cancel', 'sessions'], 'system': SYSTEM,
                    'config': self.config}
        if not self.store:
            raise ValueError('Bridge is not initialized')
        if method == 'submit':
            return await self.submit(params)
        if method == 'info' or method == 'models':
            await self.connect()
            await self.measure()
            return self.info()
        if method == 'compact':
            return await self.compact()
        if method in ('new', 'clear', 'resume'):
            await self.disconnect()
            if method == 'resume':
                data = self.store.resume(params['id'])
                self.config = dict(data['config'])
            else:
                self.store.create(self.config, self.sticky)
            return self.info()
        if method == 'save' or method == 'sticky':
            if method == 'sticky':
                self.sticky = params.get('enabled', not self.sticky)
            if self.store.current is None:
                self.store.create(self.config, self.sticky)
            if method == 'save' or self.sticky:
                self.store.current['saved'] = True
                self.store.write()
            return self.info()
        if method == 'list':
            return self.store.saved()
        if method == 'configure':
            candidate = parse_model(params['expression'], self.config) if 'expression' in params else {**self.config, **params}
            await self.connect()
            models = self.metadata.get('models', [])
            matched = next((m for m in models if candidate['model'] in (m['value'], m.get('resolvedModel'))), None)
            if matched and candidate.get('effort') and candidate['effort'] not in matched.get('supportedEffortLevels', []):
                if 'effort' in params or 'expression' in params and params['expression'].endswith(':' + candidate['effort']):
                    raise ValueError('Runtime does not announce this effort for the selected model')
                candidate['effort'] = None
            await self.disconnect()
            self.config = candidate
            self.store.current['config'] = dict(candidate)
            self.store.write()
            return self.info()
        if method == 'system':
            await self.disconnect()
            self.prompt = params.get('text', SYSTEM)
            return {'system': self.prompt, 'note': 'Runtime resumes history with snapshot=false; prefix cache may be invalidated'}
        if method == 'watermarks':
            normalize('', params['policy'])
            self.policy = params['policy']
            return {'policy': self.policy}
        if method == 'login':
            import claude_agent_sdk
            return {'argv': [str(Path(claude_agent_sdk.__file__).parent / '_bundled' / 'claude'), 'auth', 'login']}
        raise ValueError('Unknown method: ' + method)

    async def reader(self):
        while True:
            message = await asyncio.to_thread(read_frame)
            if message is None:
                self.shutting_down = True
                if self.active:
                    self.cancelled.add(self.active['id'])
                    if self.client:
                        await self.client.interrupt()
                await self.queue.put(None)
                return
            method = message.get('method')
            if method == 'cancel' or (self.active and method in ('new', 'clear', 'resume')):
                if self.active:
                    self.cancelled.add(self.active['id'])
                    if self.client:
                        await self.client.interrupt()
                if method == 'cancel':
                    send({'id': message['id'], 'result': {'cancelled': True}})
                    continue
            if self.active and method == 'submit':
                send({'id': message['id'], 'error': {'code': -32001, 'message': 'Conversation busy; draft retained'}})
                continue
            await self.queue.put(message)

    async def run(self):
        reader = asyncio.create_task(self.reader())
        try:
            while True:
                message = await self.queue.get()
                if message is None:
                    break
                self.active = message
                try:
                    result = await self.handle(message['method'], message.get('params', {}))
                    self.check_cancelled()
                    send({'id': message['id'], 'result': result})
                except Exception as exc:
                    self.baselines.clear()
                    send({'id': message['id'], 'error': {'code': -32000, 'message': str(exc)}})
                finally:
                    self.cancelled.discard(message['id'])
                    self.active = None
        finally:
            await self.disconnect()
            if self.store:
                self.store.release()
            reader.cancel()


if __name__ == '__main__':
    asyncio.run(Bridge().run())
