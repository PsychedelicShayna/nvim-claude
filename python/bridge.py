"""JSON-RPC stdio bridge. One worker owns SDK connect/receive/disconnect scopes."""
import argparse
import asyncio
import importlib.metadata
import json
import os
from pathlib import Path
import sys
import time

import claude_agent_sdk as sdk
from contracts import envelope, parse_model, validate_edit
from storage import Store

DEFAULT_PROMPT = (Path(__file__).resolve().parent.parent / 'resources/system.txt').read_text()
DEFAULT_CONFIG = {'model': 'claude-haiku-5-5', 'effort': 'low', 'context_limit_tokens': 100000}


def emit(message):
    body = json.dumps({'jsonrpc': '2.0', **message}, ensure_ascii=False).encode()
    sys.stdout.buffer.write(f'Content-Length: {len(body)}\r\n\r\n'.encode() + body)
    sys.stdout.buffer.flush()


class Bridge:
    def __init__(self, state, config=None):
        self.store = Store(state)
        self.config = {**DEFAULT_CONFIG, **(config or {})}
        self.conversation = self.store.create(self.config)
        self.client = None
        self.prompt = DEFAULT_PROMPT
        self.sticky = False
        self.metadata = {}
        self.cancelled = False
        self.busy = False
        self.queue = asyncio.Queue()
        self.ttl = 300
        self.request = None

    async def close_client(self):
        if self.client:
            await self.client.disconnect()
            self.client = None

    async def connect(self):
        if self.client:
            return
        c = self.conversation
        # Refuse inherited API/cloud credentials instead of silently changing billing.
        keys = ('ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'CLAUDE_CODE_USE_BEDROCK',
                'CLAUDE_CODE_USE_VERTEX', 'CLAUDE_CODE_USE_FOUNDRY', 'CLAUDE_CODE_USE_ANTHROPIC_AWS')
        if any(os.environ.get(key) for key in keys):
            raise ValueError('API/cloud billing environment is present. Start Neovim without those variables to use runtime subscription login; no billing fallback was attempted.')
        env = {'CLAUDE_CODE_DISABLE_CLAUDE_MDS': '1', 'CLAUDE_CODE_DISABLE_AUTO_MEMORY': '1',
               'CLAUDE_AGENT_SDK_DISABLE_BUILTIN_AGENTS': '1', 'CLAUDE_CODE_AUTO_CONNECT_IDE': 'false',
               'CLAUDE_CODE_DISABLE_BUNDLED_SKILLS': '1', 'CLAUDE_CODE_DISABLE_ATTACHMENTS': '1',
               'CLAUDE_CODE_DISABLE_CRON': '1', 'CLAUDE_CODE_DISABLE_BACKGROUND_TASKS': '1',
               'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC': '1', 'DISABLE_AUTO_COMPACT': '1',
               'CLAUDE_CODE_MAX_OUTPUT_TOKENS': '4096', 'CLAUDE_CODE_EFFORT_LEVEL': self.config.get('effort') or '',
               'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION': 'false', 'CLAUDE_CODE_DISABLE_ADVISOR_TOOL': '1'}
        options = sdk.ClaudeAgentOptions(model=self.config['model'], effort=self.config.get('effort'),
            thinking={'type': 'disabled'}, tools=[], skills=[], agents={}, plugins=[], mcp_servers={},
            strict_mcp_config=True, setting_sources=[], include_partial_messages=True,
            permission_mode='dontAsk', cwd=c['cwd'],
            system_prompt={'type': 'custom', 'prompt': self.prompt, 'snapshot': False},
            settings=json.dumps({'disableAllHooks': True, 'autoMemoryEnabled': False, 'idleCompaction': False}),
            env=env, resume=c['session'] if c['started'] else None,
            session_id=None if c['started'] else c['session'])
        self.client = sdk.ClaudeSDKClient(options)
        try:
            await self.client.connect()
            self.metadata = await self.client.get_server_info() or {}
            context = await self.client.get_context_usage()
            mcp = await self.client.get_mcp_status()
            if context.get('mcpTools') or context.get('memoryFiles') or context.get('agents') or mcp.get('mcpServers'):
                raise ValueError('Runtime isolation failed: unexpected tools, memory, agents or MCP servers')
            account = self.metadata.get('account', {})
            self.ttl = 3600 if account.get('subscriptionType') and account.get('apiProvider') == 'firstParty' else 300
            c['occupancy'] = {k: context.get(k) for k in ('totalTokens', 'rawMaxTokens', 'model', 'apiUsage')}
        except BaseException:
            await self.close_client()
            raise

    def status(self, state):
        if self.request:
            emit({'method': 'status', 'params': {'request_id': self.request['id'], 'epoch': self.request['params'].get('epoch'), 'state': state}})

    async def run_query(self, prompt, streaming=True):
        if self.cancelled:
            raise RuntimeError('Request canceled before model dispatch')
        await self.client.query(prompt)
        text, partial, completed, compacted = [], [], False, False
        async for message in self.client.receive_response():
            if isinstance(message, sdk.SystemMessage):
                if message.subtype == 'init':
                    data = message.data
                    if data.get('tools') or data.get('mcp_servers') or data.get('agents') or data.get('skills'):
                        await self.client.interrupt()
                        raise ValueError('Runtime announced unexpected model-accessible tools or skills')
                    sid = data.get('session_id')
                    if sid and sid not in self.conversation['sessions']:
                        self.conversation['sessions'].append(sid)
                    if sid:
                        self.conversation['session'] = sid
                    self.conversation['started'] = True
                    self.store.flush()
                elif message.subtype == 'compact_boundary':
                    compacted = True
                    self.conversation['baselines'] = {}
            elif isinstance(message, sdk.StreamEvent):
                delta = message.event.get('delta', {})
                if delta.get('type') == 'text_delta':
                    chunk = delta['text']
                    partial.append(chunk)
                    if streaming and not self.cancelled:
                        emit({'method': 'partial', 'params': {'request_id': self.request['id'], 'epoch': self.request['params'].get('epoch'), 'text': chunk}})
            elif isinstance(message, sdk.AssistantMessage):
                text.extend(block.text for block in message.content if isinstance(block, sdk.TextBlock))
            elif isinstance(message, sdk.ResultMessage):
                if message.is_error:
                    raise RuntimeError(message.result or 'Claude failed; check :NvClaude login and account access')
                completed = True
                self.conversation['started'] = True
                self.conversation['session'] = message.session_id
                if message.session_id not in self.conversation['sessions']:
                    self.conversation['sessions'].append(message.session_id)
                for key, value in (message.usage or {}).items():
                    if isinstance(value, (int, float)):
                        usage = self.conversation['usage']
                        usage[key] = usage.get(key, 0) + value
        if self.cancelled:
            raise RuntimeError('Request canceled; no edit was applied')
        if not completed:
            raise RuntimeError('Runtime ended without a successful result')
        return ''.join(text) if text else ''.join(partial), compacted

    async def budget(self, payload, compact=False):
        usage = await self.client.get_context_usage()
        self.conversation['occupancy'] = {k: usage.get(k) for k in ('totalTokens', 'rawMaxTokens', 'model', 'apiUsage')}
        limit = self.config.get('context_limit_tokens')
        # Context telemetry and auto-compaction are not preflight enforcement.
        # This runtime exposes no authoritative next-request token counter or hard input limit.
        if limit is not None:
            raise ValueError(f'Unsupported hard prompt budget ({limit} tokens): Claude Code {self.metadata.get("claude_code_version", "unknown")} exposes context telemetry and compaction thresholds, not an enforceable next-request ceiling. No model request was sent. A model-default budget explicitly removes the local ceiling; it is not 100k protection.')
        bound = len(payload.encode('utf-8')) + len(self.prompt.encode('utf-8')) + 8192
        physical = usage.get('rawMaxTokens')
        if physical and bound + 4096 >= physical:
            raise ValueError('Mandatory prompt and target exceed the conservative physical-context allowance; reduce the supplied selection/context')
        if not compact and physical and usage.get('totalTokens', 0) + bound + 4096 > physical * .6 and self.conversation['started']:
            self.status('compacting')
            await self.compact()
            return True
        return False

    async def compact(self):
        await self.connect()
        await self.budget('/compact', compact=True)
        _, boundary = await self.run_query('/compact', streaming=False)
        if not boundary:
            raise RuntimeError('Runtime did not emit a compaction boundary; compaction was not confirmed')
        self.conversation['baselines'] = {}
        self.store.flush()
        return 'Compacted by the runtime; exact document baselines invalidated.'

    async def turn(self, p):
        c = self.conversation
        if not c['saved'] and c['last_request'] and time.time() - c['last_request'] > self.ttl:
            await self.close_client()
            self.conversation = c = self.store.create(self.config, self.sticky)
        self.status('continued' if c['started'] else 'new')
        await self.connect()
        encoded = envelope(p, c['baselines'])
        payload = json.dumps(encoded, ensure_ascii=False)
        if await self.budget(payload):
            encoded = envelope(p, {})
            payload = json.dumps(encoded, ensure_ascii=False)
            await self.budget(payload)
        c['last_request'] = time.time()
        if not c['first_prompt']:
            c['first_prompt'] = p['instruction']
        self.store.flush()
        try:
            raw, compacted = await self.run_query(payload)
            c['turns'].append({'request': encoded, 'assistant': raw})
            if 'document' in p and not compacted:
                c['baselines'][p['document']['id']] = {'text': p['snapshot'], 'revision': p['revision']}
            self.store.flush()
            if p['operation'] != 'ask':
                try:
                    validate_edit(raw, p['targets'])
                except (ValueError, TypeError) as error:
                    # Return raw invalid content to Lua for inspection, never insert it.
                    return {'raw': raw, 'validation_error': str(error)}
            return {'raw': raw}
        except BaseException:
            c['baselines'] = {}
            self.store.flush()
            raise

    async def dispatch(self, method, p):
        if method == 'turn':
            return await self.turn(p)
        if method in ('new', 'clear'):
            await self.close_client()
            self.conversation = self.store.create(self.config, self.sticky)
            return 'Started an empty conversation; saved checkpoints retained.'
        if method == 'resume':
            await self.close_client()
            self.conversation = self.store.resume(p['id'])
            self.config = dict(self.conversation['config'])
            return 'Saved conversation resumed; editor targets were not restored.'
        if method == 'list':
            return self.store.list()
        if method == 'save':
            self.conversation['saved'] = True
            self.store.flush()
            return 'Conversation saved, including future completed turns.'
        if method == 'sticky':
            value = p.get('value')
            if value not in (None, 'on', 'off'):
                raise ValueError('Use sticky on|off')
            self.sticky = not self.sticky if value is None else value == 'on'
            if self.sticky:
                await self.dispatch('save', {})
            return 'Sticky ' + ('on' if self.sticky else 'off')
        if method == 'system':
            if 'text' in p or p.get('reset'):
                await self.close_client()
                self.prompt = DEFAULT_PROMPT if p.get('reset') else p['text']
                self.conversation['baselines'] = {}
                return 'Prompt changed; next turn resumes history with snapshot=False. Prefix cache reuse may change.'
            return self.prompt
        if method == 'models':
            await self.connect()
            return self.metadata.get('models', [])
        if method == 'configure':
            await self.connect()
            models = self.metadata.get('models', [])
            config = parse_model(p['expression'], self.config, models) if 'expression' in p else {**self.config, **p}
            if not isinstance(config['model'], str) or not config['model']:
                raise ValueError('Model must be a nonempty string')
            limit = config.get('context_limit_tokens')
            if limit is not None and (not isinstance(limit, int) or limit <= 0):
                raise ValueError('Context budget must be a positive integer or model default')
            metadata = next((m for m in models if config['model'] in (m['value'], m.get('resolvedModel'))), None)
            effort = config.get('effort')
            if metadata and effort is not None and effort not in metadata.get('supportedEffortLevels', []):
                raise ValueError('Runtime does not advertise that effort for the selected model')
            await self.close_client()
            self.config = config
            self.conversation['config'] = dict(config)
            self.conversation['baselines'] = {}
            self.store.flush()
            return config
        if method == 'compact':
            return await self.compact()
        if method in ('initialize', 'info'):
            await self.connect()
            c = self.conversation
            account = self.metadata.get('account', {})
            return {'protocol_version': 1, 'sdk': importlib.metadata.version('claude-agent-sdk'),
                    'python': sys.version.split()[0], 'cli': self.metadata.get('claude_code_version'),
                    'config': self.config, 'conversation': c['id'], 'saved': c['saved'], 'sticky': self.sticky,
                    'occupancy_estimate': c['occupancy'], 'cumulative_usage': c['usage'],
                    'budget_enforcement': 'unsupported; capped requests refused before dispatch',
                    'cache': {'ttl_seconds_estimate': self.ttl, 'remaining_estimate': max(0, self.ttl - (time.time() - c['last_request'])), 'provenance': 'runtime account class plus documented default, not cache-entry telemetry'},
                    'authentication': {'provider': account.get('apiProvider', 'unknown'), 'subscription': account.get('subscriptionType', 'unknown')},
                    'thinking': 'disabled requested; runtime model metadata may report supportsThinkingOff=false',
                    'capabilities': self.metadata.get('capabilities', [])}
        raise ValueError('Unknown method: ' + method)

    async def reader(self):
        reader = asyncio.StreamReader(limit=16777216)
        protocol = asyncio.StreamReaderProtocol(reader)
        transport, _ = await asyncio.get_running_loop().connect_read_pipe(lambda: protocol, sys.stdin.buffer)
        try:
            while True:
                try:
                    header = await reader.readuntil(b'\r\n\r\n')
                except asyncio.IncompleteReadError:
                    break
                fields = dict(line.decode().split(':', 1) for line in header.split(b'\r\n') if line)
                length = int(fields.get('Content-Length', '-1'))
                if not 0 <= length <= 16777216:
                    raise ValueError('Invalid frame length')
                message = json.loads(await reader.readexactly(length))
                method = message['method']
                if method == 'cancel':
                    self.cancelled = True
                    if self.client and self.busy:
                        await self.client.interrupt()
                    emit({'id': message['id'], 'result': 'Canceled'})
                elif method in ('new', 'clear', 'resume') and self.busy:
                    self.cancelled = True
                    if self.client:
                        await self.client.interrupt()
                    await self.queue.put(message)
                elif self.busy:
                    emit({'id': message['id'], 'error': {'code': -32001, 'message': 'Conversation busy; retain your draft and retry after completion'}})
                else:
                    self.cancelled = False
                    self.busy = True
                    await self.queue.put(message)
        finally:
            self.cancelled = True
            if self.client and self.busy:
                await self.client.interrupt()
            await self.queue.put(None)
            transport.close()

    async def serve(self):
        reader = asyncio.create_task(self.reader())
        try:
            while True:
                self.request = message = await self.queue.get()
                if message is None:
                    break
                try:
                    result = await self.dispatch(message['method'], message.get('params', {}))
                    emit({'id': message['id'], 'result': result})
                except Exception as error:
                    emit({'id': message['id'], 'error': {'code': -32000, 'message': str(error)}})
                finally:
                    self.busy = not self.queue.empty()
            await reader
        finally:
            reader.cancel()
            await self.close_client()
            self.store.release()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--state', required=True)
    parser.add_argument('--login', action='store_true')
    parser.add_argument('--config', default='{}')
    args = parser.parse_args()
    if args.login:
        executable = Path(sdk.__file__).parent / '_bundled' / 'claude'
        os.execv(str(executable), [str(executable), 'auth', 'login'])
    asyncio.run(Bridge(args.state, json.loads(args.config)).serve())


if __name__ == '__main__':
    main()
