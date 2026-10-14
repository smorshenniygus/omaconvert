import json
from pathlib import Path
import subprocess
import sys
import unittest
ROOT=Path(__file__).resolve().parents[1]

class WorkerTests(unittest.TestCase):
    def test_status_keeps_desktop_details_without_user_bus(self):
        import os
        env = dict(os.environ, DBUS_SESSION_BUS_ADDRESS='unix:path=/nonexistent')
        p = subprocess.run([sys.executable, str(ROOT/'bin/omaconvert'), '--status'],
                           env=env, capture_output=True, timeout=10)
        self.assertEqual(p.returncode, 0, p.stdout)
        status = json.loads(p.stdout)
        self.assertEqual(status['event'], 'status')
        self.assertIn('capabilities_error', status)
        self.assertNotIn('capabilities', status)
        self.assertIn('hotkey', status)
        self.assertIn('open_with', status)

    def test_direct_worker_refuses_without_protection(self):
        worker=ROOT/'bin/omaconvert-worker'
        self.assertTrue(worker.exists(), 'worker entrypoint is missing')
        p=subprocess.run([sys.executable,str(worker),'omaconvert-job-forged.scope','268435456','--probe','/never-open.png'], input=b'go\n',capture_output=True,timeout=5)
        self.assertNotEqual(p.returncode,0)
        self.assertIn(b'protection-unavailable',p.stdout)

    def test_help_and_version_without_user_bus(self):
        import os
        env=dict(os.environ,DBUS_SESSION_BUS_ADDRESS='unix:path=/nonexistent')
        for args in (['--version'],['--help'],['--check']):
            p=subprocess.run([sys.executable,str(ROOT/'bin/omaconvert'),*args],env=env,capture_output=True,timeout=5)
            self.assertEqual(p.returncode,0,p.stderr)
