#!/usr/bin/env python3
"""Exports AIME's built-in color schemes as aime-theme v1 packages (docs/themes.md).

    python3 scripts/export-themes.py [--out <themes.json>] [--fixtures <dir>]

Defaults write the website data (../aime-web/src/data/themes.json when that checkout
exists) and the shared test fixtures (Packages/AIMEKit/Tests/AIMECoreTests/Fixtures/theme-v1).
The website copies the fixture directory verbatim; both test suites must match it.
"""
import argparse
import base64
import hashlib
import json
import os
import sys

import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "SharedSupport", "aime.yaml")
KEYS = [
    "back_color", "border_color", "preedit_back_color", "text_color", "hilited_text_color",
    "hilited_back_color", "candidate_text_color", "comment_text_color", "label_color",
    "hilited_candidate_back_color", "hilited_candidate_text_color", "hilited_comment_text_color",
    "hilited_candidate_label_color",
]
LAYOUT_KEYS = ["corner_radius", "hilited_corner_radius", "border_width", "border_height", "spacing",
               "line_spacing", "font_point", "label_font_point", "comment_font_point"]
# Same fallbacks as PanelTheme for keys a scheme leaves out.
FALLBACK = {"preedit_back_color": "0x00000000", "border_color": "0x00000000", "hilited_back_color": "0x00000000"}


def color_string(value):
    """YAML reads unquoted 0x… as an integer; normalise to 0xAARRGGBB."""
    if isinstance(value, int):
        return "0x%08X" % value
    text = str(value).strip().lower()
    text = text[2:] if text.startswith("0x") else text.lstrip("#")
    if len(text) == 6:
        text = "ff" + text
    if len(text) != 8:
        raise ValueError("bad color %r" % value)
    return "0x" + text.upper()


def canonical(package):
    return json.dumps(package, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def encode(package):
    data = canonical(package).encode("utf-8")
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def rgba(argb):
    raw = int(argb, 16)
    return ((raw >> 16) & 0xFF) / 255, ((raw >> 8) & 0xFF) / 255, (raw & 0xFF) / 255, ((raw >> 24) & 0xFF) / 255


def over(top, base):
    r, g, b, a = top
    return (r * a + base[0] * (1 - a), g * a + base[1] * (1 - a), b * a + base[2] * (1 - a), 1.0)


def luminance(c):
    lin = lambda v: v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4
    return 0.2126 * lin(c[0]) + 0.7152 * lin(c[1]) + 0.0722 * lin(c[2])


def contrast(a, b):
    la, lb = luminance(a), luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def min_contrast(colors):
    """PanelTheme.minimumTextContrast with default style (no translucency, alpha 1)."""
    base = over(rgba(colors["back_color"]), (0.5, 0.5, 0.5, 1))
    normal = contrast(over(rgba(colors["candidate_text_color"]), base), base)
    hb = over(rgba(colors["hilited_candidate_back_color"]), base)
    highlighted = contrast(over(rgba(colors["hilited_candidate_text_color"]), hb), hb)
    return round(min(normal, highlighted), 2)


def is_dark(colors):
    return luminance(over(rgba(colors["back_color"]), (0.5, 0.5, 0.5, 1))) < 0.18


def package(theme_id, name, author, colors, layout=None):
    p = {"format": "aime-theme", "version": 2 if layout else 1, "id": theme_id, "name": name, "author": author, "colors": colors}
    if layout:
        p["layout"] = layout
    return p


def number(v):
    v = float(v)
    return int(v) if v.is_integer() else v


def default_layout(style):
    """What the panel uses with AIME's shipped style: style/aime wins, then style."""
    aime = style.get("aime") or {}
    return {k: number(aime.get(k, style[k])) for k in LAYOUT_KEYS if k in aime or k in style}


def case(pkg):
    d = encode(pkg)
    return {"id": pkg["id"], "package": pkg, "canonical": canonical(pkg), "d": d,
            "url": "aime-ime://theme?v=%d&d=" % pkg["version"] + d, "min_contrast": min_contrast(pkg["colors"]),
            "dark": is_dark(pkg["colors"])}


def builtins():
    raw = open(SOURCE, "rb").read()
    config = yaml.safe_load(raw)
    schemes = config["preset_color_schemes"]
    base_layout = default_layout(config["style"])
    themes = []
    for theme_id, scheme in schemes.items():
        if scheme.get("color_format") != "argb":
            raise SystemExit("%s: only color_format argb is exported" % theme_id)
        colors = {k: color_string(scheme[k]) if k in scheme else FALLBACK[k] for k in KEYS}
        layout = dict(base_layout, **{k: number(scheme[k]) for k in LAYOUT_KEYS if k in scheme})
        themes.append(package(theme_id, scheme.get("name", theme_id), scheme.get("author", "AIME"), colors, layout))
    return themes, hashlib.sha256(raw).hexdigest()


def extras(themes):
    by_id = {t["id"]: t for t in themes}
    sakura = dict(by_id["sakura"]["colors"])
    sakura["hilited_candidate_back_color"] = "0xFFD81B60"
    low = dict(by_id["aime_light"]["colors"])
    low.update(candidate_text_color="0xFFC8C7C4", hilited_candidate_back_color="0xFFEDEDEB",
               hilited_candidate_text_color="0xFFFFFFFF")
    tight = dict(by_id["sakura"]["layout"], corner_radius=14, hilited_corner_radius=0, border_width=0, border_height=0, font_point=18)
    return [package("sakura_test", "樱花测试 / Sakura test", "Fixture", sakura, tight),
            package("low_contrast", "低对比度", "Fixture", low)]  # v1: colors only


def invalid_cases(themes):
    base = extras(themes)[0]
    def variant(**changes):
        p = json.loads(json.dumps(base))
        for key, value in changes.items():
            if key == "colors":
                p["colors"].update(value)
            elif value is None:
                p.pop(key, None)
            else:
                p[key] = value
        return p
    missing = json.loads(json.dumps(base)); missing["colors"].pop("label_color")
    oversize = variant(name="长" * 40, author="x" * 40)
    oversize["padding"] = "x" * 4200
    rows = [
                ("wrong_format", variant(format="ghostty"), "format"),
        ("reserved_id", variant(id="aime_custom"), "reserved"),
        ("bad_id", variant(id="Sakura-Test"), "id"),
        ("missing_color", missing, "colors"),
        ("bad_color", variant(colors={"back_color": "red"}), "colors"),
        ("long_name", variant(name="名" * 41), "name"),
        ("layout_out_of_range", variant(layout=dict(base["layout"], font_point=99)), "layout"),
        ("version_3", variant(version=3), "version"),
        ("oversize", oversize, "size"),
    ]
    out = [{"name": n, "d": encode(p), "reason": r} for n, p, r in rows]
    out.append({"name": "not_base64", "d": "%%%", "reason": "encoding"})
    out.append({"name": "not_json", "d": base64.urlsafe_b64encode(b"theme").decode().rstrip("="), "reason": "encoding"})
    return out


def write(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(value, f, ensure_ascii=False, indent=2)
        f.write("\n")


def main():
    web = os.path.join(os.path.dirname(ROOT), "aime-web", "src", "data", "themes.json")
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default=web if os.path.isdir(os.path.dirname(web)) else None)
    parser.add_argument("--fixtures", default=os.path.join(ROOT, "Packages/AIMEKit/Tests/AIMECoreTests/Fixtures/theme-v1"))
    args = parser.parse_args()

    themes, source_sha = builtins()
    cases = [case(t) for t in themes]
    if args.out:
        write(args.out, {"version": 1, "source": "SharedSupport/aime.yaml", "source_sha256": source_sha,
                         "themes": [{"id": c["id"], "name": c["package"]["name"], "author": c["package"]["author"],
                                     "colors": c["package"]["colors"], "layout": c["package"].get("layout"), "dark": c["dark"],
                                     "min_contrast": c["min_contrast"], "d": c["d"]} for c in cases]})
        print("wrote", args.out)
    if args.fixtures:
        write(os.path.join(args.fixtures, "valid.json"), cases + [case(p) for p in extras(themes)])
        write(os.path.join(args.fixtures, "invalid.json"), invalid_cases(themes))
        print("wrote", args.fixtures)


if __name__ == "__main__":
    sys.exit(main())
