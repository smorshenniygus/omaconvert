"""Opt-in real cgroup tests. Run explicitly outside the filesystem sandbox."""
import json
import sys
import unittest
from lib.confinement import JobScope


class CgroupTests(unittest.TestCase):
    def test_verified_scope_contains_python_and_children(self):
        with JobScope(memory=256*1024**2) as scope:
            process = scope.start([sys.executable, '-c',
                "import sys,os,subprocess,json; sys.stdin.readline(); print(json.dumps([open('/proc/self/cgroup').read(),subprocess.check_output(['cat','/proc/self/cgroup'],text=True)]),flush=True); sys.stdin.read()"], 'inspect')
            process.stdin.write(b'go\n'); process.stdin.flush()
            data = json.loads(process.stdout.readline())
            self.assertTrue(all(scope.unit in line and 'omaconvert.slice' in line for line in data), data)
            self.assertGreater(scope.observations()['memoryPeakSampled'], 0)

    def test_allocator_is_stopped_under_256_mib(self):
        with JobScope(memory=256*1024**2) as scope:
            process = scope.start([sys.executable, '-c',
                "import sys; sys.stdin.readline(); x=bytearray(512*1024**2)"], 'inspect')
            process.stdin.write(b'go\n'); process.stdin.flush()
            process.wait(timeout=15)
            observed = scope.observations()
            self.assertNotEqual(process.returncode, 0)
            self.assertTrue(observed['oomKill'] or observed['result'] == 'oom-kill', observed)
    def test_two_scopes_share_one_aggregate_budget(self):
        with JobScope(memory=128*1024**2) as first, JobScope(memory=128*1024**2) as second:
            args=[sys.executable,'-c','import sys;sys.stdin.read()']
            first.start(args,'inspect');second.start(args,'inspect')
            self.assertEqual(first.path.parent,second.path.parent)
            self.assertLessEqual(int((first.path.parent/'memory.max').read_text()),first.budget.total_bytes)
            self.assertNotEqual(first.path,second.path)
