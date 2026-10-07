#!/usr/bin/env python3
"""Generate AIME's emoji board from the pinned Unicode 16.0 emoji-test.txt.

Offline only. Supply the official source with --source; --check verifies an existing
catalog without changing it. The Unicode data license accompanies SharedSupport.
"""

import argparse
import hashlib
import json
from pathlib import Path

SOURCE_URL = "https://www.unicode.org/Public/emoji/16.0/emoji-test.txt"
SOURCE_SHA256 = "24f0c534e86cf142e2496953e8f0e46a3e702392911eddcd29c6cced85139697"
MAX_SOURCE_BYTES = 1 << 20
GROUPS = [
    ("Smileys & Emotion", "smileys", "表情"),
    ("People & Body", "people", "人物"),
    ("Animals & Nature", "nature", "自然"),
    ("Food & Drink", "food", "美食"),
    ("Travel & Places", "travel", "旅行"),
    ("Activities", "activities", "活动"),
    ("Objects", "objects", "物品"),
    ("Symbols", "symbols", "符号"),
    ("Flags", "flags", "旗帜"),
]


def generate(source):
    if source.stat().st_size > MAX_SOURCE_BYTES:
        raise ValueError("Unicode source exceeds the 1 MiB limit")
    raw = source.read_bytes()
    if hashlib.sha256(raw).hexdigest() != SOURCE_SHA256:
        raise ValueError("Unicode source SHA-256 mismatch")
    grouped = {name: [] for name, _, _ in GROUPS}
    group = None
    seen = set()
    qualified = excluded_skin = retained_hair = 0
    for line in raw.decode("utf-8").splitlines():
        if line.startswith("# group: "):
            group = line.removeprefix("# group: ")
            continue
        if not line or line.startswith("#"):
            continue
        sequence, separator, tail = line.partition(";")
        if not separator:
            raise ValueError("Malformed Unicode emoji row")
        if tail.partition("#")[0].strip() != "fully-qualified":
            continue
        qualified += 1
        points = [int(value, 16) for value in sequence.split()]
        if any(0x1F3FB <= value <= 0x1F3FF for value in points):
            excluded_skin += 1
            continue
        if any(0x1F9B0 <= value <= 0x1F9B3 for value in points):
            retained_hair += 1
        if group not in grouped:
            raise ValueError(f"Unexpected Unicode group: {group}")
        emoji = "".join(chr(value) for value in points)
        if emoji in seen:
            raise ValueError("Duplicate fully-qualified emoji")
        seen.add(emoji)
        grouped[group].append(emoji)
    if (qualified, excluded_skin, retained_hair, len(seen)) != (3781, 1875, 12, 1906):
        raise ValueError("Pinned Unicode 16.0 entry counts do not match")
    categories = [
        {"id": identifier, "title": title, "items": grouped[name]}
        for name, identifier, title in GROUPS
    ]
    if any(not category["items"] for category in categories):
        raise ValueError("An emoji category is empty")
    return {
        "version": 1,
        "unicodeVersion": "16.0",
        "sourceURL": SOURCE_URL,
        "sourceSHA256": SOURCE_SHA256,
        "license": "Unicode-3.0",
        "attribution": "Unicode, Inc.",
        "entryCount": len(seen),
        "categories": categories,
    }


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=root / "SharedSupport/aime/emoji.json")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        catalog = generate(args.source)
        data = (json.dumps(catalog, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
        if args.check:
            if args.output.read_bytes() != data:
                raise ValueError("Existing emoji catalog differs from the pinned source")
        else:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_bytes(data)
    except (OSError, ValueError) as error:
        parser.exit(1, f"emoji generation failed: {error}\n")
    print(json.dumps({
        "mode": "check" if args.check else "generate",
        "output": str(args.output),
        "categories": len(catalog["categories"]),
        "entries": catalog["entryCount"],
        "categoryCounts": {item["id"]: len(item["items"]) for item in catalog["categories"]},
        "sha256": hashlib.sha256(data).hexdigest(),
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
