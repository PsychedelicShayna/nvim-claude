"""Provision a private SDK environment, then replace this process with the bridge."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import venv


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--data', required=True)
    parser.add_argument('--state', required=True)
    parser.add_argument('--update', action='store_true')
    parser.add_argument('--login', action='store_true')
    parser.add_argument('--config', default='{}')
    args = parser.parse_args()
    if sys.version_info < (3, 10):
        raise RuntimeError('nvim-claude requires Python 3.10 or newer')
    root = Path(args.data)
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    env = root / 'venv'
    python = env / 'bin/python'
    with (root / 'install.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        ready = env / '.ready'
        if not ready.exists() or args.update:
            print('nvim-claude: provisioning Python environment', file=sys.stderr, flush=True)
            ready.unlink(missing_ok=True)
            venv.EnvBuilder(with_pip=True).create(env)
            subprocess.run([str(python), '-m', 'pip', 'install', '--upgrade', '--no-cache-dir', 'claude-agent-sdk'], check=True, stdout=sys.stderr)
            subprocess.run([str(python), '-c', 'import claude_agent_sdk'], check=True)
            ready.write_text('ready\n')
    if args.update:
        return
    script = Path(__file__).with_name('bridge.py')
    argv = [str(python), str(script), '--state', args.state, '--config', args.config]
    if args.login:
        argv.append('--login')
    os.execv(str(python), argv)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'nvim-claude setup failed: {error}. Check Python venv/pip support and network access; run :NvClaude update to retry.', file=sys.stderr)
        sys.exit(1)
