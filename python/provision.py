"""Create a private SDK environment, serialized across editor instances."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import venv


def main():
    root = Path(sys.argv[1]).resolve()
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (root / 'install.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        env = root / 'venv'
        python = env / 'bin' / 'python'
        marker = root / 'ready.json'
        if '--update' in sys.argv or not (marker.exists() and python.exists()):
            marker.unlink(missing_ok=True)
            print('Creating plugin Python environment', flush=True)
            venv.EnvBuilder(with_pip=True).create(env)
            print('Installing latest claude-agent-sdk', flush=True)
            subprocess.run([str(python), '-m', 'pip', 'install', '--upgrade', '--no-cache-dir', '--disable-pip-version-check', 'claude-agent-sdk'], check=True)
            subprocess.run([str(python), '-c', 'from claude_agent_sdk import ClaudeSDKClient, delete_session'], check=True)
            marker.write_text(json.dumps({'python': str(python)}))
        print('Ready: ' + str(python), flush=True)


if __name__ == '__main__':
    main()
