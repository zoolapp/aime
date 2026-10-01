#!/usr/bin/env python3
"""Probe only a downloaded package's CLI; never install or start IMKit.

This is a component test, not a clean macOS installation or UI acceptance test.
Uses macOS sandbox-exec to deny existing RIME/AIME data, development libraries,
and networking. All workspace data and extracted binaries live in a fresh temp.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile


def verify(package, sums, output, preview_baseline=False):
    package, output = package.resolve(), output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    expected = [line.split()[0] for line in sums.read_text().splitlines()
                if len(line.split()) == 2 and line.split()[1].lstrip("*") == package.name]
    actual = hashlib.sha256(package.read_bytes()).hexdigest()
    if len(expected) != 1 or actual != expected[0]:
        raise ValueError("Package checksum does not match exactly one manifest entry")
    report = {"package_sha256": actual, "checksum_passed": True,
              "scope": "preview baseline" if preview_baseline else "release component probe",
              "commands": {}, "clean_system_install_tested": False,
              "full_chain_passed": False}
    count = 0

    def run(name, args, env=None, cwd=None, timeout=180):
        nonlocal count
        count += 1
        if count > 128:
            raise RuntimeError("Hard command limit exceeded")
        p = subprocess.run(args, env=env, cwd=cwd, capture_output=True,
                           text=True, timeout=timeout)
        (output / (name + ".log")).write_text(p.stdout + p.stderr)
        report["commands"][name] = {"exit_code": p.returncode}
        return p

    try:
        signature = run("package-signature", ["/usr/sbin/pkgutil", "--check-signature", str(package)])
        gatekeeper = run("package-gatekeeper", ["/usr/sbin/spctl", "--assess", "--type", "install", "--verbose=2", str(package)])
        staple = run("package-staple", ["/usr/bin/xcrun", "stapler", "validate", str(package)])
        report["distribution_checks_passed"] = all(p.returncode == 0 for p in (signature, gatekeeper, staple))
        if not report["distribution_checks_passed"] and not preview_baseline:
            raise ValueError("Distribution checks failed; runtime probe refused")
        with tempfile.TemporaryDirectory(prefix="aime-package-isolation-", dir="/private/tmp") as temporary:
            root = Path(temporary).resolve()
            expanded = root / "expanded"
            if run("expand", ["/usr/sbin/pkgutil", "--expand-full", str(package), str(expanded)]).returncode:
                raise ValueError("Package expansion failed")
            apps = list(expanded.rglob("AIME.app"))
            if len(apps) != 1:
                raise ValueError("Expected exactly one input method app")
            app = apps[0]
            cli = app / "Contents/Helpers/aime"
            if not cli.is_file():
                raise ValueError("Bundled CLI is missing")
            if run("app-signature", ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)]).returncode:
                raise ValueError("App signature integrity failed")
            home = Path.home().resolve()
            repo = Path(__file__).resolve().parent.parent
            denied = [home / p for p in ["Library/Rime", "Library/AIME", "Library/Logs/AIME",
                      "Library/Application Support/AIME", "Library/Input Methods"]]
            denied += [Path("/Library/Input Methods"), Path("/Applications/AIME Settings.app"),
                       Path("/opt/homebrew"), Path("/usr/local"), repo]
            profile = root / "isolation.sb"
            policy = '(version 1)\n(allow default)\n(deny network*)\n'
            for path in denied:
                policy += '(deny file-read* file-write* (subpath ' + json.dumps(str(path.resolve())) + '))\n'
            profile.write_text(policy)
            (output / "isolation.sb").write_text(policy)
            env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(root / "home"),
                   "TMPDIR": str(root), "AIME_USER_DIR": str(root / "workspace"),
                   "AIME_STATS_DIR": str(root / "stats"),
                   "AIME_CREDENTIALS_FILE": str(root / "credentials.json")}
            (root / "home").mkdir()
            prefix = ["/usr/bin/sandbox-exec", "-f", str(profile)]
            # Use a known existing forbidden file, so a missing file cannot fake isolation.
            probe = run("deny-probe", prefix + ["/usr/bin/stat", str(repo / "AGENTS.md")], env, root)
            if probe.returncode == 0 or "Operation not permitted" not in probe.stderr:
                raise ValueError("Sandbox denial was not verified")
            files = [cli, app / "Contents/MacOS/AIME"] + list((app / "Contents/Frameworks").rglob("*.dylib"))
            if len(files) > 64:
                raise ValueError("Hard Mach-O inventory limit exceeded")
            forbidden = re.compile(r"^\s*(?:/opt/homebrew/|/usr/local/|/Users/|/Library/Input Methods/)", re.M)
            for index, file in enumerate(files):
                libraries = run("dependencies-" + str(index), ["/usr/bin/otool", "-L", str(file)])
                # Skip the file-name header; inspect actual install names only.
                if libraries.returncode or forbidden.search("\n".join(libraries.stdout.splitlines()[1:])):
                    raise ValueError("External development dependency found")
            if (root / "workspace").exists():
                raise ValueError("Probe workspace was not initially empty")
            # bench deploys internally without the deploy command's global reload
            # notification, which could wake the user's installed input method.
            bench = run("deploy-and-candidates", prefix + [str(cli), "bench", "--schema", "rime_ice",
                        "--keys", "nihaoshijie", "--iterations", "20", "--print-candidates"], env, root)
            if bench.returncode or not re.search(r"^\d+\. .*?[\u3400-\u9fff]", bench.stdout, re.M):
                raise ValueError("Chinese candidates were not observed")
            if not all((root / "workspace/build" / name).is_file()
                       for name in ["default.yaml", "aime.yaml", "rime_ice.schema.yaml"]):
                raise ValueError("Empty-workspace deployment artifacts are missing")
            report["bundle_smoke_passed"] = True
    except (ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        report["error"] = str(error)
        report["bundle_smoke_passed"] = False
    report["command_count"] = count
    (output / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if report.get("bundle_smoke_passed") else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    parser.add_argument("sums", type=Path)
    parser.add_argument("output", type=Path, help="New evidence directory (must not exist)")
    parser.add_argument("--preview-baseline", action="store_true", help="Explicitly probe an unsigned old preview; not final release acceptance")
    args = parser.parse_args()
    raise SystemExit(verify(args.package, args.sums, args.output, args.preview_baseline))
