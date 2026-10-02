#!/usr/bin/env python3
import importlib.util, tempfile, unittest, json, subprocess, os
from unittest.mock import patch
from pathlib import Path
from types import SimpleNamespace

HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location("matrix",HERE/"terminal-m2-matrix.py"); matrix=importlib.util.module_from_spec(spec); spec.loader.exec_module(matrix)

class MatrixTests(unittest.TestCase):
    def test_concurrent_result_validation_handles_reset_start_and_bounds(self):
        reset={"status":"complete","dsr_matches":True}
        self.assertIs(matrix.validate_concurrent_result(reset,require_dsr=True),reset)
        start={"status":"complete","received":[{"seq":i} for i in range(20)],"output":[{"seq":i} for i in range(200)],"echoes":[{"seq":i} for i in range(20)],"dsr":{"status":"observed"}}
        self.assertIs(matrix.validate_concurrent_result(start),start)
        for bad in ({**start,"status":"failed_input_sequence"},{**start,"received":start["received"][:-1]},{**start,"output":start["output"][:-1]},{**start,"echoes":start["echoes"][:-1]}):
            with self.assertRaises(RuntimeError): matrix.validate_concurrent_result(bad)
    def test_concurrent_window_rejects_dsr_outside_sample(self):
        row={"started":2,"ended":3,"dsr":{"reply_end":4}}
        matrix.validate_concurrent_window(row,1,5)
        with self.assertRaises(RuntimeError): matrix.validate_concurrent_window(row,1,3.5)
    def test_concurrent_dry_run_uses_two_warmups_final_reset_and_formal_start(self):
        with tempfile.TemporaryDirectory() as d:
            out=Path(d)/"out"; apps=Path(d)/"apps"
            subprocess.run(["python3",str(HERE/"terminal-m2-matrix.py"),"--output",str(out),"--apps-root",str(apps),"--pairs","1","--scenarios","concurrent","--limit-runs","1","--dry-run"],env={**os.environ,"PYTHONDONTWRITEBYTECODE":"1"},check=True)
            ops=[json.loads(x)["op"] for x in next(out.glob("*/child/control.jsonl")).read_text().splitlines()]
            self.assertEqual(ops,["reset","start","reset","start","reset","start","quit"]); self.assertNotIn("load",ops)
            run=next(p for p in out.iterdir() if p.is_dir()); self.assertEqual([json.loads((run/f"ui-phase-{i}-ready.json").read_text())["phase"] for i in (1,2,3)],[1,2,3])
    def test_concurrent_child_route_and_sampler_cap_contract(self):
        source=(HERE/"terminal-m2-matrix.py").read_text(); self.assertIn('child_tool = "terminal-m2-concurrent.py" if scenario == "concurrent"', source)
        investigate=(HERE/"terminal-m2-investigate.py").read_text(); self.assertIn('SAMPLER_MAX_SECONDS = 25.0', investigate)
    def test_pair_range_defaults_and_start_pair_alternation(self):
        source=(HERE/"terminal-m2-matrix.py").read_text()
        self.assertIn('p.add_argument("--start-pair",type=int,default=1)', source)
        self.assertIn('for pair in range(a.start_pair,a.start_pair+a.pairs)', source)
        with tempfile.TemporaryDirectory() as d:
            out=Path(d)/"out"; apps=Path(d)/"apps"
            subprocess.run(["python3",str(HERE/"terminal-m2-matrix.py"),"--output",str(out),"--apps-root",str(apps),"--start-pair","2","--pairs","5","--scenarios","ascii","--limit-runs","2","--dry-run"],env={**os.environ,"PYTHONDONTWRITEBYTECODE":"1"},check=True)
            names=[p.name for p in out.iterdir() if p.is_dir()]
            self.assertTrue(all("-2-" in n for n in names))
        for start,count in ((0,1),(101,1),(99,3)):
            with tempfile.TemporaryDirectory() as d:
                p=subprocess.run(["python3",str(HERE/"terminal-m2-matrix.py"),"--output",str(Path(d)/"o"),"--apps-root",str(Path(d)/"a"),"--start-pair",str(start),"--pairs",str(count),"--dry-run"],capture_output=True)
                self.assertNotEqual(p.returncode,0)
    def test_history_resize_sampler_contract_is_20_seconds(self):
        source = (HERE / "terminal-m2-matrix.py").read_text()
        self.assertIn('"--duration","20"', source)
        self.assertIn('sampler.wait(timeout=25)', source)
        start = source.index('if scenario in ("history-scroll", "resize"):')
        branch = source[start:source.index('        return', start) + len('        return')]
        self.assertLess(branch.index('final_load=command'), branch.index('if not args.dry_run: time.sleep(2)'))
        self.assertLess(branch.index('before_snapshot=background_snapshot'), branch.index('sampler=subprocess.Popen'))
        self.assertLess(branch.index('time.sleep(2)'), branch.index('waiting-scene'))
    def test_ui_actions_contract_rejects_missing_outside_scene_count_and_unverified(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/"ui-actions.json"; base={"status":"observed","scene":"resize","started_monotonic":2.0,"ended_monotonic":3.0,"action_count":2,"verified":True}; p.write_text(json.dumps(base))
            self.assertEqual(matrix.validate_ui_actions(p,1,4,"resize")["action_count"],2)
            for change in ({"scene":"history-scroll"},{"action_count":1},{"verified":False},{"started_monotonic":0},{"ended_monotonic":5}):
                p.write_text(json.dumps({**base,**change}))
                with self.assertRaises(RuntimeError): matrix.validate_ui_actions(p,1,4,"resize")
    def test_early_timeout_creates_known_failure_record(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)
            def fail(*args):
                run=root/"vt-ascii-1-fixed"; run.mkdir(); matrix.LAST_RUN_DIR=run
                raise TimeoutError("ui-ready")
            old=matrix._one_run; matrix._one_run=fail
            try:
                with self.assertRaises(TimeoutError): matrix.one_run(SimpleNamespace(),Path("/app"),"vt","ascii",1,"vt-legacy",root)
            finally: matrix._one_run=old
            self.assertEqual(__import__('json').loads((root/"vt-ascii-1-fixed/run-summary.json").read_text())["status"],"failed")
    def test_owned_cleanup_does_not_touch_untracked(self):
        class P:
            def __init__(self): self.terminated=False
            def poll(self): return None
            def terminate(self): self.terminated=True
            def wait(self,timeout): return None
        tracked, untracked=P(),P(); matrix.ACTIVE_PROCS[:]=[tracked]
        with tempfile.TemporaryDirectory() as d:
            def fail(*args): raise RuntimeError("forced")
            old=matrix._one_run; matrix._one_run=fail
            try:
                with self.assertRaises(RuntimeError): matrix.one_run(None,None,"vt","ascii",1,"order",Path(d))
            finally: matrix._one_run=old
        self.assertTrue(tracked.terminated); self.assertFalse(untracked.terminated)

    def test_idle_scene_rejects_wrong_visibility(self):
        with self.assertRaises(RuntimeError): matrix.validate_scene({"status":"observed","visible":False},"visible-idle")

    def test_idle_dry_run_records_two_warmups_and_final_preload(self):
        with tempfile.TemporaryDirectory() as d:
            out=Path(d)/"out"; apps=Path(d)/"apps"
            subprocess.run(["python3",str(HERE/"terminal-m2-matrix.py"),"--output",str(out),"--apps-root",str(apps),"--pairs","1","--scenarios","visible-idle","--limit-runs","1","--dry-run"],env={**os.environ,"PYTHONDONTWRITEBYTECODE":"1"},check=True)
            control=next(out.glob("*/child/control.jsonl")); ops=[json.loads(x)["op"] for x in control.read_text().splitlines()]
            self.assertEqual(ops[:6],["reset","load","reset","load","reset","load"])
            self.assertEqual(ops[-1],"quit")

    def test_failed_sampler_status_is_rejected_by_contract(self):
        with tempfile.TemporaryDirectory() as d:
            path=Path(d)/"sample.json"; path.write_text(json.dumps({"sampling_status":"invalid_counter_decrease"}))
            with self.assertRaises(RuntimeError): matrix.validate_sample(path,0)
            with self.assertRaises(RuntimeError): matrix.validate_sample(Path(d)/"missing.json",0)
            path.write_text(json.dumps({"sampling_status":"valid"}))
            with self.assertRaises(RuntimeError): matrix.validate_sample(path,1)

    def test_ancestry_wrong_pid_is_rejected(self):
        with patch.object(matrix.subprocess,"run",return_value=SimpleNamespace(stdout="99\n")):
            with self.assertRaises(RuntimeError): matrix.ancestry(10,20)

    def test_background_snapshot_keeps_only_numeric_process_rows(self):
        class R:
            returncode=0
            stdout=" 12  1.5  42\n junk /bad args\n 13 nope 9\n 14 0.0 100\n"
        with patch.object(matrix.subprocess,"run",side_effect=[R(),R(),R()]) as mocked:
            result=matrix.background_snapshot((12,))
        self.assertEqual([x["pid"] for x in result["top5"]],[14])
        self.assertTrue(all("argv" not in x and "path" not in x for x in result["top5"]))
        self.assertTrue(all(len(call.args[0]) <= 3 for call in mocked.call_args_list))

    def test_background_snapshot_parses_memory_and_thermal_states(self):
        class R:
            def __init__(self, out, rc=0): self.stdout=out; self.returncode=rc
        values=[R(" 1 0 2\n"),R("System-wide memory free percentage: 47%\n"),R("No thermal warning level has been recorded\n")]
        with patch.object(matrix.subprocess,"run",side_effect=values):
            result=matrix.background_snapshot()
        self.assertEqual(result["memory_pressure"],{"status":"observed","free_percent":47.0})
        self.assertEqual(result["pmset"],{"status":"no_recorded_warning"})

    def test_background_snapshot_rejects_error_output_and_nonfinite_values(self):
        class R:
            def __init__(self,out,rc=0): self.stdout=out; self.returncode=rc
        values=[R(" 1 nan -2\n"),R("Error: unavailable\n"),R("Error\n")]
        with patch.object(matrix.subprocess,"run",side_effect=values):
            result=matrix.background_snapshot()
        self.assertEqual(result["process_count"],0)
        self.assertEqual(result["memory_pressure"]["status"],"unavailable")
        self.assertEqual(result["pmset"]["status"],"unavailable")

    def test_app_map_requires_two_unique_absolute_executables(self):
        with tempfile.TemporaryDirectory() as d:
            one=Path(d)/"one"; two=Path(d)/"two"; one.write_text("x"); two.write_text("x"); one.chmod(0o755); two.chmod(0o755)
            good=json.dumps([{"label":"alpha","path":str(one)},{"label":"beta","path":str(two)}])
            self.assertEqual([x[0] for x in matrix.parse_app_map(good)],["alpha","beta"])
            for bad in (json.dumps([{"label":"a","path":str(one)},{"label":"a","path":str(two)}]),json.dumps([{"label":"a","path":"relative"},{"label":"b","path":str(two)}]),json.dumps([{"label":"a","path":str(one)}])):
                with self.assertRaises(ValueError): matrix.parse_app_map(bad)

    def test_dry_run_app_map_uses_labels_and_pair_alternation(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d); one=root/"one"; two=root/"two"; one.write_text("x"); two.write_text("x"); one.chmod(0o755); two.chmod(0o755)
            out=root/"out"; mapping=json.dumps([{"label":"alpha","path":str(one)},{"label":"beta","path":str(two)}])
            subprocess.run(["python3",str(HERE/"terminal-m2-matrix.py"),"--output",str(out),"--apps-root",str(root),"--app-map",mapping,"--pairs","2","--scenarios","ascii","--limit-runs","4","--dry-run"],env={**os.environ,"PYTHONDONTWRITEBYTECODE":"1"},check=True)
            names=sorted(p.name for p in out.iterdir() if p.is_dir())
            self.assertTrue(any(n.startswith("alpha-ascii-1-") for n in names)); self.assertTrue(any(n.startswith("beta-ascii-1-") for n in names)); self.assertTrue(any(n.startswith("beta-ascii-2-") for n in names)); self.assertTrue(any(n.startswith("alpha-ascii-2-") for n in names))

if __name__ == "__main__": unittest.main(verbosity=2)
