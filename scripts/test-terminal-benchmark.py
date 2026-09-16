#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import io
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("terminal_benchmark", Path(__file__).with_name("terminal-benchmark.py"))
assert SPEC and SPEC.loader
benchmark = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(benchmark)


class TerminalBenchmarkTests(unittest.TestCase):
    def test_cpu_time_formats(self) -> None:
        self.assertEqual(benchmark.parse_cpu_time("00:01.50"), 1.5)
        self.assertEqual(benchmark.parse_cpu_time("01:02:03.25"), 3723.25)
        with self.assertRaises(ValueError):
            benchmark.parse_cpu_time("bad")

    def test_deterministic_load_and_counts(self) -> None:
        first, second = io.BytesIO(), io.BytesIO()
        benchmark.write_load("unicode", 3, first)
        benchmark.write_load("unicode", 3, second)
        first.seek(0)
        second.seek(0)
        self.assertEqual(first.read(), second.read())
        self.assertIn(b"BEGIN TERMINAL-BENCHMARK", first.getvalue())
        self.assertIn(b"\x1b[", first.getvalue())
        self.assertNotIn(b"\\x1b", first.getvalue())
        self.assertIn(b"lines=3", first.getvalue())
        done = first.getvalue().split(b"DONE ", 1)[1]
        fields = dict(item.split(b"=", 1) for item in done.split() if b"=" in item)
        self.assertEqual(len(first.getvalue()), int(fields[b"total_bytes"]))
        prefix = first.getvalue().split(b"DONE ", 1)[0]
        self.assertEqual(int(fields[b"payload_bytes"]), len(prefix) - len(prefix.splitlines(keepends=True)[0]))

    def test_missing_process_is_recorded_and_returns_failure(self) -> None:
        completed = subprocess.CompletedProcess(["ps"], 1, "", "no process")
        with tempfile.TemporaryDirectory() as temporary, patch.object(benchmark.subprocess, "run", return_value=completed):
            output = Path(temporary) / "sample.json"
            result = benchmark.sample_process(99999, 0.001, 0.001, output)
            self.assertEqual(result, 1)
            data = json.loads(output.read_text(encoding="utf-8"))
            self.assertTrue(data["summary"]["process_disappeared"])
            self.assertEqual(data["summary"]["process_state"], "process_exited")
            self.assertEqual(data["summary"]["cpu_sampling_status"], "insufficient")
            self.assertEqual(data["samples"][0]["returncode"], 1)

    def test_ps_permission_exception_is_recorded(self) -> None:
        with tempfile.TemporaryDirectory() as temporary, patch.object(benchmark.subprocess, "run", side_effect=PermissionError("Operation not permitted")):
            output = Path(temporary) / "sample.json"
            result = benchmark.sample_process(12345, 0.001, 0.001, output)
            data = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(result, 1)
            self.assertEqual(data["samples"][0]["observation_status"], "permission_error")
            self.assertEqual(data["samples"][0]["error_type"], "PermissionError")
            self.assertEqual(data["summary"]["process_state"], "permission_error")

    def test_permission_and_format_errors_are_not_reported_as_exit(self) -> None:
        samples = [
            {"observation_status": "permission_error"},
            {"observation_status": "format_error"},
        ]
        summary = benchmark.summarize_samples(samples)
        self.assertEqual(summary["process_state"], "permission_error")
        self.assertFalse(summary["process_disappeared"])

    def test_counter_decrease_is_invalid_and_one_point_is_insufficient(self) -> None:
        decreasing = [
            {"observation_status": "observed", "pid": 7, "cumulative_cpu_seconds": 2.0, "rss_kb": 10, "monotonic_started": 1.0, "monotonic_ended": 1.1},
            {"observation_status": "observed", "pid": 7, "cumulative_cpu_seconds": 1.0, "rss_kb": 12, "monotonic_started": 2.0, "monotonic_ended": 2.1},
        ]
        summary = benchmark.summarize_samples(decreasing, expected_pid=7)
        self.assertEqual(summary["cpu_sampling_status"], "invalid_counter_decrease")
        self.assertIsNone(summary["interval_cpu_percent_estimate"])
        one = benchmark.summarize_samples([decreasing[0]], expected_pid=7)
        self.assertEqual(one["cpu_sampling_status"], "insufficient")
        self.assertIsNone(one["cpu_time_delta_seconds"])

        rollback = [
            {"observation_status": "observed", "pid": 7, "cumulative_cpu_seconds": 4.0, "rss_kb": 10, "monotonic_started": 1.0, "monotonic_ended": 1.1},
            {"observation_status": "observed", "pid": 7, "cumulative_cpu_seconds": 0.1, "rss_kb": 11, "monotonic_started": 2.0, "monotonic_ended": 2.1},
            {"observation_status": "observed", "pid": 7, "cumulative_cpu_seconds": 5.0, "rss_kb": 12, "monotonic_started": 3.0, "monotonic_ended": 3.1},
        ]
        self.assertEqual(benchmark.summarize_samples(rollback, expected_pid=7)["cpu_sampling_status"], "invalid_counter_decrease")

    def test_only_observed_matching_pid_counts_as_valid(self) -> None:
        sample = {"observation_status": "format_error", "pid": 7, "cumulative_cpu_seconds": 1.0, "rss_kb": 10}
        self.assertEqual(benchmark.summarize_samples([sample], expected_pid=7)["valid_sample_count"], 0)
        sample["observation_status"] = "observed"
        self.assertEqual(benchmark.summarize_samples([sample], expected_pid=8)["valid_sample_count"], 0)

    def test_cpu_share_uses_recorded_monotonic_bounds(self) -> None:
        samples = [
            {"observation_status": "observed", "pid": 7, "cumulative_cpu_seconds": 1.0, "rss_kb": 10, "monotonic_started": 10.0, "monotonic_ended": 10.2},
            {"observation_status": "observed", "pid": 7, "cumulative_cpu_seconds": 2.0, "rss_kb": 12, "monotonic_started": 11.0, "monotonic_ended": 11.4},
        ]
        summary = benchmark.summarize_samples(samples, expected_pid=7)
        self.assertAlmostEqual(summary["actual_sample_elapsed_seconds"], 1.4)
        self.assertAlmostEqual(summary["interval_cpu_percent_estimate"], 71.4285714286)

    def test_real_process_sampling_and_no_overwrite(self) -> None:
        process = subprocess.Popen(["/bin/sleep", "0.2"])
        try:
            with tempfile.TemporaryDirectory() as temporary:
                output = Path(temporary) / "sample.json"
                result = benchmark.sample_process(process.pid, 0.01, 0.01, output)
                self.assertEqual(result, 0)
                data = json.loads(output.read_text(encoding="utf-8"))
                self.assertGreaterEqual(data["summary"]["valid_sample_count"], 1)
                with self.assertRaises(FileExistsError):
                    benchmark.sample_process(process.pid, 0.01, 0.01, output)
        finally:
            process.wait(timeout=2)


if __name__ == "__main__":
    unittest.main()
