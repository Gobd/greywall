"""Executable discovery tests; no network requests or software installation."""
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from baseline import ROOT, find_installed_executable


class ExecutableDiscoveryTests(unittest.TestCase):
    def test_path_result_takes_priority(self):
        with mock.patch("baseline.shutil.which", return_value="/existing/path/bun"):
            self.assertEqual(find_installed_executable("bun", ["/missing/bun"]), "/existing/path/bun")

    def test_finder_path_uses_existing_executable_with_spaces(self):
        temporary = ROOT / ".build" / "tmp"
        temporary.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=temporary) as directory:
            executable = Path(directory) / "existing tool"
            executable.write_text("#!/bin/sh\nexit 0\n")
            executable.chmod(0o700)
            with mock.patch("baseline.shutil.which", return_value=None):
                self.assertEqual(find_installed_executable("bun", ["/missing/bun", str(executable)]), str(executable))

    def test_missing_or_nonexecutable_file_is_not_accepted(self):
        temporary = ROOT / ".build" / "tmp"
        temporary.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=temporary) as directory:
            file = Path(directory) / "not executable"
            file.write_text("not a program\n")
            file.chmod(0o600)
            with mock.patch("baseline.shutil.which", return_value=None):
                self.assertIsNone(find_installed_executable("bun", [str(file), directory]))

    def test_tilde_location_is_expanded(self):
        with mock.patch("baseline.shutil.which", return_value=None), \
             mock.patch("baseline.Path.is_file", return_value=True), \
             mock.patch("baseline.os.access", return_value=True):
            self.assertEqual(find_installed_executable("bun", ["~/.bun/bin/bun"]),
                             str(Path.home() / ".bun/bin/bun"))


if __name__ == "__main__":
    unittest.main()
