#!/usr/bin/env python3
"""Reproducibly assemble toolchain-xtensa-esp8266 PlatformIO package from Espressif releases."""

import argparse
import hashlib
import json
import os
import shutil
import tarfile
import urllib.request
import zipfile
from pathlib import Path

UPSTREAM_TAG = "esp-16.2.0_20261109"
ASSETS = {
    "windows_amd64": {
        "url": f"https://github.com/espressif/crosstool-NG/releases/download/{UPSTREAM_TAG}/xtensa-esp-elf-16.2.0_20261109-x86_64-w64-mingw32.zip",
        "sha256": "8DE83704FDCF58189E337CBC63A1167A3C3CC078E193EFA7FDC113BDF000C337",
        "filename": "xtensa-esp-elf-16.2.0_20261109-x86_64-w64-mingw32.zip",
    },
    "esp8266_multilib": {
        "url": f"https://github.com/espressif/crosstool-NG/releases/download/{UPSTREAM_TAG}/xtensa-esp-elf-16.2.0_20261109-esp8266-multilib.tar.xz",
        "sha256": "515E90793BA949CFA60D4DD8297862B0A46F5275C024DCC1AC64E3DC2B80B0BA",
        "filename": "xtensa-esp-elf-16.2.0_20261109-esp8266-multilib.tar.xz",
    },
}


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest().upper()


def ensure_asset(cache_dir: Path, spec: dict) -> Path:
    path = cache_dir / spec["filename"]
    if not path.is_file():
        print(f"Downloading {spec['url']} -> {path}")
        urllib.request.urlretrieve(spec["url"], path)
    digest = sha256_file(path)
    if digest != spec["sha256"].upper():
        raise RuntimeError(f"SHA256 mismatch for {path}: got {digest}, expected {spec['sha256']}")
    return path


def build_package(work_dir: Path, out_zip: Path, manifest_path: Path) -> None:
    work_dir.mkdir(parents=True, exist_ok=True)
    host_zip = ensure_asset(work_dir, ASSETS["windows_amd64"])
    multilib_txz = ensure_asset(work_dir, ASSETS["esp8266_multilib"])

    stage = work_dir / "stage"
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)

    print(f"Extracting {host_zip.name}...")
    with zipfile.ZipFile(host_zip, "r") as zf:
        zf.extractall(stage)

    print(f"Overlaying {multilib_txz.name}...")
    with tarfile.open(multilib_txz, "r:xz") as tf:
        tf.extractall(stage, filter="tar")

    tc_root = stage / "xtensa-esp-elf"
    if not tc_root.is_dir():
        raise RuntimeError(f"Expected {tc_root} inside extracted toolchain")

    shutil.copy2(manifest_path, tc_root / "package.json")

    out_zip.parent.mkdir(parents=True, exist_ok=True)
    print(f"Packing PlatformIO archive -> {out_zip}...")
    with zipfile.ZipFile(out_zip, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as zout:
        for root, _, files in os.walk(tc_root):
            for fname in sorted(files):
                full = Path(root) / fname
                rel = full.relative_to(tc_root).as_posix()
                zout.write(full, rel)

    out_sha = sha256_file(out_zip)
    sha_file = out_zip.with_suffix(out_zip.suffix + ".sha256")
    sha_file.write_text(f"{out_sha.lower()}  {out_zip.name}\n", encoding="utf-8")
    print(f"Done: {out_zip} ({out_zip.stat().st_size:,} bytes), SHA256={out_sha.lower()}")


def main() -> None:
    repo_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description="Build toolchain-xtensa-esp8266 PlatformIO package")
    parser.add_argument("--work-dir", default=str(repo_root / "build"))
    parser.add_argument(
        "--out",
        default=str(repo_root / "build" / "toolchain-xtensa-esp8266-windows_amd64-16.2.0.zip"),
    )
    args = parser.parse_args()
    build_package(Path(args.work_dir), Path(args.out), repo_root / "package.json")


if __name__ == "__main__":
    main()
