#!/usr/bin/env python3
"""Contract tests for terminal-m2-profile.py; no real process is attached."""
from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parent
WRAPPER = ROOT / "terminal-m2-profile.py"
_spec = importlib.util.spec_from_file_location("m2_profile", WRAPPER)
_module = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
_spec.loader.exec_module(_module)


class ProfileTests(unittest.TestCase):
    def test_sample_duration_wall_and_size_caps_are_distinct(self):
        self.assertEqual(_module.SAMPLE_DURATION_SECONDS, 5.0)
        self.assertEqual(_module.SAMPLE_WALL_SECONDS, 20.0)
        self.assertEqual(_module.PILOT_BYTES, 256 * 1024 * 1024)
    def test_parse_time_samples_refs_pid_and_counts(self):
        xml = '<trace><name id="n">/private/secret</name><row><sample-time>1.2</sample-time><process>pid=42</process><thread>7</thread><weight>3</weight><backtrace><frame>foo 0x1234 /tmp/x</frame><frame>bar</frame><frame>foo</frame></backtrace></row><row><process>pid=99</process><thread>9</thread><frame>other</frame></row></trace>'
        result = _module.parse_time_samples(xml, 42)
        self.assertEqual(result['sample_count'], 1)
        self.assertEqual(result['self_counts'], {'foo': 1})
        self.assertEqual(result['inclusive_counts'], {'foo': 1, 'bar': 1})
        self.assertNotIn('secret', json.dumps(result))

    def test_parse_real_time_sample_nested_pid_is_fail_closed_without_symbols(self):
        xml = '<trace><row><sample-time fmt="1.0"/><thread fmt="Main Thread (pid: 43330)"><pid fmt="43330"/></thread><kperf-bt fmt="PC:0x1234, 2 frames, pid: 43330"/></row><row><thread fmt="unknown"/></row></trace>'
        result = _module.parse_time_samples(xml, 43330)
        self.assertEqual(result['sample_count'], 1)
        self.assertEqual(result['unknown_pid_rows'], 1)
        self.assertEqual(result['inclusive_counts'], {})

    def test_sample_export_empty_is_unusable(self):
        result = _module.parse_time_samples('<trace/>', 42)
        self.assertEqual(result['sample_count'], 0)
        self.assertEqual(result['unknown_pid_rows'], 0)

    def test_record_fake_size_and_wall_limits_fail_closed(self):
        with tempfile.TemporaryDirectory() as td:
            d = Path(td); fake = d / 'bounded.py'
            fake.write_text(f"#!{sys.executable}\nimport pathlib,sys,time\na=sys.argv[1:]\nif a[0]=='record':\n o=pathlib.Path(a[a.index('--output')+1]); o.mkdir(); (o/'blob').write_bytes(b'x'*64); time.sleep(2)\nelse:\n o=pathlib.Path(a[a.index('--output')+1]); o.write_text('<trace/>')\n")
            fake.chmod(0o700)
            expected = _module.executable_for_pid(os.getpid()); self.assertIsNotNone(expected)
            old_size, old_wall = _module.PILOT_BYTES, _module.WALL_WATCHDOG_SECONDS
            try:
                _module.PILOT_BYTES = 32; out = d / 'size.trace'
                result = _module.record_profile(os.getpid(), expected, out, extended=False, xctrace=str(fake), poll=.01, finish_timeout=.1)
                self.assertEqual(result['status'], 'failed'); self.assertTrue(result['over_size_limit'])
                _module.PILOT_BYTES = 256 * 1024 * 1024; _module.WALL_WATCHDOG_SECONDS = .05; out = d / 'time.trace'
                result = _module.record_profile(os.getpid(), expected, out, extended=False, xctrace=str(fake), poll=.01, finish_timeout=.1)
                self.assertEqual(result['status'], 'failed'); self.assertTrue(result['timed_out'])
                _module.WALL_WATCHDOG_SECONDS = old_wall
                fail = d / 'fail.py'; fail.write_text(f"#!{sys.executable}\nimport sys\nsys.exit(7)\n"); fail.chmod(0o700)
                result = _module.record_profile(os.getpid(), expected, d / 'nonzero.trace', extended=False, xctrace=str(fail), poll=.01, finish_timeout=.1)
                self.assertEqual(result['status'], 'failed'); self.assertEqual(result['returncode'], 7)
            finally:
                _module.PILOT_BYTES, _module.WALL_WATCHDOG_SECONDS = old_size, old_wall

    def test_parse_sample_sanitizes_and_keeps_tree_counts(self):
        fixture = """Call graph:\n  12 + | 0x1234 foo /Users/me/secret.app\n   7 ! bar /private/tmp/key\nSort by top of stack:\n        foo  (in libSystem.dylib)        12\nBinary Images:\n  0x1234 /Users/me/secret.app\nENV_SECRET=never\n"""
        result = _module.parse_sample(fixture)
        self.assertEqual(result["call_graph"], ["  12 + | <address> foo <path>", "   7 ! bar <path>"])
        self.assertEqual(result["top_of_stack"], ["        foo 12"])
        self.assertNotIn("Users", json.dumps(result)); self.assertNotIn("ENV_SECRET", json.dumps(result))

    def test_parse_sample_accepts_interleaved_tree_prefix(self):
        result = _module.parse_sample("Call graph:\n    + ! : 100 TerminalMetalRenderer /tmp/secret\nTotal number in stack:\n")
        self.assertEqual(result["call_graph"], ["    + ! : 100 TerminalMetalRenderer <path>"])
        self.assertEqual(result["numeric_lines"], result["parsed_numeric_lines"])

    def test_parse_sample_rejects_only_malformed_numeric_lines(self):
        clean = _module.parse_sample("Call graph:\n  4 foo\n\nSort by top of stack:\n foo 4\nBinary Images:\n")
        self.assertEqual(clean["rejected_numeric_lines"], 0)
        malformed = _module.parse_sample("Call graph:\n  + 4\nTotal number in stack:\n")
        self.assertEqual(malformed["rejected_numeric_lines"], 1)

    def fake(self, directory: Path) -> Path:
        path = directory / "fake-xctrace.py"
        log = directory / "child-env.json"
        path.write_text(textwrap.dedent(f"""
            #{'!'}{sys.executable}
            import os, pathlib, sys, time
            import json
            pathlib.Path({str(log)!r}).write_text(json.dumps(dict(os.environ)))
            args=sys.argv[1:]
            if args[0] != ('record' if 'record' in args else 'export'):
                raise SystemExit(9)
            if args[0] == 'record':
                out=pathlib.Path(args[args.index('--output')+1]); out.mkdir()
                (out/'payload').write_bytes(b'x'*32); time.sleep(.03)
            else:
                out=pathlib.Path(args[args.index('--output')+1])
                out.write_text('<trace><run schema="safe"><environment>SECRET</environment><arguments>TOPSECRET</arguments><row/></run></trace>')
        """ ).lstrip())
        path.chmod(path.stat().st_mode | stat.S_IXUSR)
        return path

    def test_env_allowlist_and_record_metadata(self):
        with tempfile.TemporaryDirectory() as td:
            d=Path(td); fake=self.fake(d); log=d/'child-env.json'; out=d/'a.trace'
            env=dict(os.environ, FAKE_LOG=str(log), SECRET_FIXTURE='do-not-leak')
            # The target is this test process; expected basename validation is explicit.
            expected = _module.executable_for_pid(os.getpid())
            self.assertIsNotNone(expected)
            p=subprocess.run([sys.executable, str(WRAPPER), 'record', '--pid', str(os.getpid()),
                              '--expected-executable', expected, '--output', str(out), '--xctrace', str(fake)],
                             env=env, capture_output=True, text=True)
            self.assertEqual(p.returncode, 0, p.stderr); self.assertNotIn('do-not-leak', p.stdout+p.stderr)
            child_env = json.loads(log.read_text())
            # macOS may inject its own CF bookkeeping variable; application
            # supplied variables are still strictly limited to the allowlist.
            self.assertTrue(set(child_env) - {'__CF_USER_TEXT_ENCODING'} <= {'HOME','PATH','TMPDIR','LANG'})
            self.assertNotIn('SECRET_FIXTURE', child_env)
            self.assertEqual(json.loads(p.stdout)['status'], 'recorded')

    def test_export_discards_sensitive_xml_content(self):
        with tempfile.TemporaryDirectory() as td:
            d=Path(td); fake=self.fake(d); trace=d/'x.trace'; trace.write_bytes(b'fixture')
            p=subprocess.run([sys.executable, str(WRAPPER), 'export', str(trace), '--xctrace', str(fake)],
                             env=dict(os.environ, SECRET='TOPSECRET'), capture_output=True, text=True)
            self.assertEqual(p.returncode, 0); self.assertNotIn('TOPSECRET', p.stdout); self.assertNotIn('SECRET', p.stdout)
            result=json.loads(p.stdout); self.assertEqual(result['schema_names'], ['safe']); self.assertEqual(result['elements'], 5)

    def test_rejects_mismatched_executable(self):
        with tempfile.TemporaryDirectory() as td:
            p=subprocess.run([sys.executable, str(WRAPPER), 'record', '--pid', str(os.getpid()),
                              '--expected-executable', 'definitely-not-this-process', '--output', str(Path(td)/'x')],
                             capture_output=True, text=True)
            self.assertEqual(p.returncode, 2); self.assertNotIn('definitely', p.stdout)


if __name__ == '__main__':
    unittest.main(verbosity=2)
