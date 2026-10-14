import tempfile,unittest
from pathlib import Path
class CleanupTests(unittest.TestCase):
    def test_own_registered_temp_is_removed_but_unrelated_file_survives(self):
        from lib.cleanup import register, cleanup_job, set_job
        with tempfile.TemporaryDirectory() as d:
            import os
            from unittest.mock import patch
            root=Path(d);unit='omaconvert-job-'+'a'*32+'.scope'
            target=root/('.src.'+unit+'.tmp.png');target.write_bytes(b'partial')
            unrelated=root/'important.png';unrelated.write_bytes(b'keep')
            with patch('lib.cleanup.runtime_dir',lambda:root):
                set_job(unit);register(target);cleanup_job(unit);set_job(None)
            self.assertFalse(target.exists());self.assertEqual(unrelated.read_bytes(),b'keep')
