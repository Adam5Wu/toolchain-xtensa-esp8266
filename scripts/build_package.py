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

EXEC_SUFFIXES = {".exe", ".dll", ".so", ".bat", ".cmd", ".sh"}


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


def deterministic_zip_info(full: Path, rel: str) -> zipfile.ZipInfo:
    zi = zipfile.ZipInfo(rel, date_time=(1980, 1, 1, 0, 0, 0))
    zi.compress_type = zipfile.ZIP_DEFLATED
    zi.create_system = 3  # Unix attributes, host-independent
    is_exec = full.suffix.lower() in EXEC_SUFFIXES or (full.parent.name == "bin" and full.suffix == "")
    mode = 0o100755 if is_exec else 0o100644
    zi.external_attr = mode << 16
    return zi


def dereference_symlinks(root_dir: Path) -> None:
    """Replace symlinks created by upstream POSIX tarballs with regular file copies."""
    stage_resolved = root_dir.resolve()
    symlinks: list[Path] = []
    for root, dirs, files in os.walk(root_dir, followlinks=False):
        for name in dirs + files:
            p = Path(root) / name
            if p.is_symlink():
                symlinks.append(p)
    for p in symlinks:
        if not p.is_symlink():
            continue
        real = p.resolve(strict=True)
        real.relative_to(stage_resolved)
        p.unlink()
        if real.is_dir():
            shutil.copytree(real, p, symlinks=False)
        else:
            shutil.copy2(real, p)


def build_package(
    work_dir: Path,
    out_zip: Path,
    manifest_path: Path,
    custom_overlay: Path | None = None,
    prune_picolibc: bool = True,
) -> None:
    work_dir.mkdir(parents=True, exist_ok=True)
    host_zip = ensure_asset(work_dir, ASSETS["windows_amd64"])
    multilib_txz = ensure_asset(work_dir, ASSETS["esp8266_multilib"])

    if custom_overlay is not None and not custom_overlay.is_file():
        raise FileNotFoundError(f"Custom overlay tarball not found: {custom_overlay}")

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
    dereference_symlinks(stage)

    if custom_overlay is not None:
        print(f"Overlaying {custom_overlay.name}...")
        stage_resolved = stage.resolve()
        with tarfile.open(custom_overlay, "r:xz") as tf:
            for member in tf.getmembers():
                if member.issym() or member.islnk():
                    raise RuntimeError(f"Unexpected link in custom overlay: {member.name}")
                if member.isfile():
                    target = stage / member.name
                    target.resolve().relative_to(stage_resolved)
                    if target.is_symlink() or target.is_file():
                        target.unlink()
                tf.extract(member, stage, filter="tar")

    tc_root = stage / "xtensa-esp-elf"
    if not tc_root.is_dir():
        raise RuntimeError(f"Expected {tc_root} inside extracted toolchain")

    if prune_picolibc:
        picolibc_dir = tc_root / "picolibc"
        if picolibc_dir.exists():
            print(f"Pruning unused {picolibc_dir.name}/...")
            shutil.rmtree(picolibc_dir)

    shutil.copy2(manifest_path, tc_root / "package.json")

    out_zip.parent.mkdir(parents=True, exist_ok=True)
    print(f"Packing PlatformIO archive -> {out_zip}...")
    with zipfile.ZipFile(out_zip, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as zout:
        for root, dirs, files in os.walk(tc_root):
            dirs.sort()
            for fname in sorted(files):
                full = Path(root) / fname
                if full.is_symlink():
                    raise RuntimeError(f"Unexpected symlink in package staging tree: {full}")
                rel = full.relative_to(tc_root).as_posix()
                zi = deterministic_zip_info(full, rel)
                with zout.open(zi, "w") as dst, full.open("rb") as src:
                    shutil.copyfileobj(src, dst, 1024 * 1024)

    out_sha = sha256_file(out_zip)
    sha_file = out_zip.with_suffix(out_zip.suffix + ".sha256")
    sha_file.write_text(f"{out_sha.lower()}  {out_zip.name}\n", encoding="utf-8")
    print(f"Done: {out_zip} ({out_zip.stat().st_size:,} bytes), SHA256={out_sha.lower()}")


def main() -> None:
    repo_root = Path(__file__).resolve().parent.parent
    manifest_path = repo_root / "package.json"
    pkg_version = json.loads(manifest_path.read_text(encoding="utf-8"))["version"]

    parser = argparse.ArgumentParser(description="Build toolchain-xtensa-esp8266 PlatformIO package")
    parser.add_argument("--work-dir", default=str(repo_root / "build"))
    parser.add_argument(
        "--out",
        default=str(repo_root / "build" / f"toolchain-xtensa-esp8266-windows_amd64-{pkg_version}.zip"),
    )
    parser.add_argument(
        "--custom-overlay",
        default=None,
        help="Path to esp8266-custom-multilib.tar.xz overlay tarball",
    )
    parser.add_argument(
        "--prune-picolibc",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Remove unused picolibc/ directory before packing (default: enabled)",
    )
    args = parser.parse_args()
    build_package(
        Path(args.work_dir),
        Path(args.out),
        manifest_path,
        custom_overlay=Path(args.custom_overlay) if args.custom_overlay else None,
        prune_picolibc=args.prune_picolibc,
    )


if __name__ == "__main__":
    main()
