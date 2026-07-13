"""Tests for the shared gateway helpers (common.py)."""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "services"))
import common  # noqa: E402


class TestEnvHelpers(unittest.TestCase):
    def test_env_default(self):
        os.environ.pop("GEIVS_NOPE_XYZ", None)
        self.assertEqual(common.env("GEIVS_NOPE_XYZ", "d"), "d")

    def test_env_int(self):
        os.environ["GEIVS_TEST_INT"] = "42"
        self.assertEqual(common.env_int("GEIVS_TEST_INT", 0), 42)

    def test_env_int_falls_back_on_garbage(self):
        os.environ["GEIVS_TEST_INT"] = "notanint"
        self.assertEqual(common.env_int("GEIVS_TEST_INT", 7), 7)

    def test_env_int_missing(self):
        os.environ.pop("GEIVS_MISSING_INT", None)
        self.assertEqual(common.env_int("GEIVS_MISSING_INT", 5), 5)

    def test_env_list_trims_and_drops_blanks(self):
        os.environ["GEIVS_TEST_LIST"] = " +1, +2 ,, +3 "
        self.assertEqual(common.env_list("GEIVS_TEST_LIST"), ["+1", "+2", "+3"])

    def test_env_list_default(self):
        os.environ.pop("GEIVS_MISSING_LIST", None)
        self.assertEqual(common.env_list("GEIVS_MISSING_LIST", "a,b"), ["a", "b"])


class TestSecret(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self._orig = common.SECRETS_DIR
        common.SECRETS_DIR = self.tmp

    def tearDown(self):
        common.SECRETS_DIR = self._orig

    def test_reads_and_strips_file(self):
        with open(os.path.join(self.tmp, "my-token"), "w") as f:
            f.write("  s3cr3t\n")
        self.assertEqual(common.secret("my-token"), "s3cr3t")

    def test_env_fallback_when_file_missing(self):
        os.environ["MY_TOKEN"] = "fromenv"
        self.assertEqual(common.secret("my-token"), "fromenv")

    def test_default_when_nothing_set(self):
        os.environ.pop("MISSING_ONE", None)
        self.assertEqual(common.secret("missing-one", "def"), "def")


if __name__ == "__main__":
    unittest.main()
