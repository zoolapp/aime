import hashlib
import json
import runpy
import tempfile
import unittest
from pathlib import Path

EMBED = runpy.run_path(str(Path(__file__).resolve().parents[1] / "embed-license-materials.py"))["embed"]


class LicensePackagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="aime-license-test-")
        self.root = Path(self.temporary.name)
        self.source, self.app = self.root / "source", self.root / "AIME.app"
        self.license_path = "licenses/native-plugins/librime-fixture.LICENSE.txt"
        self.vendor_path = "Vendor/librime/lib/rime-plugins/librime-fixture.dylib"
        self.bundle_path = "Contents/Frameworks/rime-plugins/librime-fixture.dylib"
        self.write(self.source / self.license_path, b"fixture copyright and full license")
        self.write(self.source / self.vendor_path, b"fixture binary")
        self.write(self.app / self.bundle_path, b"fixture binary")
        component = {"component": "librime-fixture", "licenseFile": self.license_path,
                     "observedVendorBinary": self.vendor_path, "bundlePath": self.bundle_path,
                     "licenseSha256": hashlib.sha256(b"fixture copyright and full license").hexdigest(),
                     "observedVendorBinarySha256": hashlib.sha256(b"fixture binary").hexdigest()}
        self.manifest = {"components": [component], "completeCorrespondingSourceAuditPassed": False}
        self.write_manifest()
        for path in ["LICENSE", "THIRD_PARTY_NOTICES.md", "docs/native-plugin-license-audit.md", "docs/release-plan.md"]:
            self.write(self.source / path, path.encode())

    def tearDown(self):
        self.temporary.cleanup()

    def write(self, path, data):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def write_manifest(self):
        self.write(self.source / "licenses/native-plugins/manifest.json", json.dumps(self.manifest).encode())

    def test_embeds_exact_licenses_inventory_and_partial_receipt(self):
        receipt = EMBED(self.source, self.app)
        destination = self.app / "Contents/Resources/LicenseMaterials"
        self.assertEqual((destination / self.license_path).read_bytes(), (self.source / self.license_path).read_bytes())
        self.assertEqual(json.loads((destination / "licenses/native-plugins/manifest.json").read_bytes()), self.manifest)
        self.assertFalse(receipt["completeLicensePackagingAuditPassed"])
        self.assertFalse(receipt["completeCorrespondingSourceAuditPassed"])
        for file in receipt["files"]:
            content = (destination / file["path"]).read_bytes()
            self.assertEqual(hashlib.sha256(content).hexdigest(), file["sha256"])

    def test_rejects_changed_license_before_writing_resources(self):
        self.write(self.source / self.license_path, b"truncated license")
        with self.assertRaisesRegex(ValueError, "license hash mismatch"):
            EMBED(self.source, self.app)
        self.assertFalse((self.app / "Contents/Resources").exists())

    def test_rejects_replaced_vendor_even_if_bundle_matches(self):
        self.write(self.source / self.vendor_path, b"different binary")
        self.write(self.app / self.bundle_path, b"different binary")
        with self.assertRaisesRegex(ValueError, "Vendor binary hash mismatch"):
            EMBED(self.source, self.app)
        self.assertFalse((self.app / "Contents/Resources").exists())

    def test_rejects_changed_bundle_or_unlisted_plugin(self):
        self.write(self.app / self.bundle_path, b"different bundle")
        with self.assertRaisesRegex(ValueError, "bundle plugin differs"):
            EMBED(self.source, self.app)
        self.write(self.app / self.bundle_path, b"fixture binary")
        self.write(self.app / "Contents/Frameworks/rime-plugins/unlisted.dylib", b"extra")
        with self.assertRaisesRegex(ValueError, "directory differs"):
            EMBED(self.source, self.app)
        self.assertFalse((self.app / "Contents/Resources").exists())

    def test_rejects_manifest_path_traversal(self):
        self.manifest["components"][0]["licenseFile"] = "../../outside"
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, "unexpected inventory paths"):
            EMBED(self.source, self.app)
        self.assertFalse((self.app / "Contents/Resources").exists())


if __name__ == "__main__":
    unittest.main()
