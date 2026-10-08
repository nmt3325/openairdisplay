import unittest
from versioning import marketing_version

class VersionTests(unittest.TestCase):
    def test_fork_release(self):
        self.assertEqual(marketing_version("1.25.0","v1.25.0-air.17"),"1.25.17")
        self.assertEqual(marketing_version("1.25.0","v1.25.0-air"),"1.25.0")
    def test_upstream_patch_monotonic(self):
        self.assertEqual(marketing_version("1.25.1","v1.25.1-air.2"),"1.25.1002")
        self.assertEqual(marketing_version("1.26.0","v1.26.0-air"),"1.26.0")
    def test_mismatched_or_oversized_tag(self):
        for tag in ("v1.26.0-air.17","v1.25.0-air.1000","v1.25.0-air.1"):
            with self.assertRaises(ValueError):
                marketing_version("1.25.0",tag)
    def test_nonnumeric_upstream(self):
        with self.assertRaises(ValueError):
            marketing_version("1.25.0-air.17","v1.25.0-air.17")

if __name__=="__main__":
    unittest.main()
