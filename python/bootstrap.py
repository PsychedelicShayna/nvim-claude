"""Run outside Neovim's event loop. Install only into a plugin-owned venv."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import venv


def event(message):
    body = json.dumps({'jsonrpc': '2.0', 'method': 'setup', 'params': {'message': message}}).encode()
    sys.stdout.buffer.write(f'Content-Length: {len(body)}\r\n\r\n'.encode() + body)
    sys.stdout.buffer.flush()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--data', required=True)
    parser.add_argument('--state', required=True)
    parser.add_argument('--update', action='store_true')
    args = parser.parse_args()
    data = Path(args.data)
    data.mkdir(parents=True, exist_ok=True, mode=0o700)
    python = data / 'venv' / 'bin' / 'python'
    marker = data / 'ready.json'
    with (data / 'install.lock').open('a') as lock:
        event('Waiting for runtime installation lock')
        fcntl.flock(lock, fcntl.LOCK_EX)
        if args.update or not python.exists() or not marker.exists():
            marker.unlink(missing_ok=True)
            event('Creating private Python environment')
            venv.EnvBuilder(with_pip=True).create(data / 'venv')
            event('Installing latest released claude-agent-sdk')
            subprocess.run([str(python), '-m', 'pip', 'install', '--upgrade', '--no-cache-dir',
                            '--disable-pip-version-check', 'claude-agent-sdk'],
                           stdout=sys.stderr, stderr=sys.stderr, check=True)
            subprocess.run([str(python), '-c', 'import claude_agent_sdk'],
                           stdout=sys.stderr, stderr=sys.stderr, check=True)
            marker.write_text(json.dumps({'python': str(python)}))
    event('Starting SDK bridge')
    os.execv(str(python), [str(python), str(Path(__file__).with_name('bridge.py')),
                          '--state', args.state])


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        event(f'Setup failed: {error}. Check :messages and system Python venv/pip support.')
        raise SystemExit(1)
