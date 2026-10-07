import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class DictionaryMetadataPermissionsTests(unittest.TestCase):
    def generate(self, shared, registry, output):
        # Public package directories already exist; a private umask must not
        # turn the new metadata file into a root-only package resource.
        previous_umask = os.umask(0o077)
        try:
            result = subprocess.run(
                [sys.executable, str(ROOT / "scripts/dictionary-metadata.py"),
                 "--shared-dir", str(shared), "--registry", str(registry),
                 "--schema", "fixture", "--dictionary", "fixture",
                 "--output", str(output)],
                capture_output=True, text=True,
            )
        finally:
            os.umask(previous_umask)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o644)
        self.assertEqual(stat.S_IMODE(output.parent.stat().st_mode), 0o755)
        metadata = json.loads(output.read_text())
        self.assertEqual(metadata["rawRows"], 1)
        self.assertEqual(metadata["sourceFiles"][0]["sha256"],
                         hashlib.sha256((shared / "fixture.dict.yaml").read_bytes()).hexdigest())
        return output.read_bytes()

    def fixture(self, folder):
        shared = folder / "SharedSupport"
        shared.mkdir()
        shared.chmod(0o755)
        (shared / "aime").mkdir()
        (shared / "aime").chmod(0o755)
        (shared / "fixture.dict.yaml").write_text(
            "---\nname: fixture\nversion: 2026-10-05\n...\nFixture\tfixture\t1\n"
        )
        registry = folder / "registry.json"
        registry.write_text(json.dumps({"packages": [{
            "id": "rime-ice", "license": "GPL-3.0", "sha256": "a" * 64,
            "source": {"type": "github-release", "repo": "fixture/fixture",
                       "tag": "fixture", "asset": "fixture.zip"},
        }]}))
        return shared, registry, shared / "aime/dictionary-metadata.json"

    def test_new_public_metadata_ignores_private_umask(self):
        with tempfile.TemporaryDirectory() as temporary:
            shared, registry, output = self.fixture(Path(temporary))
            self.generate(shared, registry, output)

    def test_regeneration_replaces_old_root_only_mode(self):
        with tempfile.TemporaryDirectory() as temporary:
            shared, registry, output = self.fixture(Path(temporary))
            expected = self.generate(shared, registry, output)
            output.chmod(0o600)
            self.assertEqual(self.generate(shared, registry, output), expected)


if __name__ == "__main__":
    unittest.main()
