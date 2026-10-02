#!/usr/bin/env python3
"""Focused contract tests for terminal-m2-investigate.py."""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
import pty
import fcntl
import struct
import signal
import select
from unittest.mock import patch
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parent
RUNNER = ROOT / "terminal-m2-investigate.py"
SPEC = importlib.util.spec_from_file_location("m2probe", RUNNER); M2 = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(M2)


class M2InvestigationTests(unittest.TestCase):
    def call(self, *args: str, input: bytes | None = None) -> subprocess.CompletedProcess[bytes]:
        return subprocess.run([sys.executable, str(RUNNER), *args], input=input, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)

    def test_fixture_is_fixed_utf8_and_rejects_bad_count(self) -> None:
        p = self.call("fixture", "--kind", "chinese", "--lines", "2")
        self.assertEqual(p.returncode, 0)
        self.assertIn("中文", p.stdout.decode())
        self.assertTrue(p.stdout.endswith(b"\r\n"))
        self.assertEqual(p.stdout, self.call("fixture", "--kind", "chinese", "--lines", "2").stdout)
        self.assertNotEqual(self.call("fixture", "--kind", "ascii", "--lines", "-1").returncode, 0)

    def test_identity_invalid_and_missing_pid_are_classified(self) -> None:
        self.assertEqual(json.loads(self.call("identity", "--pid", "0").stdout)["status"], "invalid_pid")
        self.assertEqual(json.loads(self.call("identity", "--pid", "999999").stdout)["status"], "process_exited")

    def test_run_path_removed_and_child_requires_tty(self) -> None:
        self.assertNotEqual(self.call("run", "--output", "/tmp/forbidden").returncode, 0)

    def test_child_timeout_and_secret_safe_error(self) -> None:
        p = self.call("--child", "--output", "/dev/null/forbidden")
        self.assertNotEqual(p.returncode, 0)
        self.assertNotIn(b"PATH=", p.stderr)
        self.assertNotIn(b"HOME=", p.stderr)

    def test_sampler_rejects_zero_negative_interval_and_missing_samples(self) -> None:
        base = {"status":"alive", "executable_path":"/app" ,"uuid":"u","start_abstime":1}
        for duration, interval in ((0,.1),(-1,.1),(1,0),(1,-1)):
            with self.subTest(duration=duration, interval=interval), patch.object(M2,"identity",return_value=base):
                self.assertRaises(ValueError, M2.sample_main, type("A",(),{"duration":duration,"interval":interval,"pid":1,"expected_path":"/app","output":str(Path(tempfile.gettempdir())/"m2-test")})())

    def test_sampler_marks_counter_drop_pid_reuse_and_single_sample(self) -> None:
        base={"status":"alive","executable_path":"/app","uuid":"u","start_abstime":1}
        def invoke(samples):
            class U:
                def __init__(self,pid): self.x=iter(samples)
                def sample(self):
                    try: self.last = next(self.x)
                    except StopIteration: pass
                    return self.last
            a=type("A",(),{"duration":.01,"interval":.01,"pid":1,"expected_path":"/app","output":str(Path(tempfile.mkdtemp())/"s.json")})()
            with patch.object(M2,"identity",return_value=base), patch.object(M2,"ProcUsage",U), patch.object(M2.time,"sleep",return_value=None): return M2.sample_main(a)
        observed=lambda u="u",start=1,user=1,system=1:{"status":"observed","uuid":u,"start_abstime":start,"cpu_user_seconds":user,"cpu_system_seconds":system}
        self.assertNotEqual(invoke([observed(),observed(user=0)]),0)
        self.assertNotEqual(invoke([observed(),observed(u="v")]),0)
        self.assertNotEqual(invoke([{"status":"unavailable"}]),0)

    def test_sampler_requires_expected_path_and_writes_raw_clock(self) -> None:
        self.assertRaises(ValueError, M2.sample_main, type("A",(),{"duration":1,"interval":1,"pid":1,"expected_path":"","output":"/tmp/x"})())

    def test_mach_timebase_conversion(self) -> None:
        self.assertAlmostEqual(M2.ticks_to_seconds(3_000_000_000, 125, 3), 125.0)
        with self.assertRaises(ValueError): M2.ticks_to_seconds(1, 0, 1)

    def test_child_query_size_tracks_pty_winsize_without_output(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            out = Path(td) / "run"; master, slave = pty.openpty()
            proc = subprocess.Popen([sys.executable, str(RUNNER), "--child", "--output", str(out)], stdin=slave, stdout=slave, stderr=subprocess.DEVNULL, close_fds=True)
            os.close(slave)
            try:
                fcntl.ioctl(master, __import__("termios").TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
                deadline = time.monotonic() + 3
                while not (out / "ready.jsonl").exists() and time.monotonic() < deadline: time.sleep(.01)
                (out / "control.jsonl").write_text('{"id":"size-1","op":"query-size"}\n')
                while not (out / "result.jsonl").exists() and time.monotonic() < deadline: time.sleep(.01)
                first = json.loads((out / "result.jsonl").read_text().splitlines()[0]); self.assertEqual((first["columns"], first["rows"]), (80, 24))
                fcntl.ioctl(master, __import__("termios").TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
                with (out / "control.jsonl").open("a") as f: f.write('{"id":"size-2","op":"query-size"}\n')
                while len((out / "result.jsonl").read_text().splitlines()) < 2 and time.monotonic() < deadline: time.sleep(.01)
                second = json.loads((out / "result.jsonl").read_text().splitlines()[1]); self.assertEqual((second["columns"], second["rows"]), (120, 40)); self.assertFalse(select.select([master], [], [], 0)[0])
            finally:
                try:
                    with (out / "control.jsonl").open("a") as control: control.write('{"id":"quit","op":"quit"}\n')
                except OSError: pass
                proc.terminate(); proc.wait(timeout=2); os.close(master)


if __name__ == "__main__":
    unittest.main(verbosity=2)
