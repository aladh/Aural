import unittest
import contract


class ReviewContractTests(unittest.TestCase):
    def test_path_policy(self):
        cases = (("Sources/Changed.swift", True), ("", False), ("/absolute.swift", False),
                 ("../outside.swift", False), ("Sources\\Changed.swift", False),
                 (".git/config", False), ("Sources/\x00.swift", False))
        for path, expected in cases:
            with self.subTest(path=path):
                self.assertEqual(contract.safe_path(path), expected)

    def test_right_hunk_anchors_include_context_but_not_deleted_only_lines(self):
        diff = b"@@ -1,4 +1,3 @@\n@@ -9 +8,0 @@\n@@ -12 +11 @@\n"
        self.assertEqual(contract._diff_right_lines(diff), [1, 2, 3, 11])


if __name__ == "__main__":
    unittest.main()
