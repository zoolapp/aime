"""CHANGELOG.md and CHANGELOG.en.md follow the format their headers describe, agree with
each other, and list the version the app is built as (the website and the GitHub
Release notes are generated from them)."""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TYPES = {
    "zh": ["新增", "变更", "修复", "移除", "安全", "已知问题"],
    "en": ["Added", "Changed", "Fixed", "Removed", "Security", "Known issues"],
}
VERSION = re.compile(r"^## \[(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)\] - (\d{4}-\d{2}-\d{2})$")


def parse(path, lang):
    """[(version, date, status, [(type, [entries])])], newest first."""
    releases, current, kind = [], None, None
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("## "):
            match = VERSION.match(line)
            current = None
            if match:
                current = {"version": match[1], "date": match[2], "status": None, "types": []}
                releases.append(current)
            elif line != "## [Unreleased]":
                raise AssertionError(f"{path.name}: unexpected heading {line!r}")
        elif current is None:
            continue
        elif line.startswith("> ") and current["status"] is None and not current["types"]:
            current["status"] = line[2:].strip()
        elif line.startswith("### "):
            kind = line[4:].strip()
            if kind not in TYPES[lang]:
                raise AssertionError(f"{path.name} {current['version']}: unknown type {kind!r}")
            current["types"].append((kind, []))
        elif line.startswith("- ") and current["types"]:
            current["types"][-1][1].append(line[2:])
    return releases


class ChangelogTests(unittest.TestCase):
    def setUp(self):
        self.zh = parse(ROOT / "CHANGELOG.md", "zh")
        self.en = parse(ROOT / "CHANGELOG.en.md", "en")

    def test_each_release_is_complete(self):
        for lang, releases in (("zh", self.zh), ("en", self.en)):
            self.assertTrue(releases, lang)
            for release in releases:
                label = f"{lang} {release['version']}"
                self.assertTrue(release["status"], f"{label}: missing status line")
                kinds = [kind for kind, _ in release["types"]]
                self.assertTrue(kinds, f"{label}: no change types")
                self.assertEqual(kinds, sorted(kinds, key=TYPES[lang].index), f"{label}: types out of order")
                for kind, entries in release["types"]:
                    self.assertTrue(entries, f"{label} {kind}: empty")

    def test_languages_agree(self):
        def shape(releases, lang):
            return [(r["version"], r["date"], [(TYPES[lang].index(k), len(e)) for k, e in r["types"]]) for r in releases]
        self.assertEqual(shape(self.zh, "zh"), shape(self.en, "en"))

    def test_newest_first(self):
        dates = [r["date"] for r in self.zh]
        self.assertEqual(dates, sorted(dates, reverse=True))

    def test_lists_the_app_version(self):
        marketing = re.search(r'MARKETING_VERSION: "([^"]+)"', (ROOT / "project.yml").read_text()).group(1)
        self.assertEqual(self.zh[0]["version"].split("-")[0], marketing,
                         "the newest CHANGELOG version must match MARKETING_VERSION")


if __name__ == "__main__":
    unittest.main()
