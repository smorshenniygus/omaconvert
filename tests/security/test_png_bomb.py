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

    def test_qml_selection_recovers_after_bomb(self):
        import subprocess, shutil
        root=Path(__file__).resolve().parents[2]
        wrapper=self.folder/'bounded_cli.py'
        wrapper.write_text("import sys\nsys.dont_write_bytecode=True\nsys.path.insert(0,"+repr(str(root))+")\nfrom lib import controller\nfrom lib.confinement import JobScope\ncontroller.JobScope=lambda:JobScope(memory=256*1024**2)\nfrom lib.cli import main\nsys.exit(main())\n")
        harness=(root/'tests/qml/SecurityHarness.qml').read_text().replace('../../services',(root/'services').as_uri())
        (self.folder/'shell.qml').write_text(harness)
        env=dict(os.environ,QT_QPA_PLATFORM='offscreen',QT_QPA_PLATFORMTHEME='',QT_QUICK_CONTROLS_STYLE='Basic',
            HOME=str(self.folder),XDG_CONFIG_HOME=str(self.folder/'config'),XDG_CACHE_HOME=str(self.folder/'cache'),
            OMACONVERT_TEST_CLI=str(wrapper),OMACONVERT_TEST_BOMB=str(self.bomb),OMACONVERT_TEST_GOOD=str(root/'assets/kv.jpg'))
        result=subprocess.run(['qs','-p',str(self.folder/'shell.qml'),'--no-color'],env=env,capture_output=True,text=True,timeout=30)
        output=result.stdout+result.stderr
        self.assertEqual(result.returncode,0,output)
        self.assertIn('PASS hostile selection recovered',output)
        self.assertNotIn('FAIL',output)
        print(output,flush=True)
