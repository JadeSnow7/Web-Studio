#!/usr/bin/env python3
import json, os, pty, select, subprocess, tempfile, time, unittest, errno, fcntl
from unittest.mock import patch
from pathlib import Path
RUN=Path(__file__).with_name("terminal-m2-concurrent.py")
class ConcurrentTests(unittest.TestCase):
 def test_failure_gates(self):
  f=lambda n:[{"seq":i} for i in range(n)]
  import importlib.util
  s=importlib.util.spec_from_file_location('c',RUN); c=importlib.util.module_from_spec(s);s.loader.exec_module(c)
  self.assertEqual(c.final_status(f(20),f(200),b'',[]),'complete')
  self.assertEqual(c.final_status(f(19),f(200),b'',[]),'failed_input_sequence')
  self.assertEqual(c.final_status(f(20),f(199),b'',[]),'failed_output_count')
  self.assertEqual(c.final_status(f(20),f(200),b'x',[]),'failed_partial_input')
  self.assertEqual(c.final_status(f(20),f(200),b'',['write_error']),'failed_write_error')
 def test_real_pty_reset_start_quit_and_state(self):
  with tempfile.TemporaryDirectory(dir="/private/tmp") as d:
   out=Path(d)/"run";m,s=pty.openpty(); pid=os.fork()
   if pid==0: os.close(m); os.dup2(s,0);os.dup2(s,1);os.execv("/usr/bin/python3",["python3",str(RUN),"--child","--output",str(out)])
   os.close(s)
   for _ in range(100):
    if (out/"ready.jsonl").exists():break
    time.sleep(.01)
   ctl=out/"control.jsonl"
   with ctl.open("w") as f:f.write(json.dumps({"id":"r","op":"reset"})+"\n")
   deadline=time.time()+4; seen=b""
   while time.time()<deadline and b"\x1b[6n" not in seen:
    ready,_,_=select.select([m],[],[],.05)
    if ready: seen+=os.read(m,65536)
   os.write(m,b"\x1b[1;1R")
   with ctl.open("a") as f:f.write(json.dumps({"id":"s","op":"start"})+"\n")
   for _ in range(100):
    if (out/"events.jsonl").exists(): break
    time.sleep(.01)
   event=json.loads((out/"events.jsonl").read_text().splitlines()[0]); ready_row=json.loads((out/"ready.jsonl").read_text())
   self.assertEqual(event["id"],"s"); self.assertEqual(event["run_id"],ready_row["run_id"])
   self.assertEqual(event["clock_source"],"CLOCK_MONOTONIC_RAW"); self.assertIn("monotonic",event)
   for i in range(20):os.write(m,f"INPUT seq={i}\n".encode())
   deadline=time.time()+23
   while time.time()<deadline and (not (out/"result.jsonl").exists() or len((out/"result.jsonl").read_text().splitlines())<2):
    ready,_,_=select.select([m],[],[],.05)
    if ready:
     try:
      data=os.read(m,65536)
      if b"\x1b[6n" in data: os.write(m,b"\x1b[1;1R")
     except OSError: pass
   with ctl.open("a") as f:f.write(json.dumps({"id":"q","op":"quit"})+"\n")
   os.waitpid(pid,0); rows=[json.loads(x) for x in (out/"result.jsonl").read_text().splitlines()]
   start=next(x for x in rows if x.get("id")=="s");self.assertEqual(start["status"],"complete");self.assertEqual([x["seq"] for x in start["received"]],list(range(20)));self.assertEqual(start["dsr"]["status"],"observed");self.assertGreater(start["dsr"]["reply_end"],start["output"][-1]["actual"]);self.assertLessEqual(event["monotonic"],start["output"][0]["actual"])
 def test_write_all_zero_error_eagain_eintr_and_restores_flags(self):
  import importlib.util
  s=importlib.util.spec_from_file_location('c',RUN);c=importlib.util.module_from_spec(s);s.loader.exec_module(c)
  r,w=os.pipe(); old=fcntl.fcntl(w,fcntl.F_GETFL)
  for side,expected in [([0],"zero_write"),([OSError(errno.EIO,"io")],"write_error"),([BlockingIOError(),1],None),([InterruptedError(),1],None)]:
   calls=iter(side)
   def fake(fd,data):
    x=next(calls)
    if isinstance(x,BaseException): raise x
    return x
   with patch.object(c.os,"write",side_effect=fake):
    n,_,err=c.write_all(w,b"x",c.mono()+1)
   self.assertEqual(err,expected); self.assertEqual(fcntl.fcntl(w,fcntl.F_GETFL),old); self.assertEqual(n,0 if expected else 1)
  os.close(r);os.close(w)

 def test_real_pty_reset_wrong_dsr_fails(self):
  with tempfile.TemporaryDirectory(dir="/private/tmp") as d:
   out=Path(d)/"run";m,s=pty.openpty();pid=os.fork()
   if pid==0: os.close(m);os.dup2(s,0);os.dup2(s,1);os.execv("/usr/bin/python3",["python3",str(RUN),"--child","--output",str(out)])
   os.close(s)
   for _ in range(100):
    if (out/"ready.jsonl").exists():break
    time.sleep(.01)
   ctl=out/"control.jsonl";ctl.write_text(json.dumps({"id":"r","op":"reset"})+"\n");buf=b"";deadline=time.time()+3
   while time.time()<deadline and b"\x1b[6n" not in buf:
    ready,_,_=select.select([m],[],[],.05)
    if ready:buf+=os.read(m,65536)
   os.write(m,b"\x1b[2;2R");time.sleep(.1)
   with ctl.open("a") as f:f.write(json.dumps({"id":"q","op":"quit"})+"\n")
   os.waitpid(pid,0)
   rows=[json.loads(x) for x in (out/"result.jsonl").read_text().splitlines()];self.assertEqual(next(x for x in rows if x.get("id")=="r")["status"],"failed")
if __name__=="__main__":unittest.main(verbosity=2)
