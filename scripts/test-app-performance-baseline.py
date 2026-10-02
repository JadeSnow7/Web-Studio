#!/usr/bin/env python3
"""Contract tests for app-performance-baseline.py; no app is launched."""
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("baseline", ROOT / "app-performance-baseline.py")
mod = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(mod)
APP_PATH = os.path.realpath("/tmp/app")
IDENTITY = {"status":"validated", "expected_executable":APP_PATH, "uuid":"u", "start_abstime":1, "executable_path":APP_PATH, "binary_sha256":"a"}

def row(cpu, rss=10, uuid="u", start=1):
    return {"status":"observed", "uuid":uuid, "start_abstime":start, "cpu_user_seconds":cpu/2, "cpu_system_seconds":cpu/2, "resident_bytes":rss}

def patches(samples, end_identity=None, clock=(0,0,1,2,2)):
    return [
        mock.patch.object(mod, "validate_identity", return_value=IDENTITY),
        mock.patch.object(mod.m2, "ProcUsage", **{"return_value.sample.side_effect":samples}),
        mock.patch.object(mod.m2, "identity", return_value=end_identity or {"status":"alive", "uuid":"u", "start_abstime":1, "executable_path":APP_PATH}),
        mock.patch.object(mod, "binary_sha256", return_value="a"),
        mock.patch.object(mod, "monotonic", side_effect=clock),
        mock.patch.object(mod.time, "sleep"),
    ]

class BaselineTests(unittest.TestCase):
    def enter(self, ps):
        for p in ps: p.start()
        self.addCleanup(lambda: [p.stop() for p in ps])

    def test_valid_two_endpoint_path_reports_cpu_delta_and_rss(self):
        with tempfile.TemporaryDirectory() as td:
            self.enter(patches([row(1,10), row(3,12)]))
            result = mod.collect(7, "/tmp/app", Path(td)/"out.json", 1, 1, {})
        self.assertEqual(result["sampling_status"], "valid")
        self.assertEqual(result["cumulative_cpu_seconds_delta"], 2.0)
        self.assertEqual(result["rss_bytes_discrete_min"], 10)
        self.assertEqual(result["rss_bytes_discrete_max"], 12)

    def test_failed_sample_and_unverified_context_fail_closed(self):
        with tempfile.TemporaryDirectory() as td:
            self.enter(patches([row(1), {"status":"unavailable", "error_type":"process_exited"}, row(3)]))
            result = mod.collect(7, "/tmp/app", Path(td)/"out.json", 2, 1, {"backend":"VT", "scenario":"idle", "resource_count":1, "visibility":"visible"})
        self.assertEqual(result["failure"], "failed_sample")
        self.assertEqual(result["sample_count_failed"], 1)
        self.assertIsNone(result["cumulative_cpu_seconds_delta"])
        self.assertFalse(result["context"]["backend"]["verified"])

    def test_counter_regression_and_pid_reuse_are_independent_failures(self):
        with tempfile.TemporaryDirectory() as td:
            self.enter(patches([row(3), row(2)], clock=(0,0,1,1,1)))
            result = mod.collect(7, "/tmp/app", Path(td)/"out.json", 1, 1, {})
        self.assertEqual(result["failure"], "cpu_counter_regression")
        changed = {"status":"alive", "uuid":"different", "start_abstime":2, "executable_path":APP_PATH}
        with tempfile.TemporaryDirectory() as td:
            self.enter(patches([row(1), row(3)], end_identity=changed))
            result = mod.collect(7, "/tmp/app", Path(td)/"out.json", 1, 1, {})
        self.assertEqual(result["failure"], "pid_reuse_or_identity_changed")

    def test_sample_identity_and_invalid_counters_fail(self):
        with tempfile.TemporaryDirectory() as td:
            self.enter(patches([row(1), row(2, uuid="changed")]))
            result = mod.collect(7, "/tmp/app", Path(td)/"out.json", 1, 1, {})
        self.assertEqual(result["failure"], "sample_identity_changed")
        with tempfile.TemporaryDirectory() as td:
            self.enter(patches([row(1), {"status":"observed", "cpu_user_seconds":1, "cpu_system_seconds":1, "resident_bytes":1}]))
            result = mod.collect(7, "/tmp/app", Path(td)/"out.json", 1, 1, {})
        self.assertEqual(result["failure"], "sample_identity_changed")
        bad_nan = mock.Mock(sample=lambda: {"status":"observed", "cpu_user_seconds":float("nan"), "cpu_system_seconds":0, "resident_bytes":1})
        bad_negative = mock.Mock(sample=lambda: {"status":"observed", "cpu_user_seconds":0, "cpu_system_seconds":-1, "resident_bytes":1})
        bad_bool = mock.Mock(sample=lambda: {"status":"observed", "cpu_user_seconds":True, "cpu_system_seconds":0, "resident_bytes":1})
        bad_sum = mock.Mock(sample=lambda: {"status":"observed", "cpu_user_seconds":float("1e308"), "cpu_system_seconds":float("1e308"), "resident_bytes":1})
        self.assertEqual(mod.sample_once(bad_nan, 0)["error"], "invalid_cpu_user_seconds")
        self.assertEqual(mod.sample_once(bad_negative, 0)["error"], "invalid_cpu_system_seconds")
        self.assertEqual(mod.sample_once(bad_bool, 0)["error"], "invalid_cpu_user_seconds")
        self.assertEqual(mod.sample_once(bad_sum, 0)["error"], "invalid_cumulative_cpu_seconds")

    def test_identity_requires_uuid_start_and_wrong_path(self):
        for identity, message in [({"status":"alive", "executable_path":APP_PATH, "uuid":"", "start_abstime":1}, "UUID"), ({"status":"alive", "executable_path":APP_PATH, "uuid":"u", "start_abstime":0}, "start"), ({"status":"alive", "executable_path":"/tmp/other", "uuid":"u", "start_abstime":1}, "match")]:
            with mock.patch.object(mod.m2, "identity", return_value=identity), self.assertRaisesRegex(ValueError, message):
                mod.validate_identity(7, "/tmp/app")

    def test_end_identity_missing_and_binary_hash_change_fail(self):
        with tempfile.TemporaryDirectory() as td:
            self.enter(patches([row(1), row(2)], end_identity={"status":"process_exited"}))
            result = mod.collect(7, "/tmp/app", Path(td)/"out.json", 1, 1, {})
        self.assertEqual(result["failure"], "pid_reuse_or_identity_changed")
        with tempfile.TemporaryDirectory() as td:
            ps = patches([row(1), row(2)]); ps[3] = mock.patch.object(mod, "binary_sha256", return_value="changed"); self.enter(ps)
            result = mod.collect(7, "/tmp/app", Path(td)/"out.json", 1, 1, {})
        self.assertEqual(result["failure"], "pid_reuse_or_identity_changed")

    def test_refuses_overwrite_and_bounds_duration(self):
        with tempfile.TemporaryDirectory() as td:
            out = Path(td)/"out"; out.write_text("keep")
            with self.assertRaises(FileExistsError): mod.collect(os.getpid(), "/tmp/app", out, 1, 1, {})
            process = subprocess.run([sys.executable, str(ROOT/"app-performance-baseline.py"), "--pid", "-1", "--expected-executable", "/tmp/app", "--duration", "21", "--output", str(Path(td)/"new")], capture_output=True, text=True)
            self.assertEqual(process.returncode, 2)

if __name__ == "__main__": unittest.main(verbosity=2)
