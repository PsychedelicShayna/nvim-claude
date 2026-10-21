"""Install the SDK once per data directory, with an inter-process file lock."""
import fcntl
from pathlib import Path
import subprocess
import sys

if sys.version_info < (3, 10):
    raise SystemExit('Python 3.10 or newer is required')

data = Path(sys.argv[1])
data.mkdir(parents=True, exist_ok=True)
with (data / 'install.lock').open('w') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    env = data / 'venv'
    python = env / 'bin' / 'python'
    ready = env / '.nvim-claude-ready'
    if ready.is_file():
        raise SystemExit(0)
    subprocess.run([sys.executable, '-m', 'venv', str(env)], check=True)
    subprocess.run([str(python), '-m', 'pip', 'install', 'claude-agent-sdk'], check=True)
    ready.write_text('installed\n')
