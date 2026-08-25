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

    def test_predictable_tmp_symlink_does_not_clobber_victim(self):
        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp) / "history.jsonl"
            victim = Path(tmp) / "victim"
            victim.write_text("keep-me", encoding="utf-8")
            decoy = dest.with_name(dest.name + ".tmp")
            decoy.symlink_to(victim)
            MOD.write_text_atomic(dest, "safe\n", mode=0o600)
            self.assertEqual(victim.read_text(encoding="utf-8"), "keep-me")
            self.assertEqual(dest.read_text(encoding="utf-8"), "safe\n")
            self.assertTrue(decoy.is_symlink())

    def test_refuses_destination_symlink(self):
        with tempfile.TemporaryDirectory() as tmp:
            victim = Path(tmp) / "victim"
            victim.write_text("keep-me", encoding="utf-8")
            dest = Path(tmp) / "config.toml"
            dest.symlink_to(victim)
            with self.assertRaises(OSError):
                MOD.write_text_atomic(dest, "pwned\n")
            self.assertEqual(victim.read_text(encoding="utf-8"), "keep-me")


class LimitTests(unittest.TestCase):
    def test_read_text_limited_caps_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "big"
            path.write_bytes(b"a" * 100)
            data = MOD.read_text_limited(path, 10)
            self.assertEqual(len(data.encode("utf-8")), 10)

    def test_read_text_limited_refuses_symlink(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "target"
            target.write_text("secret", encoding="utf-8")
            link = Path(tmp) / "link"
            link.symlink_to(target)
            with self.assertRaises(OSError):
                MOD.read_text_limited(link, 100)

    def test_run_chain_caps_stdout(self):
        oversize = MOD.MAX_TRANSCRIPT_BYTES + 4096
        command = "python3 -c 'import sys; sys.stdout.write(\"x\" * %d)'" % oversize
        out = MOD.run_chain(command, "hi", 5000)
        self.assertLessEqual(len(out.encode("utf-8")), MOD.MAX_TRANSCRIPT_BYTES)
        self.assertTrue(out.startswith("x"))

    def test_clip_transcript(self):
        clipped = MOD.clip_transcript("é" * 80, max_bytes=20)
        self.assertLessEqual(len(clipped.encode("utf-8")), 20)
        self.assertTrue(len(clipped) > 0)


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
