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
    def test_no_manager_never_starts_tool(self):
        env=self.stub('print("should never execute")')
        runtime=self.folder/'runtime';runtime.mkdir(mode=0o700)
        env.update(XDG_RUNTIME_DIR=str(runtime),DBUS_SESSION_BUS_ADDRESS='unix:path=/nonexistent')
        p=subprocess.run([sys.executable,str(ROOT/'bin/omaconvert'),'--probe',str(self.source)],env=env,capture_output=True,text=True,timeout=10)
        events=[json.loads(x) for x in p.stdout.splitlines()]
        self.assertEqual(events[-1].get('reason'),'protection-unavailable',events)
        self.assertFalse(self.pidfile.exists())
    def test_absolute_inspection_deadline(self):
        code='import sys;sys.path.insert(0,'+repr(str(ROOT))+');from lib import controller;controller.PROBE_TIMEOUT=.3;from lib.cli import main;sys.exit(main())'
        p=subprocess.run([sys.executable,'-c',code,'--probe',str(self.source)],env=self.stub('time.sleep(30)'),capture_output=True,text=True,timeout=8)
        events=[json.loads(x) for x in p.stdout.splitlines()]
        self.assertEqual(events[-1].get('reason'),'timeout',events)
    def test_mixed_probe_and_cleanup_flags_keep_worker_boundary(self):
        marker=self.folder/'group'
        probe_json=json.dumps({"streams":[{"codec_type":"video","width":1,"height":1}],"format":{"format_name":"png_pipe"}})
        env=self.stub(f'open({str(marker)!r},"w").write(open("/proc/self/cgroup").read());print({probe_json!r})')
        p=subprocess.run([sys.executable,str(ROOT/'bin/omaconvert'),'--probe',str(self.source),'--forget-preview',str(self.folder/'src-preview.png')],env=env,capture_output=True,text=True,timeout=10)
        self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        self.assertIn('/omaconvert.slice/omaconvert-job-',marker.read_text())
    def test_second_conversion_queues_and_can_be_cancelled(self):
        import selectors
        env=self.stub('time.sleep(5)')
        args=[sys.executable,str(ROOT/'bin/omaconvert'),str(self.source),'--format','mp4']
        first=subprocess.Popen(args,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        second=None
        try:
            deadline=time.monotonic()+5
            while not self.pidfile.exists() and time.monotonic()<deadline:time.sleep(.02)
            self.assertTrue(self.pidfile.exists())
            original=self.pidfile.read_text()
            second=subprocess.Popen(args,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            with selectors.DefaultSelector() as sel:
                sel.register(second.stdout,selectors.EVENT_READ)
                self.assertTrue(sel.select(2),'second conversion did not report queue')
                queued=json.loads(second.stdout.readline())
            self.assertEqual(queued['event'],'queued')
            self.assertEqual(self.pidfile.read_text(),original)
            second.terminate();out,err=second.communicate(timeout=3)
            self.assertEqual(json.loads(out.splitlines()[-1])['event'],'cancelled')
            self.assertIsNone(first.poll())
        finally:
            for process in (second,first):
                if process:
                    if process.poll() is None:process.terminate()
                    process.communicate(timeout=5)
