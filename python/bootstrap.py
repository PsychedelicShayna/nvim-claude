"""Run with system Python; serialize provisioning without blocking Neovim."""
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
    args = parser.parse_args()
    data = Path(args.data)
    data.mkdir(parents=True, exist_ok=True)
    environment = data / 'venv'
    python = environment / 'bin' / 'python'
    with (data / 'install.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        ready = environment / 'nvim-claude-ready.json'
        if args.update or not ready.exists():
            print('nvim-claude: preparing Python environment', file=sys.stderr, flush=True)
            ready.unlink(missing_ok=True)
            venv.EnvBuilder(with_pip=True).create(environment)
            subprocess.run([str(python), '-m', 'pip', 'install', '--upgrade', '--disable-pip-version-check', 'claude-agent-sdk'], stdout=sys.stderr, check=True)
            version = subprocess.check_output([str(python), '-c', 'import claude_agent_sdk; print(claude_agent_sdk.__version__)'], text=True).strip()
            ready.write_text(json.dumps({'sdk': version}))
        fcntl.flock(lock, fcntl.LOCK_UN)
    if args.update:
        print('nvim-claude: update complete', file=sys.stderr)
        return
    script = Path(__file__).with_name('bridge.py')
    command = [str(python), str(script), '--state', args.state]
    if args.login:
        command.append('--login')
    os.execv(str(python), command)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(f'nvim-claude setup failed: {error}. Check Python 3.10+, venv/ensurepip and network access; retry :NvClaude update.', file=sys.stderr)
        sys.exit(1)
