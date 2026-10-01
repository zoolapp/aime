#!/usr/bin/env python3
"""Verify the published catalog and real AIME subscriptions in disposable directories."""

import argparse
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CATALOG_URL = "https://raw.githubusercontent.com/zoolapp/aime-dicts/main/index.json"
MAX_FEEDS = 10


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", type=Path, default=ROOT / "Packages/AIMEKit/.build/debug/aime")
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    cli = args.cli.resolve(strict=True)
    if args.evidence.exists():
        parser.error("evidence directory already exists; use a fresh directory")
    args.evidence.mkdir(parents=True)
    with tempfile.TemporaryDirectory(prefix="aime-online-verification-") as temporary:
        root = Path(temporary)
        catalog_file = root / "index.json"
        response = subprocess.run([
            "curl", "-fLsS", "--max-time", "30", "--retry", "1", "-o", str(catalog_file),
            "-w", "%{http_code}", CATALOG_URL,
        ], capture_output=True, text=True, check=True, timeout=65)
        if response.stdout != "200":
            raise RuntimeError("catalog did not return HTTP 200")
        catalog_bytes = catalog_file.read_bytes()
        if catalog_bytes != (ROOT / "SharedSupport/aime/vocabulary-catalog.json").read_bytes():
            raise RuntimeError("shipped catalog differs from published catalog")
        catalog = json.loads(catalog_bytes)
        feeds = catalog.get("feeds", [])
        if not 1 <= len(feeds) <= MAX_FEEDS:
            raise RuntimeError("catalog exceeds the 1–10 feed verification limit")
        user, shared = root / "user", root / "shared"
        shared.mkdir()
        (shared / "default.yaml").write_text("schema_list:\n  - schema: rime_ice\n")
        (shared / "aime.yaml").write_text('config_version: "online-verification"\n')
        cases, combined = [], set()
        for index, feed in enumerate(feeds):
            url = feed["url"]
            if not url.startswith("https://raw.githubusercontent.com/zoolapp/aime-dicts/v"):
                raise RuntimeError("feed must use the official repository and a fixed version")
            process = subprocess.run([
                str(cli), "subscribe", "add", "--user-dir", str(user), "--shared-dir", str(shared),
                "--name", feed["name"], url,
            ], capture_output=True, text=True, timeout=90)
            (args.evidence / f"subscription-{index + 1}.log").write_text(process.stdout + process.stderr)
            if process.returncode:
                raise RuntimeError(f"subscription failed for {feed['id']}; see evidence")
            subscriptions = json.loads((user / "aime/subscriptions.json").read_text())
            item = next(item for item in subscriptions if item["url"] == url)
            cached = (user / "aime/subscriptions" / (item["id"] + ".txt")).read_bytes()
            sha = hashlib.sha256(cached).hexdigest()
            if item.get("lastError") or item["entryCount"] != feed["entries"]:
                raise RuntimeError("subscription count or error mismatch")
            if sha != feed["sha256"] or len(cached) != feed["size"]:
                raise RuntimeError("downloaded subscription checksum/size mismatch")
            for line in cached.decode().splitlines():
                if line and not line.startswith("#"):
                    text, code, _ = line.split("\t")
                    combined.add((text, code.replace(" ", "")))
            cases.append({"id": feed["id"], "url": url, "entries": item["entryCount"],
                          "sha256": sha, "bytes": len(cached), "passes": True})
        table = (user / "aime_online.txt").read_text()
        rows = {tuple(line.split("\t")[:2]) for line in table.splitlines() if line and not line.startswith("#")}
        if rows != combined:
            raise RuntimeError("rebuilt table does not match downloaded subscriptions")
        report = {"catalogURL": CATALOG_URL, "catalogHTTP": 200, "shippedCatalogMatches": True,
                  "cliSHA256": hashlib.sha256(cli.read_bytes()).hexdigest(),
                  "isolatedTemporaryWorkspace": True, "maxFeeds": MAX_FEEDS,
                  "feedEntries": sum(c["entries"] for c in cases), "mergedEntries": len(rows),
                  "feeds": cases, "passes": True}
        (args.evidence / "verification.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
