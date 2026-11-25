import importlib.util
import io
from pathlib import Path
import plistlib
import struct
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("deb_package", ROOT / "scripts/package-deb.py")
package = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(package)

def macho(platform=2):
    return struct.pack("<8I", 0xfeedfacf, 0x100000c, 0, 2, 1, 24, 0, 0) + struct.pack("<6I", 0x32, 24, platform, 0x0f0000, 0x110000, 0)

def fixture(root):
    app = root / "app"
    app.mkdir()
    (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier":"local.dorocheat.deb.app","CFBundleExecutable":"HeroControl"}))
    for name in ["HeroControl","Tools/hero-kernel-check","Tools/deb-control","Tools/HeroOverlay.app/hero-overlay","Frameworks/HeroBackend.dylib"]:
        file = app / name
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_bytes(macho())
    return app

def members(data):
    assert data[:8] == b"!<arch>\n"
    result = {}
    offset = 8
    while offset < len(data):
        header = data[offset:offset+60]
        assert header[-2:] == b"`\n"
        name = header[:16].decode().strip().rstrip("/")
        size = int(header[48:58])
        result[name] = data[offset+60:offset+60+size]
        offset += 60 + size + size % 2
    return result

class DebPackageTests(unittest.TestCase):
    def test_all_scheme_archives_and_scripts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = fixture(root)
            for scheme, (arch, prefix) in package.SCHEMES.items():
                with self.subTest(scheme=scheme):
                    output = root / (scheme + ".deb")
                    package.build(app, output, scheme)
                    parts = members(output.read_bytes())
                    self.assertEqual(parts["debian-binary"], b"2.0\n")
                    with tarfile.open(fileobj=io.BytesIO(parts["control.tar.gz"])) as tar:
                        control = tar.extractfile("./control").read().decode()
                        self.assertIn("Architecture: " + arch, control)
                        self.assertEqual(tar.getmember("./postinst").mode, 0o755)
                        pre = tar.extractfile("./prerm").read().decode()
                        self.assertIn("--runtime-remove", pre)
                        self.assertNotIn("killall", pre)
                        self.assertNotIn("rm -rf", pre)
                        if scheme == "roothide":
                            self.assertIn("jbroot", pre)
                    with tarfile.open(fileobj=io.BytesIO(parts["data.tar.gz"])) as tar:
                        entry = tar.getmember("./"+prefix+"/DORO-CHEAT-DEB.app/Tools/hero-kernel-check")
                        self.assertEqual((entry.uid,entry.gid,entry.mode), (0,0,0o755))
                        self.assertTrue(all(not p.name.startswith("/") and ".." not in Path(p.name).parts for p in tar))
                    self.assertTrue(output.with_suffix(".deb.sha256").is_file())

    def test_rejects_foreign_tipa_app(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = fixture(root)
            (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier":"local.herocontrol.app","CFBundleExecutable":"HeroControl"}))
            with self.assertRaisesRegex(ValueError, "foreign"):
                package.build(app,root/"bad.deb","rootless")

    def test_rejects_higher_deployment_target_than_control(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/"too-new"
            data = bytearray(macho())
            struct.pack_into("<I",data,44,0x110000)
            path.write_bytes(data)
            with self.assertRaisesRegex(ValueError,"minimum iOS"):
                package.ios_arm64(path)

    def test_rejects_macos_even_when_cpu_is_arm64(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/"wrong"
            path.write_bytes(macho(platform=1))
            with self.assertRaisesRegex(ValueError,"iPhoneOS"):
                package.ios_arm64(path)

if __name__ == "__main__":
    unittest.main()
