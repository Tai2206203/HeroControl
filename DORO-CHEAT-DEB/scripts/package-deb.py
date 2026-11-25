#!/usr/bin/env python3
"""Create a standard Debian ar archive without dpkg, using signed iOS app input."""
import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import plistlib
import re
import shlex
import struct
import tarfile

ROOT = Path(__file__).resolve().parent.parent
SCHEMES = {"rootless": ("iphoneos-arm64", "var/jb/Applications"),
           "rootful": ("iphoneos-arm", "Applications"),
           "roothide": ("iphoneos-arm64e", "Applications")}

def ios_arm64(path, minimum_limit=0x0f0000):
    data = path.read_bytes()
    if len(data) < 32:
        raise ValueError("Missing Mach-O: " + str(path))
    magic, cpu, _, kind, commands, size, _, _ = struct.unpack_from("<8I", data)
    if magic != 0xfeedfacf or cpu != 0x100000c or kind not in (2, 6):
        raise ValueError("Expected arm64 executable/dylib: " + str(path))
    end = 32 + size
    if end > len(data):
        raise ValueError("Truncated Mach-O commands")
    offset = 32
    platforms = []
    for _ in range(commands):
        if offset + 8 > end:
            raise ValueError("Truncated load command")
        command, length = struct.unpack_from("<2I", data, offset)
        if length < 8 or offset + length > end:
            raise ValueError("Invalid load command size")
        if command == 0x32 and length >= 24:
            platforms.append(struct.unpack_from("<I", data, offset + 8)[0])
            if struct.unpack_from("<I", data, offset + 12)[0] > minimum_limit:
                raise ValueError("Binary minimum iOS exceeds package firmware requirement")
        offset += length
    if platforms != [2]:
        raise ValueError("Binary must declare iPhoneOS, not macOS/Simulator: " + str(path))

def scripts(scheme, config):
    app = "/" + SCHEMES[scheme][1] + "/" + config["application"]
    setup = '#!/bin/sh\nset -eu\nPATH="${PATH:-/usr/bin:/bin}:/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin:/usr/sbin:/sbin"\nexport PATH\nAPP=' + shlex.quote(app) + "\n"
    if scheme == "roothide":
        setup += 'command -v jbroot >/dev/null 2>&1 || { echo "RootHide jbroot is required" >&2; exit 1; }\nAPP="$(jbroot "$APP")"\n'
    data = shlex.quote(config["stateHome"])
    post = setup + 'case "${1:-configure}" in configure) ;; *) exit 0 ;; esac\nDATA=' + data + """
[ ! -L "$DATA" ] || exit 1
mkdir -p "$DATA"
for DIR in "$DATA" "$DATA/Documents" "$DATA/Library" "$DATA/Library/Caches" "$DATA/Library/Caches/HeroOverlay"; do
    [ ! -L "$DIR" ] || exit 1
    mkdir -p "$DIR"
    chown 501:501 "$DIR"
    chmod 700 "$DIR"
done
command -v uicache >/dev/null 2>&1 || { echo "uikittools/uicache is required" >&2; exit 1; }
uicache -p "$APP"
exit 0
"""
    pre = setup + """case "${1:-remove}" in remove|upgrade|deconfigure) ;; *) exit 0 ;; esac
if [ -x "$APP/Tools/deb-control" ]; then "$APP/Tools/deb-control" || true; fi
if [ -x "$APP/Tools/hero-kernel-check" ]; then "$APP/Tools/hero-kernel-check" --runtime-remove >/dev/null 2>&1 || true; fi
if command -v uicache >/dev/null 2>&1; then uicache -u "$APP" || true; fi
# Preserve mobile settings/history. Never respring or delete a game container.
exit 0
"""
    return {"postinst": post, "prerm": pre}

def archive(entries):
    output = io.BytesIO()
    with gzip.GzipFile(fileobj=output, mode="wb", mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as tar:
            for name, content, mode, directory in entries:
                if name.startswith("/") or ".." in Path(name).parts:
                    raise ValueError("Unsafe archive path")
                item = tarfile.TarInfo("./" + name)
                item.uid = item.gid = item.mtime = 0
                item.uname = item.gname = "root"
                item.mode = mode
                item.type = tarfile.DIRTYPE if directory else tarfile.REGTYPE
                item.size = 0 if directory else len(content)
                tar.addfile(item, None if directory else io.BytesIO(content))
    return output.getvalue()

def ar_member(name, data):
    header = f"{name+'/':<16}{0:<12}{0:<6}{0:<6}{'100644':<8}{len(data):<10}`\n".encode("ascii")
    if len(header) != 60:
        raise ValueError("Invalid ar header")
    return header + data + (b"\n" if len(data) % 2 else b"")

def build(app, output, scheme):
    config = json.loads((ROOT / "Debian/package.json").read_text("utf8"))
    if scheme not in SCHEMES:
        raise ValueError("Unsupported package scheme")
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != config["bundleID"]:
        raise ValueError("Refusing to package TIPA/foreign application")
    executable = info.get("CFBundleExecutable", "")
    if not executable or Path(executable).name != executable:
        raise ValueError("Invalid bundle executable")
    binaries = {executable, "Tools/hero-kernel-check", "Tools/deb-control", "Tools/HeroOverlay.app/hero-overlay"}
    binaries.update(p.relative_to(app).as_posix() for p in app.rglob("*.dylib"))
    parts = [int(part) for part in config["minimumIOS"].split(".")]
    parts += [0] * (3-len(parts))
    limit = (parts[0]<<16) | (parts[1]<<8) | parts[2]
    for name in binaries:
        ios_arm64(app / name, limit)
    arch, parent = SCHEMES[scheme]
    prefix = parent + "/" + config["application"]
    # Own only the app tree. Do not add/chmod bootstrap roots such as /var/jb.
    data = [(prefix, b"", 0o755, True)]
    for path in sorted(app.rglob("*")):
        if path.is_symlink():
            raise ValueError("Symlinks not allowed in packaged app: " + str(path))
        name = path.relative_to(app).as_posix()
        data.append((prefix + "/" + name, b"" if path.is_dir() else path.read_bytes(),
                     0o755 if path.is_dir() or name in binaries else 0o644, path.is_dir()))
    control = (f"Package: {config['package']}\nName: {config['name']}\nVersion: {config['version']}\n"
               f"Architecture: {arch}\nSection: Utilities\nPriority: optional\nMaintainer: DORO-CHEAT\n"
               f"Depends: firmware (>= {config['minimumIOS']}), uikittools\n"
               "Description: Independent DORO-CHEAT menu app with default-on READ MEMORY.\n")
    if scheme == "roothide":
        control += "Tag: role::enduser, roothide::compatible\nRootHide: true\n"
    controls = [("control", control.encode(), 0o644, False)]
    controls.extend((name, text.encode(), 0o755, False) for name, text in scripts(scheme, config).items())
    package = b"!<arch>\n" + ar_member("debian-binary", b"2.0\n") + ar_member("control.tar.gz", archive(controls)) + ar_member("data.tar.gz", archive(data))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(package)
    output.with_suffix(output.suffix + ".sha256").write_text(hashlib.sha256(package).hexdigest() + "  " + output.name + "\n", encoding="utf8", newline="\n")
    return output

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--scheme", choices=SCHEMES, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    print("Built DEB:", build(args.app, args.output, args.scheme))

if __name__ == "__main__":
    main()
