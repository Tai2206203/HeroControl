#!/usr/bin/env python3
"""Pin adapter and helper to the same packaged source generation."""
import hashlib
from pathlib import Path

root = Path(__file__).resolve().parent.parent
print(hashlib.sha256((root / 'source-manifest.json').read_bytes()).hexdigest())
