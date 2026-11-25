#!/usr/bin/env python3
"""Reproduce UIKit-style missing stdio in an isolated native test process."""
import os
import subprocess
import sys


def close_standard_fds():
    for fd in (0, 1, 2):
        try:
            os.close(fd)
        except OSError:
            pass


if __name__ == "__main__":
    result = subprocess.run([sys.argv[1], "--fd-self-test"], preexec_fn=close_standard_fds, timeout=20)
    if result.returncode:
        raise SystemExit("Closed-stdio helper regression failed, exit=" + str(result.returncode))
    print("Closed-stdio helper capture regression passed (real dup2/close/stdout/stderr).")
