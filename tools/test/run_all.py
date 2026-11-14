"""Runs every offline test of Mass Tree Exterminator (Lua 5.1 through python lupa) and the translation check.

Each test is its own script; a failing check raises, which makes that script exit non-zero. Used by the CI
(build.yml test-command) and by hand.

Usage: python tools/test/run_all.py
"""
import subprocess
import sys
from pathlib import Path

TEST_DIR = Path(__file__).resolve().parent
MOD_DIR = TEST_DIR.parent.parent

SCRIPTS = sorted(p for p in TEST_DIR.glob("run_*.py") if p.name != "run_all.py") + [MOD_DIR / "tools" / "check_l10n.py"]


def main():
    failed = []
    for script in SCRIPTS:
        result = subprocess.run([sys.executable, str(script)], cwd=MOD_DIR, capture_output=True, text=True)
        status = "ok" if result.returncode == 0 else "FAILED"
        print(f"{status:6} {script.relative_to(MOD_DIR).as_posix()}")
        if result.returncode != 0:
            failed.append(script)
            print(result.stdout[-3000:])
            print(result.stderr[-3000:])
    if failed:
        print(f"{len(failed)} of {len(SCRIPTS)} failed")
        return 1
    print(f"all {len(SCRIPTS)} passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
