import os,signal,subprocess,sys,tempfile,time,unittest
from pathlib import Path
from lib.process import ProcessRunner
from lib.events import EventSink
from lib.errors import ProcessFailed
from lib.preview import forget_preview
ROOT=Path(__file__).resolve().parents[1]
def alive(pid):
    try:return Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()[0] not in ('Z','X')
    except FileNotFoundError:return False
class ReviewRegressions(unittest.TestCase):
    def test_timeout_includes_descendant_pipe_drain(self):
        child='import time;time.sleep(1.2)'
        code='import subprocess,sys;subprocess.Popen([sys.executable,"-c",'+repr(child)+'])'
        start=time.monotonic()
        with self.assertRaises(ProcessFailed):
            ProcessRunner(EventSink()).capture([sys.executable,'-c',code],'test',timeout=.15)
        self.assertLess(time.monotonic()-start,1.1)
    def test_forgetting_preview_does_not_remove_active_job_temp(self):
        with tempfile.TemporaryDirectory() as d:
            target=Path(d)/'src-preview.png';target.write_bytes(b'old')
            active=Path(d)/'.src-preview.png.omaconvert-job-abc.scope.tmp.png';active.write_bytes(b'active')
            forget_preview(target)
            self.assertTrue(active.exists())
    def test_controller_death_stops_tool_grandchild(self):
        with tempfile.TemporaryDirectory() as d:
            folder=Path(d);source=folder/'input.png';source.write_bytes(b'x');marker=folder/'pid'
            tool=folder/'ffprobe'
            tool.write_text('#!/usr/bin/python3\nimport subprocess,sys,time\np=subprocess.Popen([sys.executable,"-c","import time;time.sleep(3)"])\nopen('+repr(str(marker))+',"w").write(str(p.pid))\ntime.sleep(3)\n');tool.chmod(0o700)
            p=subprocess.Popen([sys.executable,str(ROOT/'bin/omaconvert'),'--probe',str(source)],env=dict(os.environ,PATH=str(folder)+os.pathsep+os.environ['PATH']),stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            pid=None
            try:
                deadline=time.monotonic()+5
                while not marker.exists() and time.monotonic()<deadline:time.sleep(.02)
                self.assertTrue(marker.exists());pid=int(marker.read_text())
                p.kill();p.wait(timeout=3)
                deadline=time.monotonic()+1
                while alive(pid) and time.monotonic()<deadline:time.sleep(.02)
                self.assertFalse(alive(pid),'grandchild survived controller')
            finally:
                if p.poll() is None:p.kill();p.wait()
                if pid and alive(pid):os.kill(pid,signal.SIGKILL)
