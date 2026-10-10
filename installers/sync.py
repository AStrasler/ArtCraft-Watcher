#!/usr/bin/env python3
"""Download and maintain exactly one verified Windows x64 MSI per ArtCraft app."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
from datetime import datetime, timezone
from urllib.request import Request, urlopen

APPS = ("designcraft", "effectcraft", "filmcraft", "lightcraft", "pdfcraft", "photocraft", "vectorcraft")
API = "https://api.github.com/repos/storytold/{}/releases/latest"

def fetch(url, token=None):
    headers = {"User-Agent": "ArtCraft-Watcher-Installer-Archive", "Accept": "application/vnd.github+json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    return urlopen(Request(url, headers=headers), timeout=90)

def download(url, path, token=None):
    digest = hashlib.sha256()
    with fetch(url, token) as response, open(path, "wb") as out:
        while chunk := response.read(1024 * 1024):
            out.write(chunk)
            digest.update(chunk)
    return digest.hexdigest()

def sync(root, token=None):
    root.mkdir(parents=True, exist_ok=True)
    manifest_path = root / "manifest.json"
    existing = json.loads(manifest_path.read_text(encoding="utf-8")) if manifest_path.exists() else {}
    manifest = dict(existing)
    for app in APPS:
        release = json.load(fetch(API.format(app), token))
        assets = release.get("assets", [])
        msi = next((a for a in assets if re.fullmatch(rf"{app}-.*-windows-x64\.msi", a["name"], re.I)), None)
        checksums = next((a for a in assets if a["name"] == "SHA256SUMS.txt"), None)
        if not msi or not checksums:
            raise RuntimeError(f"{app}: missing official MSI or SHA256SUMS.txt")
        target = root / f"{app}-windows-x64.msi"
        if manifest.get(app, {}).get("version") == release["tag_name"] and target.is_file():
            current = hashlib.file_digest(open(target, "rb"), "sha256").hexdigest()
            if current == manifest[app]["sha256"]:
                print(f"CURRENT {app} {release['tag_name']}", flush=True)
                continue
        with tempfile.TemporaryDirectory(dir=root) as temp:
            temp = Path(temp)
            checksum_path = temp / "SHA256SUMS.txt"
            download(checksums["browser_download_url"], checksum_path)
            sums = checksum_path.read_text(encoding="utf-8")
            matches = [line for line in sums.splitlines() if line.strip().endswith(msi["name"])]
            if len(matches) != 1:
                raise RuntimeError(f"{app}: checksum entry missing or ambiguous")
            expected = matches[0].split()[0].lower()
            if not re.fullmatch(r"[a-f0-9]{64}", expected):
                raise RuntimeError(f"{app}: invalid SHA256 entry")
            staged = temp / msi["name"]
            actual = download(msi["browser_download_url"], staged)
            if actual != expected or (msi.get("digest") and msi["digest"].lower() != "sha256:" + actual):
                raise RuntimeError(f"{app}: checksum mismatch, existing installer preserved")
            os.replace(staged, target)
        manifest[app] = {"version": release["tag_name"], "sha256": actual, "source": msi["browser_download_url"], "verified_at": datetime.now(timezone.utc).isoformat()}
        manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(f"UPDATED {app} {release['tag_name']} VERIFIED", flush=True)
    print("All seven apps checked.", flush=True)

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", type=Path, required=True, help="Private destination for installers")
    args = parser.parse_args()
    sync(args.directory, os.environ.get("GITHUB_TOKEN"))
