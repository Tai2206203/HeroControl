#!/usr/bin/env python3
"""Run real native lock transfer with open and closed standard descriptors."""
import os
import subprocess
import sys


def close_stdio():
    for descriptor in (0, 1, 2):
        try:
            os.close(descriptor)
        except OSError:
            pass


subprocess.run([sys.argv[1]], check=True, timeout=10)
subprocess.run([sys.argv[1]], check=True, timeout=10, preexec_fn=close_stdio)
print('Overlay lock: exclusive lock survives spawn/exec, releases on exit; closed stdio and symlink rejection passed.')
