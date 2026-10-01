#!/usr/bin/env python3
"""Embed the audited, partial native-plugin license inventory before signing."""

import argparse
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def embed(source_root, app):
    source_root, app = Path(source_root).resolve(), Path(app).resolve()
    inventory_path = "licenses/native-plugins/manifest.json"
    inventory = json.loads((source_root / inventory_path).read_bytes())
    components = inventory.get("components")
    if not isinstance(components, list) or not 1 <= len(components) <= 100:
        raise ValueError("expected 1–100 audited plugins")
    plugins = app / "Contents/Frameworks/rime-plugins"
    expected_names, payload = set(), {}
    # Validate every input before touching the bundle's resources.
    for component in components:
        name = component["component"]
        if not re.fullmatch(r"librime-[a-z0-9-]+", name):
            raise ValueError("invalid native-plugin name")
        filename = f"{name}.dylib"
        if filename in expected_names:
            raise ValueError("duplicate plugin in inventory")
        expected_names.add(filename)
        license_path = f"licenses/native-plugins/{name}.LICENSE.txt"
        binary_path = f"Vendor/librime/lib/rime-plugins/{filename}"
        bundle_path = f"Contents/Frameworks/rime-plugins/{filename}"
        if (component["licenseFile"] != license_path
                or component["observedVendorBinary"] != binary_path
                or component["bundlePath"] != bundle_path):
            raise ValueError(f"unexpected inventory paths: {name}")
        license_data = (source_root / license_path).read_bytes()
        if sha256(license_data) != component["licenseSha256"]:
            raise ValueError(f"license hash mismatch: {name}")
        binary_data = (source_root / binary_path).read_bytes()
        if sha256(binary_data) != component["observedVendorBinarySha256"]:
            raise ValueError(f"Vendor binary hash mismatch: {name}; re-audit the changed engine")
        if (app / bundle_path).read_bytes() != binary_data:
            raise ValueError(f"bundle plugin differs from audited Vendor input: {name}")
        payload[license_path] = license_data
    actual_names = {path.name for path in plugins.iterdir()}
    if actual_names != expected_names:
        raise ValueError("bundled plugin directory differs from audited inventory")
    for path in ["LICENSE", "THIRD_PARTY_NOTICES.md", inventory_path,
                 "docs/native-plugin-license-audit.md", "docs/release-checklist.md"]:
        payload[path] = (source_root / path).read_bytes()
    payload["README.txt"] = (
        "AIME license materials — partial inventory\n"
        "LICENSE applies to AIME original code; dependencies retain their licenses.\n"
        "licenses/native-plugins contains three audited plugin license texts and their source inventory.\n"
        "The inventory's Vendor hashes describe pre-signing input, not the signed bundle.\n"
        "Full transitive notices, GPL corresponding source and combined-work review remain pending.\n"
        "This bundle is not approved for public distribution by this embedding step.\n"
    ).encode("utf-8")
    receipt = {"schemaVersion": 1, "scope": "partial native-plugin license packaging",
               "completeLicensePackagingAuditPassed": False,
               "completeCorrespondingSourceAuditPassed": False,
               "pluginInputHashesVerifiedBeforeSigning": True,
               "files": [{"path": path, "bytes": len(data), "sha256": sha256(data)}
                         for path, data in sorted(payload.items())]}
    payload["packaging-receipt.json"] = (json.dumps(receipt, indent=2) + "\n").encode()
    destination = app / "Contents/Resources/LicenseMaterials"
    for path, data in sorted(payload.items()):
        target = destination / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    args = parser.parse_args()
    try:
        receipt = embed(ROOT, args.app)
    except (ValueError, OSError, KeyError, TypeError) as error:
        parser.exit(1, f"license embedding failed: {error}\n")
    print(f"Embedded {len(receipt['files'])} partial license/source-inventory files before signing")


if __name__ == "__main__":
    main()
