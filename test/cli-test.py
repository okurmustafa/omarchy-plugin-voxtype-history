#!/usr/bin/env python3
import importlib.machinery
import importlib.util
import os
import stat
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOADER = importlib.machinery.SourceFileLoader("voxtype_history", str(ROOT / "bin" / "voxtype-history"))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
MOD = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(MOD)


class WriteTextAtomicTests(unittest.TestCase):
    def test_applies_mode_despite_umask(self):
        old = os.umask(0o022)
        try:
            with tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / "secret.json"
                MOD.write_text_atomic(path, "hi\n", mode=0o600)
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        finally:
            os.umask(old)


class EnableConfigModeTests(unittest.TestCase):
    def test_preserves_restrictive_config_mode_on_backup_and_rewrite(self):
        old = os.umask(0o022)
        try:
            with tempfile.TemporaryDirectory() as tmp:
                config = Path(tmp) / "config.toml"
                config.write_text('[output]\nmode = "type"\n', encoding="utf-8")
                os.chmod(config, 0o600)
                result = MOD.enable_in_config(config, "/tmp/voxtype-history log", 5000)
                self.assertEqual(stat.S_IMODE(config.stat().st_mode), 0o600)
                backup = Path(result["backup"])
                self.assertTrue(backup.exists())
                self.assertEqual(stat.S_IMODE(backup.stat().st_mode), 0o600)
                self.assertIn("voxtype-history", config.read_text(encoding="utf-8"))
        finally:
            os.umask(old)

    def test_disable_preserves_existing_mode(self):
        old = os.umask(0o022)
        try:
            with tempfile.TemporaryDirectory() as tmp:
                config = Path(tmp) / "config.toml"
                config.write_text('[output]\nmode = "type"\n', encoding="utf-8")
                os.chmod(config, 0o640)
                MOD.enable_in_config(config, "/tmp/voxtype-history log", 5000)
                MOD.disable_in_config(config, None, None)
                self.assertEqual(stat.S_IMODE(config.stat().st_mode), 0o640)
                self.assertNotIn("voxtype-history", config.read_text(encoding="utf-8"))
        finally:
            os.umask(old)


if __name__ == "__main__":
    unittest.main()
