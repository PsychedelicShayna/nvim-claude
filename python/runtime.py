"""One sequential SDK conversation. Editor operations never give Claude tools."""
import asyncio
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import subprocess
import time

import claude_agent_sdk as sdk
from policy import encode, make_envelope, parse_model, present, validate_edit, PRESETS
from storage import Store
from budget import Gate

SYSTEM = (Path(__file__).resolve().parent.parent / 'resources' / 'system.txt').read_text()
CLI = Path(sdk.__file__).parent / '_bundled' / 'claude'
OVERHEAD = 16384
OUTPUT_RESERVE = 4096


class Runtime:
    def __init__(self, root, emit):
        self.store = Store(root)
        self.emit = emit
        self.client = None
        self.config = {'model': 'claude-haiku-5-5', 'effort': 'low', 'context_limit_tokens': 100000}
        self.prompt = SYSTEM
        self.sticky = False
        self.baselines = {}
        self.catalogue = []
        self.context = {}
        self.watermarks = 'allow'
        self.mapping = None
        self.cancelled = False
        self.billing = 'unknown'
        self.ttl = 300
        self.versions = {'python': platform.python_version(), 'sdk': importlib.metadata.version('claude-agent-sdk'), 'cli': subprocess.check_output([str(CLI), '--version'], text=True).strip()}
        self.record = self.store.create(dict(self.config))
        self.gate = Gate()

    async def disconnect(self):
        if self.client:
            client, self.client = self.client, None
            await client.disconnect()

    async def close(self):
        await self.disconnect()
        self.store.release()
        self.gate.close()

    async def connect(self):
        if self.client:
            return
        try:
            await self._connect()
        except BaseException:
            await self.disconnect()
            raise

    async def _connect(self):
        # Never silently turn an inherited paid key into the personal default.
        if os.getenv('ANTHROPIC_API_KEY') or os.getenv('ANTHROPIC_AUTH_TOKEN') or os.getenv('ANTHROPIC_BASE_URL') or any(os.getenv(k) for k in ('CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX', 'CLAUDE_CODE_USE_FOUNDRY')):
            raise ValueError('API key or custom provider routing detected. Remove it to use the official runtime login; this plugin never silently changes billing or routing.')
        env = {
            'CLAUDE_CODE_AUTO_CONNECT_IDE': 'false', 'CLAUDE_CODE_DISABLE_AUTO_MEMORY': '1',
            'CLAUDE_CODE_DISABLE_CLAUDE_MDS': '1', 'CLAUDE_CODE_DISABLE_ATTACHMENTS': '1',
            'CLAUDE_AGENT_SDK_DISABLE_BUILTIN_AGENTS': '1', 'CLAUDE_CODE_DISABLE_BUNDLED_SKILLS': '1',
            'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC': '1', 'CLAUDE_CODE_DISABLE_BACKGROUND_TASKS': '1',
            'CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK': '1', 'CLAUDE_CODE_DISABLE_ADVISOR_TOOL': '1',
            'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION': 'false', 'CLAUDE_CODE_EFFORT_LEVEL': self.config.get('effort') or '',
            'CLAUDE_CODE_MAX_OUTPUT_TOKENS': str(OUTPUT_RESERVE), 'DISABLE_AUTOUPDATER': '1',
            'CLAUDE_CODE_AUTO_COMPACT_WINDOW': str(max(100000, min(self.config.get('context_limit_tokens') or 1000000, 1000000))),
            'DISABLE_AUTO_COMPACT': '1',
            'ANTHROPIC_BASE_URL': self.gate.url,
            'CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL': '1',
        }
        persisted = sdk.get_session_info(self.record['sdk_session'], directory=self.record['cwd']) is not None
        opts = sdk.ClaudeAgentOptions(
            model=self.config['model'], effort=self.config.get('effort'), thinking={'type': 'disabled'},
            system_prompt={'type': 'custom', 'prompt': self.prompt, 'snapshot': False},
            tools=[], mcp_servers={}, strict_mcp_config=True, setting_sources=[], skills=[], agents={}, plugins=[],
            cwd=self.record['cwd'], env=env, include_partial_messages=True,
            permission_mode='dontAsk', settings=json.dumps({'disableAllHooks': True}),
            resume=self.record['sdk_session'] if persisted else None,
            session_id=None if persisted else self.record['sdk_session'],
        )
        client = sdk.ClaudeSDKClient(opts)
        await client.connect()
        self.client = client
        info = await client.get_server_info() or {}
        self.catalogue = info.get('models', [])
        if info.get('agents'):
            raise ValueError('Runtime announced unexpected agents; refusing model dispatch')
        self.context = await client.get_context_usage()
        if self.context.get('memoryFiles') or self.context.get('mcpTools') or self.context.get('agents') or self.context.get('mcpInstructions'):
            raise ValueError('Runtime loaded unintended memory, MCP tools, or agents')
        mcp = await client.get_mcp_status()
        if mcp.get('mcpServers'):
            raise ValueError('Runtime announced unexpected MCP servers')
        entry = next((m for m in self.catalogue if self.config['model'] in (m.get('value'), m.get('resolvedModel'))), None)
        if self.config.get('effort') and (not entry or self.config['effort'] not in entry.get('supportedEffortLevels', [])):
            raise ValueError('Runtime has not announced support for this model/effort combination; choose an announced effort or omit it')
        auth = await asyncio.create_subprocess_exec(str(CLI), 'auth', 'status', stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        out, _ = await auth.communicate()
        try:
            status = json.loads(out)
            self.billing = status.get('authMethod', 'unknown')
            self.ttl = 3600 if status.get('subscriptionType') and self.billing == 'claude.ai' else 300
        except ValueError:
            pass
        override = os.getenv('CLAUDE_CODE_PROMPT_CACHE_TTL')
        if override in ('5m', '1h'):
            self.ttl = {'5m': 300, '1h': 3600}[override]
        if os.getenv('FORCE_PROMPT_CACHING_5M') in ('1', 'true'):
            self.ttl = 300
        self.gate.limit = self.limit()

    def limit(self):
        physical = self.context.get('rawMaxTokens') or 200000
        return min(self.config.get('context_limit_tokens') or physical, physical - OUTPUT_RESERVE)

    def bound(self, text=''):
        # UTF-8 bytes bound byte-fallback tokenization of host-controlled text.
        # Fixed runtime allowance is separately reported, not an exact token count.
        return OVERHEAD + len(self.prompt.encode()) + self.record['history_bytes'] + len(text.encode())

    async def stream(self, prompt, request, compact=False):
        if self.cancelled:
            raise ValueError('Request cancelled before dispatch')
        async def message():
            yield {'type': 'user', 'message': {'role': 'user', 'content': prompt}, 'client_composed': not compact}
        await self.client.query(message())
        raw, final_text, result, boundary = '', '', None, False
        async for msg in self.client.receive_response():
            if isinstance(msg, sdk.SystemMessage):
                if msg.subtype == 'init':
                    if msg.data.get('tools') or msg.data.get('mcp_servers') or msg.data.get('agents'):
                        await self.client.interrupt()
                        raise ValueError('No-tools contract violated by runtime initialization')
                if msg.subtype == 'compact_boundary':
                    boundary = True
                    self.baselines.clear()
            elif isinstance(msg, sdk.StreamEvent):
                event = msg.event
                if event.get('type') == 'content_block_delta' and event.get('delta', {}).get('type') == 'text_delta':
                    raw += event['delta']['text']
                    if not compact:
                        self.emit('partial', {**request, 'text': present(raw, self.watermarks, self.mapping)})
            elif isinstance(msg, sdk.AssistantMessage):
                if getattr(msg, 'error', None):
                    raise ValueError('Claude error: ' + str(msg.error))
                final_text += ''.join(block.text for block in msg.content if isinstance(block, sdk.TextBlock))
            elif isinstance(msg, sdk.ResultMessage):
                result = msg
        raw = final_text or raw
        if result is None or result.is_error:
            raise ValueError('Claude request failed: ' + (str(getattr(result, 'result', 'no final result'))))
        if self.cancelled or getattr(result, 'terminal_reason', None) in ('aborted_streaming', 'aborted_tools'):
            raise ValueError('Request cancelled; no edit applied')
        self.record['turns'] += 1
        self.record['sdk_session'] = result.session_id
        if result.session_id not in self.record['sessions']:
            self.record['sessions'].append(result.session_id)
        self.record['history_bytes'] += len(prompt.encode()) + len(raw.encode()) + 256
        # Result usage is per query; keep billed usage separate from occupancy.
        for key, value in (result.usage or {}).items():
            if isinstance(value, (int, float)):
                self.record['cumulative_usage'][key] = self.record['cumulative_usage'].get(key, 0) + value
        self.store.write()
        self.context = await self.client.get_context_usage()
        return raw, boundary

    async def compact(self, request):
        await self.connect()
        if not self.record['turns']:
            raise ValueError('There is no conversation to compact')
        if self.bound('/compact') + OUTPUT_RESERVE > self.limit():
            raise ValueError('Compaction cannot safely fit the chosen budget. Save this conversation and start new.')
        self.emit('status', {**request, 'text': 'compacting'})
        _, boundary = await self.stream('/compact', request, compact=True)
        self.baselines.clear()
        if not boundary:
            raise ValueError('Runtime did not announce a compaction boundary; no compaction claimed')
        # The complete-wire gate still enforces admission after compaction.
        self.record['history_bytes'] = int(self.context.get('totalTokens', 0)) * 4
        self.store.write()
        return {'message': 'Runtime compacted context; exact file baselines invalidated.'}

    async def turn(self, request):
        if not self.record['saved'] and self.record['last_request'] and time.time() - self.record['last_request'] >= self.ttl:
            await self.fresh()
        await self.connect()
        envelope = make_envelope(request, self.baselines)
        prompt = encode(envelope)
        if self.bound(prompt) + OUTPUT_RESERVE * 4 + 4096 > self.limit() and self.record['turns']:
            await self.compact(request)
            envelope = make_envelope(request, self.baselines)
            prompt = encode(envelope)
        if self.bound(prompt) > self.limit():
            document = request.get('document')
            if document and envelope.get('context', {}).get('kind') == 'snapshot':
                lines = document['text'].splitlines(keepends=True)
                first = min(t['start'][0] for t in request['targets'])
                last = max(t['end'][0] for t in request['targets']) + 1
                lo, hi = max(0, first - 8), min(len(lines), last + 8)
                if lo > 0 or hi < len(lines):
                    envelope['context'] = {'kind': 'excerpt', 'revision': document['revision'],
                        'start_row': lo, 'end_row': hi, 'omitted_before': lo,
                        'omitted_after': len(lines) - hi, 'text': ''.join(lines[lo:hi])}
                    prompt = encode(envelope)
            if self.bound(prompt) > self.limit():
                raise ValueError('Mandatory instruction, target, and context exceed the local admission budget. No oversized request was sent; narrow the selection or start new.')
        self.emit('status', {**request, 'text': 'continued' if self.record['turns'] else 'new'})
        self.record['last_request'] = time.time()
        self.record['first_prompt'] = self.record['first_prompt'] or request['instruction']
        self.store.write()
        try:
            raw, _ = await self.stream(prompt, {'request': request['request'], 'epoch': request['epoch']})
        except BaseException:
            self.baselines.clear()
            # Delivery is uncertain. Reserve both sent input and maximum output.
            self.record['history_bytes'] += len(prompt.encode()) + OUTPUT_RESERVE * 4
            self.store.write()
            raise
        if request.get('document'):
            if envelope['context']['kind'] == 'excerpt':
                self.baselines.pop(request['document']['id'], None)
            else:
                self.baselines[request['document']['id']] = request['document']
        if request['operation'] == 'ask':
            return {'text': present(raw, self.watermarks, self.mapping), 'raw': raw}
        try:
            data = validate_edit(raw, request['targets'], request.get('block', False))
        except (ValueError, TypeError) as error:
            return {'status': 'invalid', 'message': str(error), 'raw': raw}
        for replacement in data.get('replacements', []):
            replacement['text'] = present(replacement['text'], self.watermarks, self.mapping)
        return {**data, 'raw': raw}

    async def fresh(self):
        await self.disconnect()
        self.baselines.clear()
        self.record = self.store.create(dict(self.config), self.sticky)

    async def command(self, method, params):
        if method == 'initialize':
            self.config.update(params.get('config', {}))
            self.record['config'] = dict(self.config)
            self.mapping = params.get('punctuation')
            self.store.write()
            return {'versions': self.versions, 'cli': str(CLI), 'presets': PRESETS, 'system': self.prompt, 'config': self.config}
        if method == 'turn':
            return await self.turn(params)
        if method in ('new', 'clear'):
            await self.fresh()
            return {'message': 'New empty conversation; saved checkpoints retained'}
        if method == 'save':
            self.record['saved'] = True
            self.store.write()
            return {'message': 'Conversation saved', 'id': self.record['id']}
        if method == 'sticky':
            self.sticky = params.get('enabled', not self.sticky)
            if self.sticky:
                self.record['saved'] = True
                self.store.write()
            return {'message': 'Sticky ' + ('on' if self.sticky else 'off')}
        if method == 'list':
            return self.store.list()
        if method == 'resume':
            await self.disconnect()
            self.record = self.store.resume(params['id'])
            self.config = dict(self.record['config'])
            self.baselines.clear()
            return {'message': 'Saved conversation resumed', 'config': self.config}
        if method == 'compact':
            return await self.compact(params)
        if method == 'models':
            await self.connect()
            return {'models': self.catalogue, 'presets': PRESETS, 'config': self.config}
        if method == 'configure':
            await self.connect()
            config = parse_model(params['expression'], self.config, self.catalogue) if 'expression' in params else params['config']
            if not isinstance(config.get('model'), str) or not config['model']:
                raise ValueError('Model must be a nonempty runtime ID')
            limit = config.get('context_limit_tokens')
            if limit is not None and (not isinstance(limit, int) or limit <= 0):
                raise ValueError('Context limit must be positive or model default')
            entry = next((m for m in self.catalogue if config['model'] in (m.get('value'), m.get('resolvedModel'))), {})
            if config.get('effort') and config['effort'] not in entry.get('supportedEffortLevels', []):
                raise ValueError('Effort support is not announced for this model; use raw configuration with effort omitted')
            await self.disconnect()
            self.config = config
            self.record['config'] = dict(config)
            self.store.write()
            self.baselines.clear()
            return {'config': config, 'message': 'Model configuration updated; history retained, cache may be cold'}
        if method == 'system':
            await self.disconnect()
            self.prompt = params.get('text', SYSTEM)
            self.baselines.clear()
            return {'message': 'System prompt updated for the next turn; history retained, cache prefix changed'}
        if method == 'watermarks':
            mode = params['mode']
            if mode not in ('allow', 'remove', 'replace'):
                raise ValueError('Use allow, remove, or replace')
            self.watermarks = mode
            return {'message': 'Punctuation policy: ' + mode}
        if method == 'info':
            return {
                'config': self.config, 'resolved_model': self.context.get('model'),
                'versions': self.versions, 'retention': 'saved' if self.record['saved'] else 'ephemeral',
                'sticky': self.sticky, 'conversation': self.record['id'],
                'occupancy': self.context, 'cumulative_usage': self.record['cumulative_usage'],
                'budget': {'planning_bound': self.bound(), 'last_complete_wire_bound': self.gate.last_bound,
                    'last_refusal': self.gate.refused, 'runtime_allowance': OVERHEAD,
                    'output_reserve': OUTPUT_RESERVE,
                    'provenance': 'Complete text-only API request UTF-8 bytes plus 16384 tokens of provider framing reserve; enforced before HTTPS forwarding, including compaction. Runtime occupancy is separately estimated.'},
                'cache': {'ttl_seconds': self.ttl,
                    'remaining_seconds': max(0, self.ttl - (time.time() - self.record['last_request'])),
                    'provenance': 'Estimated from authentication and TTL overrides; not a cache hit guarantee'},
                'authentication': self.billing,
            }
        raise ValueError('Unknown bridge method: ' + method)
