"""Provision once under a process lock, then replace ourselves with the bridge."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import venv


def provision(data: Path, update: bool = False) -> Path:
    if sys.version_info < (3, 10):
        raise RuntimeError("nvim-claude needs Python 3.10 or later")
    data.mkdir(parents=True, exist_ok=True, mode=0o700)
    runtime = data / "venv"
    python = runtime / "bin" / "python"
    with (data / "install.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        ready = runtime / "nvim-claude-ready.json"
        if ready.exists() and python.exists() and not update:
            return python
        ready.unlink(missing_ok=True)
        # Build at its final location: virtualenv entry-point shebangs are absolute.
        # The lock and ready marker prevent clients from observing a partial install.
        print("nvim-claude: preparing private SDK environment", file=sys.stderr, flush=True)
        if not python.exists():
            venv.create(runtime, with_pip=True)
        print("nvim-claude: installing latest released claude-agent-sdk", file=sys.stderr, flush=True)
        subprocess.run([str(python), "-m", "pip", "install", "--disable-pip-version-check",
                        "--no-cache-dir", "--upgrade", "claude-agent-sdk"],
                       stdout=sys.stderr, stderr=sys.stderr, check=True)
        subprocess.run([str(python), "-c", "import claude_agent_sdk"], check=True,
                       stdout=sys.stderr, stderr=sys.stderr)
        ready.write_text(json.dumps({"python": str(python)}))
    return python


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", required=True, type=Path)
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument("--update", action="store_true")
    args = parser.parse_args()
    try:
        python = provision(args.data, args.update)
        bridge = Path(__file__).with_name("bridge.py")
        os.execv(str(python), [str(python), "-u", str(bridge), "--state", str(args.state)])
    except Exception as error:
        print(f"nvim-claude setup failed: {error}. Check Python venv/pip and network access; "
              "then retry or run :NvClaude setup update.", file=sys.stderr, flush=True)
        sys.exit(1)


if __name__ == "__main__":
    main()
