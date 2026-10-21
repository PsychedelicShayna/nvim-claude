import asyncio
import importlib.util
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import unittest


@unittest.skipUnless(importlib.util.find_spec('claude_agent_sdk'), 'Run with the provisioned SDK Python')
class SessionControls(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        scratch = Path(os.environ.get('XDG_CACHE_HOME', Path.home() / '.cache')) / 'npi-canary'
        scratch.mkdir(parents=True, exist_ok=True)
        temporary = tempfile.TemporaryDirectory(dir=scratch, prefix='nvim-claude-rpc-')
        self.addCleanup(temporary.cleanup)
        bridge = Path(__file__).resolve().parents[1] / 'python' / 'bridge.py'
        self.process = await asyncio.create_subprocess_exec(
            sys.executable, '-u', str(bridge), '--state', temporary.name,
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE, start_new_session=True)
        self.serial = 0
        await self.rpc('initialize', {})

    async def rpc(self, method, params):
        self.serial += 1
        body = json.dumps({'jsonrpc': '2.0', 'id': self.serial, 'method': method, 'params': params}).encode()
        self.process.stdin.write(f'Content-Length: {len(body)}\r\n\r\n'.encode() + body)
        await self.process.stdin.drain()
        while True:
            header = await asyncio.wait_for(self.process.stdout.readuntil(b'\r\n\r\n'), 10)
            size = int(header.split(b':', 1)[1].strip())
            reply = json.loads(await self.process.stdout.readexactly(size))
            if reply.get('id') == self.serial:
                return reply

    async def asyncTearDown(self):
        if self.process.returncode is None:
            try:
                await self.rpc('shutdown', {})
                await asyncio.wait_for(self.process.wait(), 5)
            except (asyncio.TimeoutError, BrokenPipeError, asyncio.IncompleteReadError):
                os.killpg(self.process.pid, signal.SIGTERM)
                try:
                    await asyncio.wait_for(self.process.wait(), 5)
                except asyncio.TimeoutError:
                    os.killpg(self.process.pid, signal.SIGKILL)
                    await self.process.wait()
        diagnostics = (await self.process.stderr.read()).decode()
        self.assertEqual(self.process.returncode, 0, diagnostics)

    async def test_bad_parameters_do_not_disable_saved_session_controls(self):
        initial = (await self.rpc('info', {}))['result']['conversation']
        bad = await self.rpc('info', [])
        self.assertIn('error', bad)
        await self.rpc('save', {})
        fresh = (await self.rpc('new', {}))['result']['id']
        self.assertNotEqual(fresh, initial)
        saved = (await self.rpc('list', {}))['result']
        self.assertIn(initial, {record['id'] for record in saved})
        await self.rpc('resume', {'id': initial})
        resumed = (await self.rpc('info', {}))['result']
        self.assertEqual(resumed['conversation'], initial)
        self.assertTrue(resumed['saved'])
        await self.rpc('sticky', {'enabled': True})
        await self.rpc('new', {})
        await self.rpc('sticky', {'enabled': False})
        current = (await self.rpc('info', {}))['result']
        self.assertTrue(current['saved'])
        self.assertFalse(current['sticky'])


if __name__ == '__main__':
    unittest.main()
