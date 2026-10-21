#!/usr/bin/env python3
"""Provision once under a cross-process lock, publish only a complete venv."""
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import uuid


def main():
    if sys.version_info < (3, 10):
        raise RuntimeError('nvim-claude requires Python 3.10 or newer')
    root = Path(sys.argv[1])
    root.mkdir(parents=True, exist_ok=True)
    with (root / 'install.lock').open('a') as lock:
        print('Waiting for runtime installation lock', file=sys.stderr, flush=True)
        fcntl.flock(lock, fcntl.LOCK_EX)
        marker = root / 'current.json'
        if marker.exists() and '--update' not in sys.argv:
            runtime = json.loads(marker.read_text())
            if Path(runtime['python']).is_file():
                print(json.dumps(runtime), flush=True)
                return
        environment = root / ('sdk-' + uuid.uuid4().hex)
        try:
            print('Creating private Python environment', file=sys.stderr, flush=True)
            subprocess.run([sys.executable, '-m', 'venv', str(environment)], check=True,
                           stdout=sys.stderr)
            python = environment / 'bin' / 'python'
            print('Installing latest released claude-agent-sdk', file=sys.stderr, flush=True)
            subprocess.run([str(python), '-m', 'pip', 'install', '--disable-pip-version-check',
                            '--no-cache-dir', 'claude-agent-sdk'], check=True, stdout=sys.stderr)
            runtime = {'python': str(python), 'environment': str(environment)}
            temp = root / 'current.json.new'
            temp.write_text(json.dumps(runtime))
            os.replace(temp, marker)
            print(json.dumps(runtime), flush=True)
        except BaseException:
            shutil.rmtree(environment, ignore_errors=True)
            raise


if __name__ == '__main__':
    main()
