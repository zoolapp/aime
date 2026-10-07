#!/usr/bin/env python3
"""Count the enabled Rime dictionary's raw records and record source hashes.

Offline, streaming, and deliberately not a general YAML parser. Supports the pinned
dictionary headers' scalar fields and block lists only; unfamiliar YAML is rejected.
Each reachable source file is read once. Word records are not deduplicated.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import tempfile

MAX_HEADER_BYTES = 1 << 20
MAX_LINE_BYTES = 1 << 20
MAX_FILES = 64
MAX_DEPTH = 16
SCALAR_KEYS = {"name", "version", "sort"}
LIST_KEYS = {"import_tables", "columns"}
TOKEN = re.compile(r"[A-Za-z0-9_./-]+")
SHA256 = re.compile(r"[0-9a-f]{64}")


def safe_name(value):
    path = PurePosixPath(value)
    if (not TOKEN.fullmatch(value) or value.startswith("/") or "\\" in value
            or any(part in ("", ".", "..") for part in value.split("/"))):
        raise ValueError(f"unsafe dictionary name: {value!r}")
    return path


def scalar(value, context):
    # The pinned headers use only ASCII identifiers and ISO/version strings. Reject
    # anchors, aliases, tags, flow collections and escapes instead of guessing YAML.
    if len(value) >= 2 and value[0] in "\"'" and value[-1] == value[0]:
        value = value[1:-1]
    if not TOKEN.fullmatch(value):
        raise ValueError(f"unsupported YAML scalar at {context}")
    return value


def read_dictionary(shared, name):
    relative = str(safe_name(name)) + ".dict.yaml"
    path = shared / relative
    if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(shared):
        raise ValueError(f"missing or unsafe dictionary source: {relative}")
    digest = hashlib.sha256()
    header = {}
    started = ended = False
    active_list = None
    header_bytes = rows = 0
    with path.open("rb") as source:
        for number, raw in enumerate(source, 1):
            if len(raw) > MAX_LINE_BYTES:
                raise ValueError(f"line exceeds 1 MiB at {relative}:{number}")
            digest.update(raw)
            line = raw.decode("utf-8").rstrip("\r\n")
            if number == 1:
                line = line.removeprefix("\ufeff")
            if ended:
                if line.strip() and not line.lstrip().startswith("#"):
                    rows += 1
                continue
            header_bytes += len(raw)
            if header_bytes > MAX_HEADER_BYTES:
                raise ValueError(f"header exceeds 1 MiB: {relative}")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            content = line.split("#", 1)[0].rstrip()
            context = f"{relative}:{number}"
            if content == "---" and not started:
                started = True
                continue
            if content == "..." and started:
                ended = True
                continue
            if not started or "\t" in content:
                raise ValueError(f"unsupported YAML header at {context}")
            if content.startswith("  - "):
                if active_list is None:
                    raise ValueError(f"list without supported header key at {context}")
                value = scalar(content[4:].strip(), context)
                if active_list == "import_tables":
                    safe_name(value)
                header[active_list].append(value)
                continue
            match = re.fullmatch(r"([a-z_]+):(?: (.*))?", content)
            if match is None:
                raise ValueError(f"unsupported YAML syntax at {context}")
            key, value = match.groups()
            if key in header or key not in SCALAR_KEYS | LIST_KEYS:
                raise ValueError(f"duplicate or unsupported YAML key {key!r} at {context}")
            active_list = None
            if key in LIST_KEYS:
                if value not in (None, "", "[]"):
                    raise ValueError(f"only block lists or [] supported at {context}")
                header[key] = []
                active_list = key if value != "[]" else None
            else:
                header[key] = scalar(value or "", context)
    if not ended or not header.get("name") or not header.get("version"):
        raise ValueError(f"incomplete dictionary header: {relative}")
    return {
        "path": relative, "dictionary": header["name"], "version": header["version"],
        "sha256": digest.hexdigest(), "rawRows": rows,
        "importTables": header.get("import_tables", []),
    }


def generate(shared, registry, package_id, schema, dictionary):
    shared = shared.resolve()
    safe_name(schema)
    safe_name(dictionary)
    package = next((item for item in registry["packages"] if item["id"] == package_id), None)
    if package is None:
        raise ValueError(f"unknown source package: {package_id}")
    source = package["source"]
    if source["type"] != "github-release":
        raise ValueError("only the pinned github-release package source is supported")
    if not SHA256.fullmatch(package["sha256"]) or not package.get("license"):
        raise ValueError("source package is missing its SHA-256 or license")
    files, visiting, visited = [], set(), set()

    def visit(name, depth):
        if depth > MAX_DEPTH:
            raise ValueError("dictionary import depth exceeds 16")
        if name in visiting:
            raise ValueError(f"dictionary import cycle: {name}")
        if name in visited:
            return
        if len(files) >= MAX_FILES:
            raise ValueError("dictionary imports exceed 64 source files")
        visiting.add(name)
        record = read_dictionary(shared, name)
        files.append(record)
        for imported in record["importTables"]:
            visit(imported, depth + 1)
        visiting.remove(name)
        visited.add(name)

    visit(dictionary, 0)
    return {
        "version": 1, "schema": schema, "dictionary": dictionary,
        "packageID": package_id, "sourceVersion": source["tag"],
        "sourceURL": f'https://github.com/{source["repo"]}/releases/download/{source["tag"]}/{source["asset"]}',
        "sourceSHA256": package["sha256"], "license": package["license"],
        "rawRows": sum(item["rawRows"] for item in files),
        "rawRowsDescription": "按根词库及启用的 import_tables 递归统计，每个来源文件读取一次；排除空行和注释，不按词条去重，不代表唯一词数或实际候选数。未启用的词表不计入。",
        "sourceFiles": files,
    }


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shared-dir", type=Path, default=root / "build/SharedSupport")
    parser.add_argument("--registry", type=Path, default=root / "dicts/registry.json")
    parser.add_argument("--package-id", default="rime-ice")
    parser.add_argument("--schema", default="rime_ice")
    parser.add_argument("--dictionary", default="rime_ice")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    output = args.output or args.shared_dir / "aime/dictionary-metadata.json"
    protected = [Path.home() / "Library/Rime", Path.home() / "Library/AIME/Rime"]
    try:
        for candidate in (args.shared_dir.resolve(), output.resolve()):
            if any(candidate == path or candidate.is_relative_to(path) for path in protected):
                raise ValueError("dictionary metadata must not read or write live user directories")
        metadata = generate(args.shared_dir, json.loads(args.registry.read_text()), args.package_id, args.schema, args.dictionary)
        data = (json.dumps(metadata, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
        if args.check:
            if output.read_bytes() != data:
                raise ValueError("dictionary metadata differs from the enabled source files")
        else:
            output.parent.mkdir(parents=True, exist_ok=True)
            temporary = None
            try:
                with tempfile.NamedTemporaryFile(dir=output.parent, delete=False) as destination:
                    temporary = Path(destination.name)
                    destination.write(data)
                    # This is public bundled metadata. pkgbuild changes ownership
                    # to root, so NamedTemporaryFile's 0600 would hide it from users.
                    os.fchmod(destination.fileno(), 0o644)
                os.replace(temporary, output)
            finally:
                if temporary is not None:
                    temporary.unlink(missing_ok=True)
    except (OSError, UnicodeError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"dictionary metadata failed: {error}\n")
    print(json.dumps({"mode": "check" if args.check else "generate", "output": str(output),
                      "schema": metadata["schema"], "dictionary": metadata["dictionary"],
                      "rawRows": metadata["rawRows"], "sourceFiles": len(metadata["sourceFiles"]),
                      "sha256": hashlib.sha256(data).hexdigest()}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
