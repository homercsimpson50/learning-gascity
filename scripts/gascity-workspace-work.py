#!/usr/bin/env python3
"""
gascity-workspace-work.py — switch to DOCKER gas city and open its workspace
(Python API variant; mirrors gascity-workspace-work.sh).
"""

import os
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))


def main() -> int:
    print("\033[1m→ Switching to DOCKER Gas City (work mode)\033[0m")
    subprocess.check_call([os.path.join(SCRIPT_DIR, "gascity-docker-start.sh")])
    print("\n\033[1m→ Opening docker workspace\033[0m")
    os.execv(
        os.path.join(SCRIPT_DIR, "gascity-docker-workspace.py"),
        [os.path.join(SCRIPT_DIR, "gascity-docker-workspace.py"), *sys.argv[1:]],
    )


if __name__ == "__main__":
    sys.exit(main())
