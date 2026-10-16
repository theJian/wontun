#!/usr/bin/env python3
"""Packaging failure-path checks; no downloads or executable launches."""
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest


class PackagingTests(unittest.TestCase):
    def test_corrupt_cached_archive_is_rejected_before_packaging(self):
        root = Path(__file__).resolve().parents[1]
        arch = {"arm64": "arm64", "x86_64": "amd64"}[platform.machine()]
        with tempfile.TemporaryDirectory(prefix="wontun-package-test-") as directory:
            project = Path(directory)
            scripts = project / "scripts"
            scripts.mkdir()
            shutil.copy2(root / "scripts/bundle-sing-box.sh", scripts)
            cache = project / ".build/downloads"
            cache.mkdir(parents=True)
            (cache / f"sing-box-1.14.3-darwin-{arch}.tar.gz").write_bytes(b"corrupted archive")
            app = project / "Wontun.app"
            result = subprocess.run([str(scripts / "bundle-sing-box.sh"), str(app)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("checksum mismatch", result.stderr)
            self.assertFalse(app.exists())


if __name__ == "__main__":
    unittest.main()
