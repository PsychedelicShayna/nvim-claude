"""Provision an isolated SDK generation; never install into system Python."""
import argparse
import fcntl
import importlib.metadata
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import uuid


def provision(root: Path, update: bool = False) -> dict:
    if sys.version_info < (3, 10):
        raise RuntimeError('Python 3.10 or newer is required')
    root.mkdir(parents=True, exist_ok=True)
    with (root / 'install.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        current = root / 'runtime.json'
        if current.exists() and not update:
            result = json.loads(current.read_text())
            if Path(result['python']).exists() and Path(result['cli']).exists():
                return result
        generation = root / ('sdk-' + uuid.uuid4().hex)
        try:
            print('Creating Python environment...', file=sys.stderr, flush=True)
            subprocess.run([sys.executable, '-m', 'venv', str(generation)], check=True, stdout=sys.stderr)
            python = generation / 'bin' / 'python'
            print('Installing latest claude-agent-sdk...', file=sys.stderr, flush=True)
            subprocess.run([str(python), '-m', 'pip', 'install', '--disable-pip-version-check', '--upgrade', 'claude-agent-sdk'], check=True, stdout=sys.stderr)
            code = "import json,sys,importlib.metadata,claude_agent_sdk,pathlib,subprocess; c=pathlib.Path(claude_agent_sdk.__file__).parent/'_bundled'/'claude'; print(json.dumps({'python':sys.executable,'cli':str(c),'versions':{'python':sys.version.split()[0],'sdk':importlib.metadata.version('claude-agent-sdk'),'cli':subprocess.check_output([str(c),'--version'],text=True).strip()}}))"
            result = json.loads(subprocess.check_output([str(python), '-c', code], text=True))
            temporary = current.with_suffix('.new')
            temporary.write_text(json.dumps(result))
            temporary.replace(current)
            # Prior generations may be in use by another editor. They are not
            # removed during update; the README documents explicit cleanup.
            return result
        except BaseException:
            shutil.rmtree(generation, ignore_errors=True)
            raise


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--update', action='store_true')
    args = parser.parse_args()
    try:
        print(json.dumps(provision(args.root, args.update)), flush=True)
    except Exception as error:
        print(f'Provisioning failed: {error}. Check Python venv/pip support and network access; retry :NvClaude update.', file=sys.stderr)
        sys.exit(1)
