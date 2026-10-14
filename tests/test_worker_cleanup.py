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
    def test_old_preview_sessions_are_removed_without_touching_live_session(self):
        from lib.preview import sweep_preview_sessions
        import os
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)
            old=root/'p999999999999-stale';old.mkdir(mode=0o700);(old/'src-preview.png').write_bytes(b'old')
            live=root/f'p{os.getpid()}-live';live.mkdir(mode=0o700);(live/'src-preview.png').write_bytes(b'live')
            with patch('lib.preview.cache_dir',lambda:root):sweep_preview_sessions()
            self.assertFalse(old.exists());self.assertTrue((live/'src-preview.png').exists())
