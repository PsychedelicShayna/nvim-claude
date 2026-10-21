"""Loopback-only admission gate for the SDK's fully assembled API requests.

The editor protocol remains stdio. An unguessable per-process URL prevents
browser access. Credentials pass through in memory, never to disk or logs.
Only the official first-party HTTPS endpoint is forwarded to.
"""
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import secrets
import threading

OVERHEAD = 16384


def wire_bound(body):
    """Conservative byte-fallback bound, including JSON and message framing.

Reject non-text blocks: their token cost is not bounded by their JSON size.
All runtime-generated system/history text is already in this request body.
The reserve covers provider framing that isn't represented in the JSON.
"""
    data = json.loads(body)
    if data.get('tools'):
        raise ValueError('Runtime attempted to expose model tools')
    for message in data.get('messages', []):
        content = message.get('content', [])
        if isinstance(content, str):
            continue
        for block in content:
            if block.get('type') not in ('text', 'thinking', 'redacted_thinking'):
                raise ValueError('Cannot establish a text-only token bound for ' + str(block.get('type')))
            if block.get('type') == 'redacted_thinking':
                raise ValueError('Opaque reasoning has no safe local token bound')
    return len(body) + OVERHEAD


class Gate:
    def __init__(self):
        self.secret = secrets.token_urlsafe(32)
        self.limit = 100000
        self.last_bound = None
        self.refused = None
        gate = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'

            def log_message(self, *_):
                pass

            def reject(self, message, code=400):
                payload = json.dumps({'type': 'error', 'error': {'type': 'invalid_request_error', 'message': message}}).encode()
                self.send_response(code)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(payload)))
                self.send_header('Connection', 'close')
                self.end_headers()
                self.wfile.write(payload)
                self.close_connection = True

            def do_POST(self):
                prefix = '/' + gate.secret
                if not self.path.startswith(prefix + '/') or self.headers.get('Origin'):
                    self.reject('Not found', 404)
                    return
                path = self.path[len(prefix):]
                if path.split('?')[0] not in ('/v1/messages', '/v1/messages/count_tokens'):
                    self.reject('Endpoint not permitted by editor bridge', 404)
                    return
                try:
                    length = int(self.headers.get('Content-Length', '-1'))
                    if length < 0 or length > 16 * 1024 * 1024:
                        raise ValueError('Request body is missing or too large')
                    body = self.rfile.read(length)
                    if path.split('?')[0] == '/v1/messages':
                        bound = wire_bound(body)
                        gate.last_bound = bound
                        if bound > gate.limit:
                            raise ValueError(f'Local prompt ceiling refused request before forwarding: conservative complete-wire bound {bound} > {gate.limit} tokens. Compact or start new; the limit was not raised.')
                    headers = {key: value for key, value in self.headers.items() if key.lower() not in ('host', 'connection', 'content-length', 'accept-encoding')}
                    headers['Content-Length'] = str(len(body))
                    headers['Accept-Encoding'] = 'identity'
                    connection = http.client.HTTPSConnection('api.anthropic.com', timeout=120)
                    try:
                        connection.request('POST', path, body, headers)
                        response = connection.getresponse()
                        self.send_response(response.status)
                        for key, value in response.getheaders():
                            if key.lower() not in ('connection', 'transfer-encoding', 'content-length'):
                                self.send_header(key, value)
                        self.send_header('Connection', 'close')
                        self.end_headers()
                        while True:
                            chunk = response.read1(65536)
                            if not chunk:
                                break
                            self.wfile.write(chunk)
                            self.wfile.flush()
                    finally:
                        connection.close()
                    self.close_connection = True
                except (ValueError, json.JSONDecodeError) as error:
                    gate.refused = str(error)
                    self.reject(str(error))
                except (OSError, http.client.HTTPException):
                    self.close_connection = True

        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f'http://127.0.0.1:{self.server.server_port}/{self.secret}'

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
