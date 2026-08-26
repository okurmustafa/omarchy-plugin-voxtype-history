#!/usr/bin/env python3
import glob
import importlib.machinery
import importlib.util
import os
import stat
import subprocess
import sys
import tempfile
import threading
import time
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

    def _call_with_timeout(self, fn, timeout_s, *args, **kwargs):
        box = {}

        def run():
            try:
                box["result"] = fn(*args, **kwargs)
            except Exception as exc:
                box["error"] = exc

        thread = threading.Thread(target=run, daemon=True)
        thread.start()
        thread.join(timeout_s)
        if thread.is_alive():
            self.fail(f"{fn.__name__} did not finish within {timeout_s}s")
        if "error" in box:
            raise box["error"]
        return box.get("result")

    def test_read_bytes_limited_refuses_fifo_without_blocking(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "fifo"
            os.mkfifo(path)

            def read_fifo():
                return MOD.read_bytes_limited(path, 100)

            with self.assertRaises(OSError):
                self._call_with_timeout(read_fifo, 2)

    def test_read_bytes_limited_refuses_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(OSError):
                self._call_with_timeout(MOD.read_bytes_limited, 2, Path(tmp), 100)

    def test_read_bytes_limited_refuses_character_device(self):
        with self.assertRaises(OSError):
            self._call_with_timeout(MOD.read_bytes_limited, 2, Path("/dev/null"), 100)

    def test_run_chain_passes_stdin(self):
        command = "python3 -c 'import sys; sys.stdout.write(sys.stdin.read().upper())'"
        out = MOD.run_chain(command, "hi", 5000)
        self.assertEqual(out, "HI")

    def test_run_chain_caps_stdout(self):
        oversize = MOD.MAX_TRANSCRIPT_BYTES + 4096
        command = "python3 -c 'import sys; sys.stdout.write(\"x\" * %d)'" % oversize
        out = MOD.run_chain(command, "hi", 5000)
        self.assertLessEqual(len(out.encode("utf-8")), MOD.MAX_TRANSCRIPT_BYTES)
        self.assertTrue(out.startswith("x"))

    def test_run_chain_times_out_when_stdin_not_consumed(self):
        payload = "x" * MOD.MAX_TRANSCRIPT_BYTES
        started = time.monotonic()
        out = self._call_with_timeout(MOD.run_chain, 8, "sleep 30", payload, 250)
        self.assertLess(time.monotonic() - started, 5)
        self.assertEqual(out, payload)

    def test_run_chain_kills_whole_process_group_on_timeout(self):
        marker = f"30.{os.getpid()}{int(time.time()) % 100000}"
        command = f"sleep {marker} & sleep {marker} & wait"
        out = self._call_with_timeout(MOD.run_chain, 8, command, "hi", 250)
        self.assertEqual(out, "hi")
        time.sleep(0.2)
        survivors = []
        for cmdline in glob.glob("/proc/[0-9]*/cmdline"):
            try:
                content = Path(cmdline).read_bytes()
            except OSError:
                continue
            if marker.encode() in content:
                survivors.append(cmdline)
        self.assertEqual(survivors, [], "chained grandchildren survived the kill")

    def test_clip_transcript(self):
        clipped = MOD.clip_transcript("é" * 80, max_bytes=20)
        self.assertLessEqual(len(clipped.encode("utf-8")), 20)
        self.assertTrue(len(clipped) > 0)


class StoreLockTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.env_backup = {
            key: os.environ.get(key)
            for key in ("XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_RUNTIME_DIR")
        }
        os.environ["XDG_DATA_HOME"] = str(base / "data")
        os.environ["XDG_CONFIG_HOME"] = str(base / "config")
        os.environ["XDG_RUNTIME_DIR"] = str(base / "run")
        (base / "run").mkdir()

    def tearDown(self):
        for key, value in self.env_backup.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        self.tmp.cleanup()

    def test_acquires_and_releases(self):
        with MOD.StoreLock():
            pass
        with MOD.StoreLock():
            pass

    def test_refuses_fifo_lock_file(self):
        os.mkfifo(MOD.lock_path())
        started = time.monotonic()
        with self.assertRaises(OSError):
            with MOD.StoreLock():
                pass
        self.assertLess(time.monotonic() - started, 2)

    def test_refuses_symlink_lock_file(self):
        victim = Path(self.tmp.name) / "victim"
        victim.write_text("keep", encoding="utf-8")
        os.symlink(victim, MOD.lock_path())
        with self.assertRaises(OSError):
            with MOD.StoreLock():
                pass

    def test_refuses_symlinked_data_dir(self):
        real = Path(self.tmp.name) / "real-data"
        real.mkdir()
        data_root = Path(os.environ["XDG_DATA_HOME"])
        data_root.mkdir(parents=True, exist_ok=True)
        os.symlink(real, data_root / "voxtype-history")
        with self.assertRaises(OSError):
            with MOD.StoreLock():
                pass

    def test_contended_lock_times_out_bounded(self):
        holder = subprocess.Popen(
            [
                sys.executable,
                "-c",
                "import fcntl, sys, time;"
                f"f = open({str(MOD.lock_path())!r}, 'a+');"
                "fcntl.flock(f.fileno(), fcntl.LOCK_EX);"
                "print('held', flush=True);"
                "time.sleep(30)",
            ],
            stdout=subprocess.PIPE,
            text=True,
        )
        try:
            self.assertEqual(holder.stdout.readline().strip(), "held")
            original = MOD.LOCK_TIMEOUT_S
            MOD.LOCK_TIMEOUT_S = 0.4
            try:
                started = time.monotonic()
                with self.assertRaises(OSError):
                    with MOD.StoreLock():
                        pass
                self.assertLess(time.monotonic() - started, 3)
            finally:
                MOD.LOCK_TIMEOUT_S = original
        finally:
            holder.kill()
            holder.wait()
            holder.stdout.close()


class ChainBudgetTests(unittest.TestCase):
    def test_voxtype_timeout_covers_previous_chain(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "config.toml"
            config.write_text(
                '[output]\nmode = "type"\n\n'
                '[output.post_process]\ncommand = "slow-llm-cleanup"\ntimeout_ms = 30000\n',
                encoding="utf-8",
            )
            result = MOD.enable_in_config(config, "/x/voxtype-history log", MOD.HOOK_TIMEOUT_MS)
            self.assertEqual(result["previousCommand"], "slow-llm-cleanup")
            self.assertEqual(result["previousTimeoutMs"], 30000)
            text = config.read_text(encoding="utf-8")
            self.assertIn(f"timeout_ms = {30000 + MOD.CHAIN_BUDGET_MARGIN_MS}", text)

    def test_default_timeout_without_previous_chain(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "config.toml"
            config.write_text('[output]\nmode = "type"\n', encoding="utf-8")
            MOD.enable_in_config(config, "/x/voxtype-history log", MOD.HOOK_TIMEOUT_MS)
            self.assertIn(f"timeout_ms = {MOD.HOOK_TIMEOUT_MS}", config.read_text(encoding="utf-8"))

    def test_escaped_previous_command_round_trips(self):
        import tomllib
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "config.toml"
            config.write_text(
                '[output.post_process]\ncommand = "say \\"hi\\" now"\ntimeout_ms = 1000\n',
                encoding="utf-8",
            )
            result = MOD.enable_in_config(config, "/x/voxtype-history log", MOD.HOOK_TIMEOUT_MS)
            self.assertEqual(result["previousCommand"], 'say "hi" now')
            MOD.disable_in_config(config, result["previousCommand"], result["previousTimeoutMs"])
            parsed = tomllib.loads(config.read_text(encoding="utf-8"))
            self.assertEqual(parsed["output"]["post_process"]["command"], 'say "hi" now')
            self.assertEqual(parsed["output"]["post_process"]["timeout_ms"], 1000)


class TomlQuoteTests(unittest.TestCase):
    def test_escapes_injection_attempt(self):
        hostile = 'x" \n[malicious]\ny = "'
        quoted = MOD.toml_quote(hostile)
        self.assertNotIn("\n", quoted)
        self.assertEqual(quoted, 'x\\" \\n[malicious]\\ny = \\"')

    def test_disable_restores_hostile_previous_command_safely(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / "config.toml"
            config.write_text('[output]\nmode = "type"\n', encoding="utf-8")
            hostile = 'run" --flag\n[injected]\nowned = "yes'
            MOD.enable_in_config(config, "/tmp/voxtype-history log", 5000)
            MOD.disable_in_config(config, hostile, 1000)
            text = config.read_text(encoding="utf-8")
            # The hostile payload must stay inside the quoted string: no line may
            # become a new section header or key.
            self.assertNotIn("[injected]", [line.strip() for line in text.splitlines()])
            self.assertIn('command = "run\\" --flag\\n[injected]\\nowned = \\"yes"', text)


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
