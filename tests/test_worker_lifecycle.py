"""Real public CLI, with bounded stand-ins for a foreign media tool."""
import json,os,signal,subprocess,sys,tempfile,time,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

class WorkerLifecycle(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='omaconvert-worker-test-');self.addCleanup(self.tmp.cleanup)
        self.folder=Path(self.tmp.name);self.source=self.folder/'source.png';self.source.write_bytes(b'x')
        self.pidfile=self.folder/'pid'
    def stub(self,body):
        tool=self.folder/'ffprobe';tool.write_text('#!/usr/bin/python3\nimport os,sys,time,signal\n'+f'open({str(self.pidfile)!r},"w").write(str(os.getpid()))\n'+body+'\n');tool.chmod(0o700)
        return dict(os.environ,PATH=str(self.folder)+os.pathsep+os.environ['PATH'])
    def run_probe(self,body):
        return subprocess.run([sys.executable,str(ROOT/'bin/omaconvert'),'--probe',str(self.source)],env=self.stub(body),capture_output=True,text=True,timeout=10)
    def test_endless_stdout_is_bounded_and_reported(self):
        p=self.run_probe('while True: os.write(1,b"x"*4096)')
        events=[json.loads(x) for x in p.stdout.splitlines()]
        self.assertEqual(p.returncode,2,p.stdout+p.stderr)
        self.assertEqual(events[-1].get('reason'),'output-limit',events)
        self.assertLess(len(p.stdout),65536)
    def test_external_sigkill_is_not_reported_as_memory(self):
        p=self.run_probe('os.kill(os.getpid(),signal.SIGKILL)')
        events=[json.loads(x) for x in p.stdout.splitlines()]
        self.assertNotEqual(p.returncode,0)
        self.assertNotEqual(events[-1].get('reason'),'memory-limit')
    def test_killed_controller_leaves_no_tool(self):
        p=subprocess.Popen([sys.executable,str(ROOT/'bin/omaconvert'),'--probe',str(self.source)],env=self.stub('time.sleep(30)'),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        try:
            deadline=time.monotonic()+5
            while not self.pidfile.exists() and time.monotonic()<deadline:time.sleep(.02)
            self.assertTrue(self.pidfile.exists())
            pid=int(self.pidfile.read_text())
            p.kill();p.wait(timeout=3)
            deadline=time.monotonic()+3
            def alive():
                try:return Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()[0] not in ('Z','X')
                except FileNotFoundError:return False
            while alive() and time.monotonic()<deadline:time.sleep(.02)
            self.assertFalse(alive(),'tool survived killed controller')
        finally:
            if p.poll() is None:p.kill();p.wait()
            p.stdout.close();p.stderr.close()
