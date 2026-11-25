#!/usr/bin/env python3
"""Export only this independent source tree, with no parent-repository inputs."""
from pathlib import Path
import hashlib
import json
import zipfile

ROOT = Path(__file__).resolve().parent.parent

def build(output=None):
    output = output or ROOT / "dist/DORO-CHEAT-DEB-source.zip"
    files = json.loads((ROOT / "source-manifest.json").read_text("utf8"))
    names = [entry["path"] for entry in files] + ["source-manifest.json"]
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        for name in sorted(names):
            path = ROOT / name
            if not path.resolve().is_relative_to(ROOT) or path.is_symlink():
                raise ValueError("Source input outside independent tree")
            item = zipfile.ZipInfo("DORO-CHEAT-DEB/" + name, (2026,1,1,0,0,0))
            item.compress_type = zipfile.ZIP_DEFLATED
            item.external_attr = 0o100644 << 16
            archive.writestr(item, path.read_bytes())
    output.with_suffix(".zip.sha256").write_text(hashlib.sha256(output.read_bytes()).hexdigest()+"  "+output.name+"\n",encoding="utf8",newline="\n")
    return output

if __name__ == "__main__":
    print("Independent source archive:", build())
