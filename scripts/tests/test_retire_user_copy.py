"""retire-user-copy: the .pkg moves a leftover per-user AIME to the Trash (#32)."""
import pathlib
import plistlib
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "pkg" / "scripts" / "retire-user-copy"
BUNDLE_ID = "app.zool.inputmethod.aime"


def make_app(path: pathlib.Path, version: str, build: str, bundle_id: str = BUNDLE_ID) -> None:
    contents = path / "Contents"
    contents.mkdir(parents=True)
    with open(contents / "Info.plist", "wb") as handle:
        plistlib.dump({"CFBundleIdentifier": bundle_id, "CFBundleShortVersionString": version,
                       "CFBundleVersion": build}, handle)


class RetireUserCopyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        root = pathlib.Path(self.tmp.name)
        self.home = root / "home dir"  # spaces, like "Input Methods"
        self.copy = self.home / "Library" / "Input Methods" / "AIME.app"
        self.system = root / "Library" / "Input Methods" / "AIME.app"
        (self.home / "Library" / "Rime").mkdir(parents=True)
        (self.home / "Library" / "Rime" / "keep.txt").write_text("user data")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def run_script(self) -> subprocess.CompletedProcess:
        # Fed on stdin, as postinstall runs it (bash -s <home> <app> < retire-user-copy).
        with open(SCRIPT, encoding="utf-8") as script:
            return subprocess.run(["/bin/bash", "-s", str(self.home), str(self.system)], stdin=script,
                                  capture_output=True, text=True, check=False)

    def trash(self) -> list:
        trash = self.home / ".Trash"
        return sorted(p.name for p in trash.iterdir()) if trash.exists() else []

    def test_moves_leftover_copy_to_trash(self) -> None:
        make_app(self.copy, "0.1.8", "14")
        make_app(self.system, "0.1.11", "18")
        result = self.run_script()
        self.assertEqual(result.returncode, 0)
        self.assertFalse(self.copy.exists())
        self.assertEqual(self.trash(), ["AIME 0.1.8 (14) from Input Methods.app"])
        self.assertIn("moved leftover per-user copy 0.1.8 (14)", result.stderr)
        self.assertTrue(self.system.exists())
        self.assertEqual((self.home / "Library" / "Rime" / "keep.txt").read_text(), "user data")

    def test_second_leftover_does_not_overwrite_first(self) -> None:
        make_app(self.system, "0.1.11", "18")
        for _ in range(2):
            make_app(self.copy, "0.1.8", "14")
            self.assertEqual(self.run_script().returncode, 0)
        self.assertEqual(len(self.trash()), 2)

    def test_nothing_to_do_without_user_copy(self) -> None:
        make_app(self.system, "0.1.11", "18")
        result = self.run_script()
        self.assertEqual((result.returncode, result.stderr, self.trash()), (0, "", []))

    def test_keeps_user_copy_when_system_copy_missing(self) -> None:
        make_app(self.copy, "0.1.8", "14")
        self.assertEqual(self.run_script().returncode, 0)
        self.assertTrue(self.copy.exists())

    def test_ignores_foreign_bundle(self) -> None:
        make_app(self.copy, "1.0", "1", bundle_id="com.example.other")
        make_app(self.system, "0.1.11", "18")
        self.assertEqual(self.run_script().returncode, 0)
        self.assertTrue(self.copy.exists())


if __name__ == "__main__":
    unittest.main()
