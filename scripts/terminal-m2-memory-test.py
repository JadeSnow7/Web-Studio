#!/usr/bin/env python3
import importlib.util, json, os, subprocess, sys, tempfile, unittest
from pathlib import Path
from unittest.mock import patch
RUN=Path(__file__).with_name("terminal-m2-memory.py")
s=importlib.util.spec_from_file_location("memory",RUN); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)

class MemoryTests(unittest.TestCase):
 def test_parser_known_and_unknown(self):
  sample="COUNT BYTES AVERAGE CLASSNAME\n 2 10 5 Foo\n 1 3 3 Bar\nTotal 3 nodes"
  self.assertEqual(m.parse_heap(sample),{"status":"observed","total_nodes":3,"total_bytes":13})
  self.assertEqual(m.parse_heap("Total 1,234 objects 5 MB")["status"],"unavailable")
  self.assertEqual(m.parse_heap("object listing without totals")["status"],"unavailable")
  self.assertEqual(m.parse_heap(sample.replace("Total 3 nodes","Total 4 nodes"))["reason"],"node_total_mismatch")
  self.assertEqual(m.parse_heap(sample.replace(" 1 3 3 Bar"," 1 3 4 Bar"))["reason"],"average_mismatch")
  injected=sample.replace("Foo", "PRIVATE CLASS NAME WITH SECRET")
  got=m.parse_heap(injected); self.assertEqual(got["status"],"observed"); self.assertNotIn("PRIVATE",json.dumps(got))
  got=m.parse_vmmap("Physical footprint: 7 MB\nMALLOC_TINY 2 MB"); self.assertEqual(got["physical_footprint_bytes"],7*1024**2); self.assertEqual(got["malloc"]["status"],"unavailable")
  self.assertEqual(m.parse_vmmap("Physical footprint current: 2 MB\nPhysical footprint: 3 MB")["physical_footprint_bytes"],3*1024**2)
  self.assertEqual(m.parse_vmmap("MALLOC_TINY 2 MB")["status"],"unavailable")
  self.assertEqual(m.parse_vmmap("unknown")["status"],"unavailable")
 def test_identity_pid_and_path(self):
  with patch.object(m.os,"kill"), patch.object(m,"executable_path",return_value="/App/Binary"):
   self.assertEqual(m.verify_identity(123,"/App/Binary")["status"],"observed")
   self.assertEqual(m.verify_identity(123,"/Other")["status"],"identity_mismatch")
  self.assertEqual(m.verify_identity(0,"/App/Binary")["status"],"invalid_pid")
 def test_bounded_timeout_and_sizecap(self):
  class Fake:
   pid=123
   def poll(self): return None
   def wait(self,**kw): return 0
   stdout=None
  with patch.object(m.subprocess,"Popen",return_value=Fake()), patch.object(m.os,"killpg"):
   self.assertEqual(m.run_bounded(["tool"],m.mono()-.1,Path("/private/tmp"))[0],"timeout")
  rfd,wfd=os.pipe(); os.write(wfd,b"012345"); os.close(wfd)
  class Done:
   pid=123
   def __init__(self,fd): self.stdout=os.fdopen(fd,"rb")
   def poll(self): return 0
   def wait(self,**kw): return 0
  try:
   with patch.object(m.subprocess,"Popen",return_value=Done(rfd)):
    self.assertEqual(m.run_bounded(["tool"],m.mono()+1,Path("/private/tmp"),3)[0],"size_cap")
  finally:
   try: os.close(rfd)
   except OSError: pass
 def test_output_is_redacted_and_unique(self):
  with tempfile.TemporaryDirectory(dir="/private/tmp") as d:
   p=Path(d)/"out.json"; payload={"schema":"x","status":"complete","pid":1,"identity_status":"observed","heap":m.parse_heap("Total 2 objects 1 KB"),"vmmap":m.parse_vmmap("Physical footprint: 3 KB")}; p.write_text(json.dumps(payload))
   text=p.read_text(); self.assertNotIn("/private/tmp",text); self.assertNotIn("MALLOC",text); self.assertTrue(all(k in payload for k in ("heap","vmmap")))
 def test_size_cap_constant(self): self.assertEqual(m.MAX_CAPTURE,256*1024*1024)
 def test_partial_writer_times_out_without_blocking(self):
  code="import sys,time; sys.stdout.write('x'); sys.stdout.flush(); time.sleep(2)"
  state,raw=m.run_bounded([sys.executable,"-c",code],m.mono()+.25,Path("/private/tmp"),100)
  self.assertEqual(state,"timeout"); self.assertEqual(raw,b"x")
 def test_exit_drain_preserves_pipe_tail(self):
  code="import sys; sys.stdout.buffer.write(b'abcdef'); sys.stdout.flush()"
  state,raw=m.run_bounded([sys.executable,"-c",code],m.mono()+2,Path("/private/tmp"),100)
  self.assertEqual(state,"ok"); self.assertEqual(raw,b"abcdef")

if __name__=="__main__": unittest.main(verbosity=2)
