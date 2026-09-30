#!/usr/bin/env python3
"""Check standalone naming, app assets, and preserved MIT notices without launching."""
import argparse
from pathlib import Path
import plistlib
import re
import subprocess

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--app", type=Path)
args = parser.parse_args()
excluded = {".git", ".build", "build", ".swiftpm", "__pycache__"}
# Assemble the old identifiers so the audit does not match its own source.
old_brand = re.compile(r"notification" + r"na" + r"nny|na" + r"nny", re.IGNORECASE)
# Crediting the upstream project is required; only these files may name it, and only this way.
credit_files = {"README.md", "CHANGELOG.md", "docs/THIRD_PARTY_NOTICES.md"}
credit_name = "Notification " + "Na" + "nny"
credit = re.compile(re.escape(f"[{credit_name}](https://github.com/chessper53/{credit_name.replace(' ', '')})"))
for path in root.rglob("*"):
    relative = path.relative_to(root)
    if excluded.intersection(relative.parts) or not path.is_file():
        continue
    assert not old_brand.search(str(relative)), f"Legacy filename: {relative}"
    try:
        text = path.read_text()
    except UnicodeDecodeError:
        continue
    if str(relative) in credit_files:
        text = credit.sub("", text)
    assert not old_brand.search(text), f"Legacy branding: {relative}"

license_text = (root / "LICENSE").read_text()
notices_text = (root / "docs/THIRD_PARTY_NOTICES.md").read_text()
upstream_copyright = "Copyright (c) 2026 chessper53"
permission = "The above copyright notice and this permission notice shall be included"
for text in (license_text, notices_text):
    assert upstream_copyright in text and permission in text

if args.app:
    app = args.app.resolve()
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    assert info["CFBundleIdentifier"] == "io.github.jakobkollerup.notchnotify"
    assert info["CFBundleName"] == info["CFBundleExecutable"] == "NotchNotify"
    assert info["CFBundleIconFile"] == "NotchNotify"
    resources = app / "Contents/Resources"
    assert (resources / "LICENSE.txt").read_text() == license_text
    assert (resources / "THIRD_PARTY_NOTICES.md").read_text() == notices_text
    assert info["CFBundleShortVersionString"] == (root / "VERSION").read_text().strip()
    for filename in ["NotchNotify.icns", "Brand/NotchNotify-Icon.png", "Brand/NotchNotify-Logo.png", "Brand/NotchNotify-MenuBar.png"]:
        assert (resources / filename).stat().st_size > 100, f"Missing asset: {filename}"
    binary = app / "Contents/MacOS/NotchNotify"
    assert not old_brand.search(subprocess.run(["strings", str(binary)], check=True, capture_output=True, text=True).stdout)
    subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
print("NotchNotify branding, assets, and preserved MIT notices verified.")
