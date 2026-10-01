#!/usr/bin/env python3
"""Build a raster reference PDF and a bounded, hashed brand asset archive."""
from pathlib import Path
import hashlib
import json
import shutil
import zipfile
from reportlab.pdfgen import canvas
from reportlab.lib.utils import ImageReader

root = Path(__file__).resolve().parents[2]
base = root / "assets/brand/aime/base-v1"
pdf = base / "brand-reference.pdf"
c = canvas.Canvas(str(pdf), pagesize=(1600, 1120), invariant=1)
c.setTitle("AIME Visual Base 1.0")
c.setAuthor("AIME")
for page, filename in enumerate(["brand-board.png", "paper-reference.png", "extension-board.png", "small-size-review.png"], start=1):
    c.setFillColorRGB(247/255, 242/255, 233/255)
    c.rect(0, 0, 1600, 1120, stroke=0, fill=1)
    if filename == "brand-board.png":
        c.drawImage(str(base / filename), 0, 0, width=1600, height=1120, mask="auto")
    elif filename == "paper-reference.png":
        c.setFillColorRGB(36/255, 35/255, 33/255)
        c.setFont("Helvetica-Bold", 28)
        c.drawString(60, 1034, "AIME / Paper material & pose references")
        c.drawImage(str(base / filename), 60, 248, width=1480, height=740, mask="auto")
        c.setFont("Helvetica", 18)
        c.drawString(60, 160, "Ivory front / vermilion reverse / gentle return curl")
        c.drawString(60, 120, "Use the vector master for geometry; this image is a material reference.")
    elif filename == "extension-board.png":
        c.drawImage(str(base / filename), 0, 50, width=1600, height=1020, mask="auto")
    else:
        c.setFillColorRGB(36/255, 35/255, 33/255)
        c.setFont("Helvetica-Bold", 28)
        c.drawString(60, 1034, "AIME / Menu icon asset review")
        c.drawImage(str(base / filename), 300, 370, width=1000, height=440, mask="auto")
        c.setFont("Helvetica", 18)
        c.drawString(60, 200, "16 / 20 / 24 / 32 px: alpha-matched black and white candidates.")
        c.drawString(60, 160, "This is an asset review, not a macOS input-source screenshot.")
    c.setFillColorRGB(36/255, 35/255, 33/255)
    c.setFont("Helvetica", 12)
    c.drawRightString(1540, 22, f"AIME BASE 1.0 / {page:02d}")
    c.showPage()
c.save()
shutil.copy2(root / "LICENSE", base / "LICENSE")
prompt = root / "docs/brand/final-2026-10-01/generation-prompts.json"
shutil.copy2(prompt, base / "paper-reference-provenance.json")
source_files = sorted((root / "scripts/brand").glob("*"))
asset_files = sorted(p for p in base.rglob("*") if p.is_file() and p.name != "manifest.json")
entries = [(p, p.relative_to(base).as_posix()) for p in asset_files]
entries += [(p, "source/" + p.name) for p in source_files if p.is_file()]
assert len(entries) <= 128, "Archive entry hard limit exceeded"
manifest = {
    "version": "1.0", "direction": "soft-bookmark", "tagline": "中文常新，自在表达。",
    "limits": {"archive_entries": 128, "image_generation_calls": 1},
    "files": [{"path": name, "bytes": p.stat().st_size, "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for p, name in entries],
    "notes": ["Independent SVG masters are editable vectors", "Menu PDF is a 16pt vector candidate", "Reference PDF contains raster pages", "App and menu integration not tested"]
}
(base / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
archive = base.parent / "aime-brand-base-v1.zip"
with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as z:
    for p, name in entries + [(base / "manifest.json", "manifest.json")]:
        info = zipfile.ZipInfo("aime-brand-base-v1/" + name, date_time=(2026, 10, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        z.writestr(info, p.read_bytes())
print(f"Created 4-page reference PDF and ZIP: {len(entries)+1} entries; {archive.stat().st_size} bytes")
