"""Explicit live tests. Preflight proves enforcement before any hostile decode."""
import io,json,os,signal,sys,tempfile,time,unittest
from pathlib import Path
from unittest.mock import patch
from lib.confinement import JobScope
from lib.controller import run_controlled
from lib.events import EventSink
from tests.security.png_fixture import write_metadata_png

class BombTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with JobScope(memory=256*1024**2) as scope:
            p=scope.start([sys.executable,'-c','import sys;sys.stdin.readline();x=bytearray(512*1024**2)'],'inspect')
            p.stdin.write(b'go\n');p.stdin.flush();p.wait(timeout=15)
            obs=scope.observations()
            if not p.returncode or not (obs['oomKill'] or obs['result']=='oom-kill'):
                raise RuntimeError('Enforcement preflight failed; bomb MUST NOT RUN')
        cls.temp=tempfile.TemporaryDirectory(prefix='omaconvert-security-')
        cls.folder=Path(cls.temp.name)
        cls.bomb=cls.folder/'metadata.png'
        cls.fixture=write_metadata_png(cls.bomb,1024**3,4*1024**2)
        print('FIXTURE '+json.dumps(cls.fixture),flush=True)
    @classmethod
    def tearDownClass(cls):cls.temp.cleanup()
    def exercise(self,args):
        scopes=[];samples=[]
        class MeasuredScope(JobScope):
            def __init__(self):
                super().__init__(memory=256*1024**2);scopes.append(self)
            def observations(self):
                data=super().observations();samples.append(data);return data
        output=io.StringIO();started=time.monotonic()
        def deadline(*_):raise TimeoutError('Security test exceeded 30 seconds')
        previous=signal.signal(signal.SIGALRM,deadline);signal.alarm(30)
        try:
            # Override only policy downwards; real controller, worker, manager,
            # codecs, cgroups and kernel enforcement run unchanged.
            with patch('lib.controller.JobScope',MeasuredScope):
                code=run_controlled(args,'inspect',EventSink(output))
        finally:
            signal.alarm(0);signal.signal(signal.SIGALRM,previous)
        events=[json.loads(line) for line in output.getvalue().splitlines()]
        self.assertTrue(events)
        self.assertIn(code,(0,2),events)
        if code:self.assertEqual(events[-1]['event'],'error')
        self.assertTrue(scopes and all(s.process.poll() is not None for s in scopes))
        print('SECURITY '+json.dumps({'operation':args[0],'elapsed':time.monotonic()-started,'code':code,'events':events,'observations':samples[-1] if samples else {}}),flush=True)
        return code
    def test_probe_bomb(self):self.exercise(['--probe',str(self.bomb)])
    def test_preview_bomb(self):
        target=self.folder/'preview.png'
        code=self.exercise(['--preview',str(self.bomb),'--preview-output',str(target)])
        if code:self.assertFalse(target.exists())
        elif target.exists():self.assertLessEqual(target.stat().st_size,1024**2)
