"""One SDK client actor per editor, with framed JSON-RPC on stdio."""
import argparse
import asyncio
import importlib.metadata
import json
import os
from pathlib import Path
import signal
import sys
import time

from claude_agent_sdk import ClaudeAgentOptions, ClaudeSDKClient, AssistantMessage, ResultMessage, SystemMessage, TextBlock
from claude_agent_sdk.types import StreamEvent
from contracts import OVERHEAD, OUTPUT_RESERVE, byte_bound, context_envelope, edit_result, excerpt, parse_expression, validate_config
from storage import Storage

RESOURCE = Path(__file__).resolve().parent.parent / 'resources' / 'system.txt'


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'))


def send(value):
    data = encode(value).encode('utf-8')
    sys.stdout.buffer.write(f'Content-Length: {len(data)}\r\n\r\n'.encode() + data)
    sys.stdout.buffer.flush()


def read_frame():
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        if line in (b'\r\n', b'\n'):
            break
        key, value = line.decode('ascii').split(':', 1)
        headers[key.lower()] = value.strip()
    size = int(headers.get('content-length', '0'))
    if size <= 0 or size > 32 * 1024 * 1024:
        raise ValueError('Invalid Content-Length')
    data = bytearray()
    while len(data) < size:
        chunk = sys.stdin.buffer.read(size - len(data))
        if not chunk:
            raise EOFError('Incomplete protocol frame')
        data.extend(chunk)
    return json.loads(data)


class Bridge:
    def __init__(self, state, versions):
        self.store = Storage(state)
        self.config = {'model': 'claude-haiku-5-5', 'effort': 'low', 'context_limit_tokens': 100000, 'thinking': False, 'auth_mode': 'subscription'}
        self.record = self.store.create(self.config)
        self.client = None
        self.metadata = {}
        self.versions = versions
        self.prompt = RESOURCE.read_text()
        self.sticky = False
        self.cancelled = False
        self.busy = False
        self.queue = asyncio.Queue()
        self.current_id = None
        self.epoch = 0
        self.ttl = 300
        self.last_cache_ttl = None

    def event(self, kind, text):
        send({'jsonrpc': '2.0', 'method': 'event', 'params': {'request_id': self.current_id, 'epoch': self.epoch, 'kind': kind, 'text': text}})

    async def disconnect(self):
        if self.client:
            client, self.client = self.client, None
            await client.disconnect()

    async def connect(self):
        if self.client:
            return
        api_env = ('ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX', 'CLAUDE_CODE_USE_FOUNDRY')
        if self.config.get('auth_mode') != 'api' and any(os.environ.get(k) for k in api_env):
            raise ValueError('API/cloud credentials are present. Refusing a silent billing switch. Explicitly set auth_mode="api" to opt in, or launch Neovim without those variables for subscription login.')
        options = ClaudeAgentOptions(
            model=self.config['model'], effort=self.config.get('effort'),
            thinking={'type': 'adaptive' if self.config.get('thinking') else 'disabled'},
            tools=[], allowed_tools=[], mcp_servers={}, strict_mcp_config=True,
            setting_sources=[], skills=[], agents={}, plugins=[],
            settings=encode({'disableAllHooks': True, 'autoMemoryEnabled': False}),
            system_prompt={'type': 'custom', 'prompt': self.prompt, 'snapshot': False},
            cwd=str(self.store.workspace),
            resume=self.record['session_id'] if self.record['has_turns'] else None,
            session_id=None if self.record['has_turns'] else self.record['session_id'],
            include_partial_messages=True,
            extra_args={'safe-mode': None, 'no-chrome': None},
            env={'CLAUDE_CODE_DISABLE_AUTO_MEMORY': '1', 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC': '1',
                 'CLAUDE_CODE_MAX_OUTPUT_TOKENS': str(OUTPUT_RESERVE),
                 'CLAUDE_CODE_AUTO_COMPACT_WINDOW': str(max(100000, min(1000000, self.config.get('context_limit_tokens') or 1000000)))})
        self.client = ClaudeSDKClient(options=options)
        try:
            await self.client.connect()
            self.metadata = await self.client.get_server_info() or {}
            self.versions['cli'] = self.metadata.get('claude_code_version', self.versions.get('cli'))
            account = self.metadata.get('account', {})
            self.ttl = 3600 if account.get('subscriptionType') and self.config.get('auth_mode') != 'api' else 300
            await self.inspect_context()
        except BaseException:
            await self.disconnect()
            raise

    async def inspect_context(self):
        usage = await self.client.get_context_usage()
        for key in ('memoryFiles', 'mcpTools', 'agents', 'systemTools', 'deferredBuiltinTools'):
            if usage.get(key):
                raise ValueError('No-tools/context isolation failed: runtime exposed ' + key)
        if not isinstance(usage.get('totalTokens'), (int, float)) or not usage.get('rawMaxTokens'):
            raise ValueError('Runtime cannot report context usage; strict local budgets unsupported before dispatch')
        # Display an intentionally small subset, never account identifiers.
        self.record['occupancy'] = {k: usage.get(k) for k in ('totalTokens', 'rawMaxTokens', 'maxTokens', 'model', 'autoCompactThreshold', 'isAutoCompactEnabled')}
        return usage

    def info(self):
        r = self.record
        age = time.time() - r['last_request'] if r['last_request'] else None
        return {'conversation': r['id'], 'config': self.config, 'retention': 'saved' if r['persistent'] else 'ephemeral', 'sticky': self.sticky,
                'occupancy': r['occupancy'], 'cumulative_usage': r['usage'], 'versions': self.versions,
                'budget': {'policy': 'conservative UTF-8 byte upper bound plus runtime allowance; fail closed on unknown context', 'history_byte_bound': r['bound'], 'runtime_allowance_tokens': OVERHEAD, 'output_reserve_tokens': OUTPUT_RESERVE, 'requested_ceiling': self.config.get('context_limit_tokens'), 'verified_runtime': '2.1.306', 'native_compaction_is_not_a_ceiling': True},
                'cache': {'ttl_seconds': self.last_cache_ttl or self.ttl, 'remaining_seconds': max(0, (self.last_cache_ttl or self.ttl) - age) if age is not None else None, 'provenance': 'observed cache-creation TTL; expiry estimated' if self.last_cache_ttl else 'estimated from runtime account mode; no heartbeat'},
                'authentication': {'mode': self.config.get('auth_mode'), 'runtime_subscription_available': bool(self.metadata.get('account', {}).get('subscriptionType'))}}

    def base_bound(self):
        return self.record['bound'] + byte_bound(self.prompt) + OVERHEAD

    def ceiling(self):
        physical = self.record['occupancy']['rawMaxTokens'] - OUTPUT_RESERVE
        return min(self.config.get('context_limit_tokens') or physical, physical)

    def check_budget(self, payload_bytes=0):
        if self.versions.get('cli') not in ('2.1.306', '2.1.306 (Claude Code)'):
            raise ValueError('Strict budget unsupported for this unverified runtime version; no model request sent. Update plugin runtime validation before using it.')
        bound = self.base_bound() + payload_bytes
        measured = self.record['occupancy']['totalTokens']
        if measured > self.base_bound():
            raise ValueError('Runtime context exceeds the accounted byte bound; refusing dispatch')
        if bound > self.ceiling():
            raise ValueError(f'Request cannot fit the selected ceiling: conservative bound {bound}, ceiling {self.ceiling()}. Target/instruction will not be truncated or budget raised.')
        return bound

    async def detach(self):
        await self.disconnect()
        self.store.write(self.record)
        self.store.discard(self.record)
        self.record = self.store.create(self.config, self.sticky)

    async def receive(self, stream=True):
        chunks, final, result, boundary = [], [], None, False
        async for message in self.client.receive_response():
            if isinstance(message, StreamEvent):
                event = message.event
                if event.get('type') == 'content_block_delta' and event.get('delta', {}).get('type') == 'text_delta':
                    text = event['delta']['text']
                    chunks.append(text)
                    if stream and not self.cancelled:
                        self.event('text', text)
            elif isinstance(message, AssistantMessage):
                if message.error:
                    raise ValueError('Assistant failed: ' + str(message.error))
                if any(not isinstance(block, TextBlock) for block in message.content):
                    # Thinking is not output. Tool blocks are never permitted.
                    if any(type(block).__name__ in ('ToolUseBlock', 'ToolResultBlock') for block in message.content):
                        raise ValueError('Runtime violated no-tools contract')
                final.extend(block.text for block in message.content if isinstance(block, TextBlock))
            elif isinstance(message, SystemMessage):
                if message.subtype == 'init':
                    if message.data.get('tools') or message.data.get('mcp_servers'):
                        raise ValueError('Runtime exposed unexpected model tools')
                elif message.subtype == 'compact_boundary':
                    boundary = True
                    self.record['baselines'] = {}
                elif message.subtype == 'status' and message.data.get('status'):
                    self.event('status', message.data['status'])
            elif isinstance(message, ResultMessage):
                result = message
        raw = ''.join(final) if final else ''.join(chunks)
        if result is None or result.is_error or result.subtype != 'success':
            detail = result.result if result else 'Runtime disconnected before successful completion'
            raise ValueError(str(detail) + '. Check :NvClaude login if authentication is missing.')
        if self.cancelled:
            raise ValueError('Request cancelled; no edit applied')
        usage = result.usage or {}
        for key in ('input_tokens', 'cache_read_input_tokens', 'cache_creation_input_tokens', 'output_tokens'):
            self.record['usage'][key] = self.record['usage'].get(key, 0) + usage.get(key, 0)
        cache = usage.get('cache_creation', {})
        if cache.get('ephemeral_1h_input_tokens'):
            self.last_cache_ttl = 3600
        elif cache.get('ephemeral_5m_input_tokens'):
            self.last_cache_ttl = 300
        return raw, boundary

    def compacted_bound(self):
        path = self.store.transcript(self.record['session_id'])
        if not path:
            raise ValueError('Compaction finished but owned runtime transcript is unavailable')
        # Native compact_boundary starts the retained context. Count every byte
        # afterwards, including metadata and attachments, as an overestimate.
        bound, seen = 0, False
        with path.open() as handle:
            for line in handle:
                item = json.loads(line)
                if item.get('subtype') == 'compact_boundary':
                    bound, seen = 0, True
                elif seen:
                    bound += byte_bound(line)
        if not seen:
            raise ValueError('Runtime did not persist the compaction boundary')
        self.record['bound'] = bound

    async def compact(self):
        await self.connect()
        self.check_budget(OUTPUT_RESERVE + 4096)
        if not self.record['has_turns']:
            return self.info()
        self.event('status', 'compacting')
        await self.client.query('/compact')
        _, boundary = await self.receive(False)
        if not boundary:
            raise ValueError('Runtime did not confirm a native compaction boundary')
        self.compacted_bound()
        self.record['baselines'] = {}
        await self.inspect_context()
        self.store.write(self.record)
        return self.info()

    async def turn(self, params):
        envelope = params['envelope']
        if envelope.get('operation') not in ('ask', 'replace', 'generate') or not isinstance(envelope.get('instruction'), str):
            raise ValueError('Invalid operation or instruction')
        r = self.record
        ttl = self.last_cache_ttl or self.ttl
        if not r['persistent'] and r['last_request'] and time.time() - r['last_request'] > ttl:
            await self.detach()
            r = self.record
        await self.connect()
        validate_config(self.config, self.metadata.get('models', []))
        empty_allowance = self.ceiling() - byte_bound(self.prompt) - OVERHEAD
        dispatch_envelope = envelope
        if byte_bound(encode(envelope)) > empty_allowance:
            dispatch_envelope = excerpt(envelope, empty_allowance)
            if byte_bound(encode(dispatch_envelope)) > empty_allowance:
                raise ValueError('Mandatory instruction and intact target cannot fit even an empty conversation under the selected ceiling. No request sent; budget unchanged.')
        wire = context_envelope(dispatch_envelope, r['baselines'])
        payload = encode(wire)
        if r['has_turns'] and self.base_bound() + byte_bound(payload) > self.ceiling() * 0.65:
            await self.compact()
            wire = context_envelope(dispatch_envelope, r['baselines'])
            payload = encode(wire)
        if self.base_bound() + byte_bound(payload) > self.ceiling():
            wire = excerpt(envelope, self.ceiling() - self.base_bound())
            payload = encode(wire)
        self.check_budget(byte_bound(payload))
        self.event('status', 'continued' if r['has_turns'] else 'new')
        r['first_prompt'] = r['first_prompt'] or envelope['instruction']
        r['last_request'] = time.time()  # TTL starts at request, not response end.
        r['baselines'] = {} if wire.get('context', {}).get('kind') == 'excerpt' else r['baselines']
        # Persist ownership before the runtime can write a session.
        self.store.write(r)
        await self.client.query(payload)
        raw = ''
        try:
            raw, boundary = await self.receive()
            r['has_turns'] = True
            r['bound'] += byte_bound(payload) + byte_bound(raw) + 2048
            r['raw'].append({'request': wire, 'assistant': raw})
            if boundary:
                self.compacted_bound()
                r['baselines'] = {}
            elif wire.get('context', {}).get('kind') != 'excerpt' and envelope.get('document'):
                r['baselines'][envelope['document']['id']] = envelope['context']
            await self.inspect_context()
            result = edit_result(raw, envelope)
            result['info'] = self.info()
            return result
        except BaseException as error:
            r['baselines'] = {}
            # Delivery may be uncertain. Reconnect by the exact owned ID rather
            # than continuing with an undercounted in-memory history.
            r['has_turns'] = bool(self.store.transcript(r['session_id']))
            r['bound'] += byte_bound(payload) + byte_bound(raw) + OUTPUT_RESERVE * 8
            await self.disconnect()
            if raw:
                self.event('status', str(error))
                raise ValueError(str(error) + '\n\nRaw response:\n' + raw) from error
            raise
        finally:
            self.store.write(r)

    async def dispatch(self, method, params):
        if method == 'initialize':
            for key in self.config:
                if key in params:
                    self.config[key] = params[key]
            self.record['config'] = dict(self.config)
            await self.connect()
            return {'models': self.metadata.get('models', []), 'config': self.config, 'versions': self.versions}
        if method == 'turn':
            return await self.turn(params)
        if method in ('info', 'models'):
            await self.connect()
            await self.inspect_context()
            return self.info() if method == 'info' else self.metadata.get('models', [])
        if method == 'configure':
            await self.connect()
            candidate = parse_expression(params['expression'], self.config, self.metadata.get('models', [])) if params.get('expression') else {**self.config, **params}
            validate_config(candidate, self.metadata.get('models', []))
            await self.disconnect()
            self.config = candidate
            self.record['config'] = dict(candidate)
            self.record['baselines'] = {}
            self.store.write(self.record)
            return {'config': self.config, 'message': 'Configuration changed; exact SDK history resumes with a new prefix on next turn.'}
        if method == 'system':
            if params.get('get'):
                return {'text': self.prompt}
            prompt = RESOURCE.read_text() if params.get('default') else params['text']
            await self.disconnect()
            self.prompt = prompt
            self.record['baselines'] = {}
            return {'message': 'System prompt updated for next turn. History retained; prefix cache may miss.'}
        if method in ('new', 'clear'):
            await self.detach()
            return self.info()
        if method == 'save':
            self.record['persistent'] = True
            self.store.write(self.record)
            return self.info()
        if method == 'sticky':
            setting = params.get('value', params.get('mode', params.get('enabled')))
            self.sticky = not self.sticky if setting in (None, '', 'toggle') else setting in (True, 'on')
            if self.sticky:
                self.record['persistent'] = True
            self.store.write(self.record)
            return self.info()
        if method == 'list':
            return self.store.saved()
        if method == 'resume':
            ident = params.get('id')
            if ident == self.record['id']:
                return self.info()
            record = self.store.load(ident)
            await self.disconnect()
            self.store.write(self.record)
            self.store.discard(self.record)
            self.record = record
            self.config = dict(record['config'])
            return self.info()
        if method == 'compact':
            return await self.compact()
        raise ValueError('Unknown bridge method: ' + method)

    async def reader(self):
        try:
            while (message := await asyncio.to_thread(read_frame)) is not None:
                method, ident = message.get('method'), message.get('id')
                if method == 'cancel':
                    self.cancelled = True
                    if self.client and self.busy:
                        try:
                            await asyncio.wait_for(self.client.interrupt(), timeout=10)
                        except Exception:
                            pass
                    send({'jsonrpc': '2.0', 'id': ident, 'result': {'cancelled': True}})
                elif self.busy and method == 'turn':
                    send({'jsonrpc': '2.0', 'id': ident, 'error': {'code': -32001, 'message': 'Conversation busy; draft retained'}})
                else:
                    if self.busy and method in ('new', 'clear', 'resume'):
                        self.cancelled = True
                        if self.client:
                            await self.client.interrupt()
                    await self.queue.put(message)
        finally:
            if self.busy and self.client:
                self.cancelled = True
                await self.client.interrupt()
            await self.queue.put(None)

    async def run(self):
        reader = asyncio.create_task(self.reader())
        try:
            while (message := await self.queue.get()) is not None:
                self.current_id = message.get('id')
                params = message.get('params') or {}
                self.epoch = params.get('epoch', 0)
                self.cancelled = False
                self.busy = True
                try:
                    result = await self.dispatch(message['method'], params)
                    send({'jsonrpc': '2.0', 'id': self.current_id, 'result': result})
                except Exception as error:
                    send({'jsonrpc': '2.0', 'id': self.current_id, 'error': {'code': -32000, 'message': str(error)}})
                finally:
                    self.busy = False
        finally:
            await self.disconnect()
            self.store.write(self.record)
            self.store.discard(self.record)
            reader.cancel()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--state', required=True)
    args = parser.parse_args()
    versions = {'python': sys.version.split()[0], 'sdk': importlib.metadata.version('claude-agent-sdk')}
    asyncio.run(Bridge(args.state, versions).run())


if __name__ == '__main__':
    main()
