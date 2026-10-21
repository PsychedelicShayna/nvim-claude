"""JSON-RPC actor. One actor owns the SDK client and every conversation transition."""
import argparse
import asyncio
import importlib.metadata
from dataclasses import asdict
import json
import os
from pathlib import Path
import platform
import sys
import time
import uuid
from claude_agent_sdk import (ClaudeAgentOptions, ClaudeSDKClient, AssistantMessage,
                              ResultMessage, StreamEvent, SystemMessage, TextBlock, UserMessage,
                              get_session_messages)
from contracts import (OVERHEAD, OUTPUT_RESERVE, PRESETS, byte_bound, context_for,
                       edit_result, encode, excerpt, normalize, parse_model)
from storage import Storage

SYSTEM = Path(__file__).resolve().parent.parent / 'resources' / 'system.txt'


def send(value):
    body = encode(value).encode('utf-8')
    sys.stdout.buffer.write(f'Content-Length: {len(body)}\r\n\r\n'.encode() + body)
    sys.stdout.buffer.flush()


def notify(method, params):
    send({'jsonrpc': '2.0', 'method': method, 'params': params})


class Bridge:
    def __init__(self, state):
        self.store = Storage(Path(state) / 'conversations')
        self.cwd = Path(state) / 'runtime'
        self.cwd.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.queue = asyncio.Queue()
        self.client = None
        self.record = None
        self.metadata = {}
        self.context = {}
        self.baselines = {}
        self.config = {'model': 'claude-haiku-5-5', 'effort': 'low', 'context_limit_tokens': 100000}
        self.prompt = SYSTEM.read_text()
        self.policy = 'allow'
        self.sticky = False
        self.busy = False
        self.cancelled = False
        self.active = None
        self.billing = 'subscription'
        self.ttl = 3600
        self.epoch = 0
        self.new_record()

    def new_record(self):
        identity = str(uuid.uuid4())
        self.store.claim(identity)
        self.record = {'id': identity, 'created': time.time(), 'first_prompt': '',
                       'saved': self.sticky, 'sdk_id': None, 'cwd': str(self.cwd),
                       'last_request': 0, 'history_bound': 0, 'raw': [], 'usage': {},
                       'config': dict(self.config)}
        self.baselines = {}
        self.store.write(self.record)

    async def disconnect(self):
        if self.client:
            client, self.client = self.client, None
            await client.disconnect()

    async def detach(self):
        await self.disconnect()
        if not self.record['saved']:
            self.store.delete(self.record)
        self.store.release(self.record['id'])
        self.epoch += 1
        self.baselines = {}

    async def connect(self, compaction=False):
        if self.client:
            if self.client_mode == compaction:
                return
            await self.disconnect()
        self.client_mode = compaction
        env = {'CLAUDE_CODE_DISABLE_AUTO_MEMORY': '1',
               'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC': '1',
               'CLAUDE_CODE_AUTO_COMPACT_WINDOW': str(min(1000000, max(100000, self.config.get('context_limit_tokens') or 1000000))),
               'CLAUDE_CODE_MAX_OUTPUT_TOKENS': str(OUTPUT_RESERVE)}
        if self.billing != 'api':
            env.update({'ANTHROPIC_API_KEY': '', 'ANTHROPIC_AUTH_TOKEN': '',
                        'CLAUDE_CODE_USE_BEDROCK': '0', 'CLAUDE_CODE_USE_VERTEX': '0',
                        'CLAUDE_CODE_USE_FOUNDRY': '0'})
        sid = self.record['sdk_id']
        extra = {'safe-mode': None, 'no-chrome': None}
        if not compaction:
            extra['disable-slash-commands'] = None
        options = ClaudeAgentOptions(
            model=self.config['model'], effort=self.config.get('effort'),
            thinking={'type': 'disabled'}, tools=[], allowed_tools=[],
            mcp_servers={}, strict_mcp_config=True, setting_sources=[],
            skills=[], agents={}, plugins=[], include_partial_messages=True,
            cwd=str(self.cwd), resume=sid, session_id=None if sid else self.record['id'],
            system_prompt={'type': 'custom', 'prompt': self.prompt, 'snapshot': False},
            settings=encode({'disableAllHooks': True, 'autoMemoryEnabled': False,
                             'enabledPlugins': {'cc-plugin-agents-md@builtin': False,
                                                'cc-plugin-plugin-authoring@builtin': False}}),
            env=env, extra_args=extra,
            stderr=lambda line: print(line, file=sys.stderr))
        self.client = ClaudeSDKClient(options)
        try:
            await self.client.connect()
            self.metadata = await self.client.get_server_info() or {}
            await self.refresh_context()
            self.validate_effort(self.config)
        except BaseException:
            await self.disconnect()
            raise

    def validate_effort(self, config):
        effort = config.get('effort')
        model = next((m for m in self.metadata.get('models', [])
                      if config['model'] in (m.get('value'), m.get('resolvedModel'))), None)
        if model and effort:
            if not model.get('supportsEffort') or effort not in model.get('supportedEffortLevels', []):
                raise ValueError('Runtime does not support that effort for the selected model')
        # Manual unknown IDs are accepted by the runtime, not advertised as verified.

    async def refresh_context(self):
        self.context = await self.client.get_context_usage()
        if any(self.context.get(k) for k in ('memoryFiles', 'mcpTools', 'agents', 'systemTools')):
            raise RuntimeError('Runtime isolation failed: unexpected memory, tools, or agents')
        return self.context

    def transcript_bound(self):
        sid = self.record.get('sdk_id')
        if not sid:
            return 0
        messages = get_session_messages(sid, directory=self.record['cwd'])
        if not messages:
            raise RuntimeError('Cannot establish a budget bound from the owned SDK transcript')
        return byte_bound(encode([asdict(message) for message in messages])) + 1024

    def status(self, message):
        p = {'message': message, 'epoch': self.epoch}
        if self.active:
            p.update(request_id=self.active['id'], generation=self.active['params'].get('generation'))
        notify('status', p)

    def input_bound(self, prompt):
        return OVERHEAD + byte_bound(self.prompt) + self.record['history_bound'] + byte_bound(prompt)

    def cap(self):
        if self.metadata.get('claude_code_version') != '2.1.306':
            raise RuntimeError('Hard-budget runtime overhead is verified only for CLI 2.1.306; nothing sent. Inspect the new runtime before enabling a cap.')
        physical = self.context.get('rawMaxTokens', 100000)
        local = self.config.get('context_limit_tokens')
        return min(local if local else physical, physical - OUTPUT_RESERVE)

    async def compact(self):
        await self.connect(compaction=True)
        cap = self.cap()
        if self.input_bound('/compact') > cap:
            raise ValueError('Too late to compact safely within this budget; use new or a larger explicit limit')
        self.status('compacting')
        boundary = None
        summary_bytes = 0
        self.dispatched = True
        await self.client.query('/compact')
        async for message in self.client.receive_response():
            if isinstance(message, SystemMessage) and message.subtype == 'compact_boundary':
                boundary = message.data.get('compact_metadata', {})
            elif isinstance(message, UserMessage) and isinstance(message.content, str):
                summary_bytes += byte_bound(message.content) + 512
            elif isinstance(message, ResultMessage) and message.is_error:
                raise RuntimeError('Runtime compaction failed')
        if not boundary:
            raise RuntimeError('Runtime did not emit a compaction boundary; history was not marked compacted')
        self.baselines = {}
        self.record['history_bound'] = max(summary_bytes + 1024, self.transcript_bound())
        self.record['compacted'] = boundary
        self.store.write(self.record)
        await self.refresh_context()
        await self.disconnect()
        return {'compacted': boundary, 'lossy': True}

    def envelope(self, params):
        envelope = {'operation': params['operation'], 'instruction': params['instruction']}
        document = params.get('document')
        if document:
            envelope['document'] = {k: document[k] for k in ('id', 'filetype')}
            envelope['context'] = context_for(document, self.baselines.get(document['id']))
            envelope['targets'] = params['targets']
            if params.get('block'):
                envelope['blockwise'] = True
        return envelope

    async def turn(self, params):
        if not self.record['saved'] and self.record['last_request'] and time.time() - self.record['last_request'] >= self.ttl:
            await self.detach()
            self.new_record()
        await self.connect()
        self.status('continued' if self.record['sdk_id'] else 'new')
        envelope = self.envelope(params)
        prompt = encode(envelope)
        cap = self.cap()
        # Keep headroom for a safe compaction turn before the next prompt.
        if self.record['history_bound'] and self.input_bound(prompt) > cap * 0.65:
            await self.compact()
            await self.connect()
            envelope = self.envelope(params)
            prompt = encode(envelope)
        if self.input_bound(prompt) > cap and params.get('document') and not params.get('whole_document'):
            envelope.pop('context', None)
            room = cap - self.input_bound(encode(envelope)) - 256
            envelope['context'] = excerpt(params['document'], params['targets'], max(0, room))
            prompt = encode(envelope)
        bound = self.input_bound(prompt)
        if bound > cap:
            raise ValueError(f'Prompt byte upper bound {bound} exceeds effective ceiling {cap}; nothing sent')
        if self.cancelled:
            raise RuntimeError('Cancelled before dispatch')
        self.record['last_request'] = time.time()
        self.record['first_prompt'] = self.record['first_prompt'] or params['instruction']
        self.record['config'] = dict(self.config)
        self.store.write(self.record)
        raw_parts, stream = [], ''
        result = None
        self.dispatched = True
        await self.client.query(prompt)
        async for message in self.client.receive_response():
            if isinstance(message, SystemMessage):
                if message.subtype == 'init':
                    data = message.data
                    if data.get('tools') or data.get('mcp_servers'):
                        await self.client.interrupt()
                        raise RuntimeError('Unexpected model-accessible tools in runtime initialization')
                    self.record['sdk_id'] = data['session_id']
                    self.record['runtime_init'] = {k: data.get(k) for k in ('tools', 'skills', 'plugins', 'apiKeySource', 'model')}
                    self.store.write(self.record)
                elif message.subtype == 'compact_boundary':
                    self.baselines = {}
            elif isinstance(message, StreamEvent):
                event = message.event
                if event.get('type') == 'content_block_delta' and event.get('delta', {}).get('type') == 'text_delta':
                    stream += event['delta']['text']
                    if not self.cancelled:
                        notify('text', {'request_id': self.active['id'], 'generation': params.get('generation'),
                                        'text': normalize(stream, self.policy)})
            elif isinstance(message, AssistantMessage):
                if message.error:
                    raise RuntimeError(str(message.error))
                raw_parts.extend(block.text for block in message.content if isinstance(block, TextBlock))
            elif isinstance(message, ResultMessage):
                result = message
        if self.cancelled:
            raise RuntimeError('Request cancelled; no edit applied')
        if not result or result.is_error or result.subtype != 'success' or result.terminal_reason in ('aborted_streaming', 'aborted_tools'):
            raise RuntimeError('SDK request failed: ' + str(result.errors if result else 'missing completion'))
        raw = ''.join(raw_parts) if raw_parts else (result.result or stream)
        self.record['sdk_id'] = result.session_id
        self.record['history_bound'] += byte_bound(prompt) + byte_bound(raw) + 1024
        self.record['history_bound'] = max(self.record['history_bound'], self.transcript_bound())
        self.record['raw'].append({'user': envelope, 'assistant': raw})
        self.record['usage'] = result.model_usage or {}
        usage = result.usage or {}
        actual = sum(usage.get(k, 0) or 0 for k in ('input_tokens', 'cache_read_input_tokens', 'cache_creation_input_tokens'))
        self.record['last_budget'] = {'conservative_bound': bound, 'actual_prompt_tokens': actual,
                                      'ceiling': cap, 'runtime_allowance': OVERHEAD}
        if usage.get('cache_creation', {}).get('ephemeral_1h_input_tokens', 0):
            self.ttl = 3600
        elif usage.get('cache_creation', {}).get('ephemeral_5m_input_tokens', 0):
            self.ttl = 300
        document = params.get('document')
        if document and envelope['context']['kind'] != 'excerpt':
            self.baselines[document['id']] = (document['revision'], document['text'])
        self.store.write(self.record)
        await self.refresh_context()
        if actual > bound:
            raise RuntimeError('Runtime overhead exceeded the conservative bound; result retained, cap support invalid')
        value = {'raw': raw, 'text': normalize(raw, self.policy), 'budget': self.record['last_budget']}
        if params['operation'] != 'ask':
            value['edit'] = edit_result(raw, params['targets'], params.get('block', False))
            for replacement in value['edit'].get('replacements', []):
                replacement['text'] = normalize(replacement['text'], self.policy)
        return value

    async def handle(self, method, params):
        if method == 'initialize':
            self.config.update(params.get('config', {}))
            self.billing = params.get('billing', 'subscription')
            self.ttl = 300 if self.billing == 'api' else 3600
            await self.connect()
            return self.info()
        if method == 'request':
            return await self.turn(params)
        if method == 'info':
            await self.connect()
            await self.refresh_context()
            return self.info()
        if method == 'models':
            await self.connect()
            return {'models': self.metadata.get('models', []), 'presets': PRESETS}
        if method == 'model':
            await self.connect()
            native = [m['value'] for m in self.metadata.get('models', [])]
            config = parse_model(params['expression'], self.config, native) if 'expression' in params else dict(params)
            if 'expression' in params and params['expression'].rsplit(':', 1)[-1] not in ('low', 'medium', 'high', 'xhigh', 'max'):
                model = next((m for m in self.metadata.get('models', []) if config['model'] in (m.get('value'), m.get('resolvedModel'))), None)
                if model and config.get('effort') not in model.get('supportedEffortLevels', []):
                    config['effort'] = None
            self.validate_effort(config)
            await self.disconnect()
            self.config = config
            self.baselines = {}
            self.record['config'] = dict(config)
            self.store.write(self.record)
            return config
        if method == 'system':
            await self.disconnect()
            self.prompt = params.get('prompt') or SYSTEM.read_text()
            self.baselines = {}
            return {'message': 'Prompt changes on the next request; same SDK history resumes with snapshot off. Prefix cache may be cold.'}
        if method == 'watermarks':
            if params['policy'] not in ('allow', 'replace', 'remove'):
                raise ValueError('Use watermarks allow, replace, or remove')
            self.policy = params['policy']
            return {'policy': self.policy}
        if method in ('new', 'clear'):
            await self.detach()
            self.new_record()
            return {'id': self.record['id'], 'epoch': self.epoch}
        if method == 'save':
            self.record['saved'] = True
            self.store.write(self.record)
            return {'saved': self.record['id']}
        if method == 'sticky':
            self.sticky = params.get('enabled', not self.sticky)
            if self.sticky:
                self.record['saved'] = True
                self.store.write(self.record)
            return {'sticky': self.sticky}
        if method == 'list':
            return [{'id': r['id'], 'title': time.strftime('%y:%m:%d:%H:%M:%S', time.localtime(r['created'])) + ' - ' + r['first_prompt'][:80]} for r in self.store.saved()]
        if method == 'resume':
            identity = params['id']
            record = self.store.read(identity)
            if not record or not record['saved']:
                raise ValueError('Saved conversation not found')
            if identity == self.record['id']:
                return {'resumed': identity}
            if not self.store.claim(identity):
                raise ValueError('Conversation is open in another live Neovim')
            await self.detach()
            self.record = record
            self.config = dict(record['config'])
            self.baselines = {}
            return {'resumed': identity, 'epoch': self.epoch}
        if method == 'compact':
            return await self.compact()
        raise ValueError('Unknown method: ' + method)

    def info(self):
        account = self.metadata.get('account', {})
        return {'protocol': 1, 'model': self.config, 'resolved_model': self.context.get('model'),
                'effort_verified': any(self.config['model'] in (m.get('value'), m.get('resolvedModel')) for m in self.metadata.get('models', [])),
                'occupancy': {k: v for k, v in self.context.items() if k in ('totalTokens', 'rawMaxTokens', 'maxTokens', 'categories')},
                'occupancy_provenance': 'runtime context estimate', 'cumulative_usage': self.record['usage'],
                'retention': 'saved' if self.record['saved'] else 'ephemeral', 'conversation': self.record['id'],
                'cache': {'ttl_seconds': self.ttl, 'remaining_estimate': max(0, self.ttl - (time.time() - self.record['last_request'])),
                          'provenance': 'runtime cache-creation usage when present; billing-mode estimate otherwise; no heartbeat'},
                'budget': self.record.get('last_budget'), 'budget_policy': 'UTF-8 byte upper bound plus 8192 runtime tokens; no chars/4 estimate',
                'budget_runtime_verified': self.metadata.get('claude_code_version') == '2.1.306',
                'versions': {'python': platform.python_version(), 'sdk': importlib.metadata.version('claude-agent-sdk'),
                             'cli': self.metadata.get('claude_code_version')},
                'billing': {'requested': self.billing, 'subscription': account.get('subscriptionType'), 'provider': account.get('apiProvider')},
                'cli_path': str(Path(__import__('claude_agent_sdk').__file__).parent / '_bundled' / 'claude'),
                'system_prompt': self.prompt}

    async def actor(self):
        try:
            while True:
                message = await self.queue.get()
                if message is None:
                    break
                method = message['method']
                self.active = message
                self.cancelled = False
                self.dispatched = False
                try:
                    value = await self.handle(method, message.get('params') or {})
                    send({'jsonrpc': '2.0', 'id': message['id'], 'result': value})
                except Exception as error:
                    if method == 'request':
                        self.baselines = {}
                        if self.dispatched:
                            try:
                                await self.disconnect()
                                self.record['history_bound'] = self.transcript_bound()
                            except Exception:
                                self.record['history_bound'] = 1000001
                            self.store.write(self.record)
                    send({'jsonrpc': '2.0', 'id': message['id'], 'error': {'code': -32000, 'message': str(error)}})
                finally:
                    if method == 'request':
                        self.busy = False
                    self.active = None
        finally:
            await self.disconnect()
            if self.record and not self.record['saved']:
                self.store.delete(self.record)
            if self.record:
                self.store.release(self.record['id'])

    async def serve(self):
        reader = asyncio.StreamReader(limit=32 * 1024 * 1024)
        await asyncio.get_running_loop().connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin.buffer)
        actor = asyncio.create_task(self.actor())
        try:
            while True:
                try:
                    headers = await reader.readuntil(b'\r\n\r\n')
                except asyncio.IncompleteReadError:
                    break
                lengths = [line.split(b':', 1)[1].strip() for line in headers.split(b'\r\n') if line.lower().startswith(b'content-length:')]
                if len(lengths) != 1 or not 0 < int(lengths[0]) <= 32 * 1024 * 1024:
                    raise ValueError('Invalid Content-Length')
                message = json.loads(await reader.readexactly(int(lengths[0])))
                method = message.get('method')
                if method == 'cancel':
                    self.cancelled = True
                    if self.client and self.busy:
                        await self.client.interrupt()
                    send({'jsonrpc': '2.0', 'id': message.get('id'), 'result': {'cancelled': True}})
                elif self.busy and method == 'request':
                    send({'jsonrpc': '2.0', 'id': message['id'], 'error': {'code': -32001, 'message': 'Conversation is busy; draft retained'}})
                else:
                    if self.busy and method in ('new', 'clear', 'resume'):
                        self.cancelled = True
                        if self.client:
                            await self.client.interrupt()
                    if method == 'request':
                        self.busy = True
                    await self.queue.put(message)
        finally:
            self.cancelled = True
            if self.client and self.busy:
                await self.client.interrupt()
            await self.queue.put(None)
            await actor


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--state', required=True)
    asyncio.run(Bridge(parser.parse_args().state).serve())
