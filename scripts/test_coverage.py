"""Regression checks for the coverage gate's diff and LLVM interpretation."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('coverage_gate', Path(__file__).with_name('check-coverage.py'))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class CoverageTests(unittest.TestCase):
    def test_multiline_counts_stop_before_column_one(self):
        self.assertEqual(gate.executable_lines([[2, 1, 3, True], [5, 1, 0, False]]), {2: 3, 3: 3, 4: 3})

    def test_uncovered_regions_are_not_ignored(self):
        self.assertEqual(gate.executable_lines([[2, 1, 0, True], [4, 1, 0, False]]), {2: 0, 3: 0})

    def test_multiple_regions_on_same_line(self):
        self.assertEqual(gate.executable_lines([[2, 1, 0, True], [2, 5, 4, True], [2, 8, 0, False]]), {2: 4})

    def test_additions_deletions_and_multiple_hunks(self):
        diff = '+++ b/Sources/A.swift\n@@ -1 +1,2 @@\n@@ -5 +6 @@\n@@ -8,2 +8,0 @@\n'
        self.assertEqual(gate.changed_lines(diff), {'Sources/A.swift': {1, 2, 6}})

    def test_deleted_file_has_no_new_lines(self):
        self.assertEqual(gate.changed_lines('+++ /dev/null\n@@ -1 +0,0 @@'), {})

    def test_scope_includes_new_core_and_testable_ui(self):
        self.assertTrue(gate.measured('Sources/PaydayCore/NewFeature.swift'))
        self.assertTrue(gate.measured('Sources/Payday/AppModel.swift'))
        self.assertFalse(gate.measured('Sources/Payday/Views.swift'))


if __name__ == '__main__':
    unittest.main()
