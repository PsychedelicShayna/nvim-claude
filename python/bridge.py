"""Content-Length framed JSON-RPC. Stdout is exclusively protocol data."""
import asyncio
import json
import signal
import sys
from runtime import Runtime


def send(value):
    payload = json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode()
    sys.stdout.buffer.write(b'Content-Length: ' + str(len(payload)).encode() + b'\r\n\r\n' + payload)
    sys.stdout.buffer.flush()


async def main():
    reader = asyncio.StreamReader(limit=32 * 1024 * 1024)
    protocol = asyncio.StreamReaderProtocol(reader)
    await asyncio.get_running_loop().connect_read_pipe(lambda: protocol, sys.stdin.buffer)
    queue = asyncio.Queue()
    runtime = Runtime(sys.argv[1], lambda method, params: send({'jsonrpc': '2.0', 'method': method, 'params': params}))
    active = False

    async def receive():
        nonlocal active
        try:
            while True:
                header = await reader.readuntil(b'\r\n\r\n')
                fields = dict(line.split(b':', 1) for line in header.strip().split(b'\r\n'))
                length = int(next(v for k, v in fields.items() if k.lower() == b'content-length'))
                if length < 0 or length > 32 * 1024 * 1024:
                    raise ValueError('Frame size out of bounds')
                message = json.loads(await reader.readexactly(length))
                if message.get('method') == 'cancel':
                    runtime.cancelled = True
                    if runtime.client and active:
                        await runtime.client.interrupt()
                    send({'jsonrpc': '2.0', 'id': message.get('id'), 'result': {'message': 'Cancelled'}})
                elif message.get('method') == 'turn' and active:
                    send({'jsonrpc': '2.0', 'id': message['id'], 'error': {'code': -32000, 'message': 'Conversation is busy; draft retained'}})
                else:
                    if message.get('method') in ('turn', 'compact'):
                        active = True
                        runtime.cancelled = False
                    await queue.put(message)
        except (asyncio.IncompleteReadError, BrokenPipeError):
            pass
        finally:
            runtime.cancelled = True
            if runtime.client and active:
                await runtime.client.interrupt()
            await queue.put(None)

    task = asyncio.create_task(receive())
    try:
        while True:
            message = await queue.get()
            if message is None:
                break
            try:
                result = await runtime.command(message['method'], message.get('params', {}))
                send({'jsonrpc': '2.0', 'id': message['id'], 'result': result})
            except Exception as error:
                send({'jsonrpc': '2.0', 'id': message.get('id'), 'error': {'code': -32000, 'message': str(error)}})
            finally:
                if message.get('method') in ('turn', 'compact'):
                    active = False
    finally:
        task.cancel()
        await runtime.close()


if __name__ == '__main__':
    try:
        asyncio.run(main())
    except (BrokenPipeError, KeyboardInterrupt):
        pass
