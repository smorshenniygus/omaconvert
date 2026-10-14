import unittest
from pathlib import Path


class BudgetTests(unittest.TestCase):
    def test_budget_preserves_reserve_and_ancestor_limit(self):
        from lib.confinement import effective_budget
        gib = 1024 ** 3
        self.assertEqual(effective_budget(8*gib, []).total_bytes, 5153960755)
        self.assertEqual(effective_budget(8*gib, [2*gib]).total_bytes, gib)
        self.assertEqual(effective_budget(8*gib, [2*gib]).inspect_bytes, gib)

    def test_insufficient_capacity_refuses(self):
        from lib.confinement import effective_budget, ProtectionUnavailable
        with self.assertRaises(ProtectionUnavailable):
            effective_budget(1024**3, [])

    def test_unconfined_process_cannot_claim_worker_protection(self):
        from lib.confinement import verify_worker, ProtectionUnavailable
        with self.assertRaises(ProtectionUnavailable):
            verify_worker('omaconvert-job-forged.scope', 256*1024**2)
