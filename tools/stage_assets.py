from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

from platform_tag import platform_tag


ROOT = Path(__file__).resolve().parents[1]


def copy_file(src: Path, dst: Path) -> None:
    if not src.exists():
        raise FileNotFoundError(src)
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)


def copy_dict(dst: Path) -> None:
    src = ROOT / "data" / "dict"
    dst.mkdir(parents=True, exist_ok=True)
    for name in ("nexaloid.tsv", "nexaloid.nxdict"):
        copy_file(src / name, dst / name)


def copy_hmm(dst: Path) -> None:
    src = ROOT / "data" / "hmm"
    dst.mkdir(parents=True, exist_ok=True)
    for name in (
        "bmes_hmm_wordhub_lattice.json",
        "bmes_hmm_wordhub_lattice.json.sha256",
        "bmes_hmm_wordhub_lattice.manifest.json",
    ):
        copy_file(src / name, dst / name)


def core_libs(target_platform: str | None = None) -> list[Path]:
    target_platform = target_platform or platform_tag()
    if target_platform.startswith("windows-"):
        names = ("nexaloid.dll", "nexaloid.lib", "libnexaloid.dll.a")
    elif target_platform.startswith("darwin-"):
        names = ("libnexaloid.dylib",)
    else:
        names = ("libnexaloid.so",)

    libs = [path for name in names for path in (ROOT / "core/zig-out").rglob(name)]
    if not libs:
        raise FileNotFoundError(f"native library for {target_platform} under core/zig-out")
    return libs


def plugin_libs(target_platform: str | None = None) -> list[Path]:
    target_platform = target_platform or platform_tag()
    if target_platform.startswith("windows-"):
        name = "nexaloid_plugin_hmm_lattice.dll"
    elif target_platform.startswith("darwin-"):
        name = "nexaloid_plugin_hmm_lattice.dylib"
    else:
        name = "nexaloid_plugin_hmm_lattice.so"
    return [path for path in (ROOT / "core/zig-out").rglob(name)]


def ensure_plugin_libs(target_platform: str | None = None) -> list[Path]:
    libs = plugin_libs(target_platform)
    if libs:
        return libs
    subprocess.run(
        ["zig", "build-lib", "-dynamic", "-lc", "--name", "nexaloid_plugin_hmm_lattice", "tools/hmm_lattice_plugin.zig"],
        cwd=ROOT,
        check=True,
    )
    out_dir = ROOT / "core" / "zig-out" / "lib"
    out_dir.mkdir(parents=True, exist_ok=True)
    target_platform = target_platform or platform_tag()
    if target_platform.startswith("windows-"):
        copy_file(ROOT / "nexaloid_plugin_hmm_lattice.dll", out_dir / "nexaloid_plugin_hmm_lattice.dll")
    elif target_platform.startswith("darwin-"):
        copy_file(ROOT / "libnexaloid_plugin_hmm_lattice.dylib", out_dir / "nexaloid_plugin_hmm_lattice.dylib")
    else:
        copy_file(ROOT / "libnexaloid_plugin_hmm_lattice.so", out_dir / "nexaloid_plugin_hmm_lattice.so")
    return plugin_libs(target_platform)


def stage_python() -> None:
    pkg = ROOT / "bindings/python/src/nexaloid"
    copy_dict(pkg / "data/dict")
    copy_hmm(pkg / "data/hmm")
    for src in core_libs():
        if src.suffix != ".lib":
            copy_file(src, pkg / "native" / src.name)
    for src in ensure_plugin_libs():
        copy_file(src, pkg / "native" / src.name)


def stage_rust(target_platform: str | None = None) -> None:
    copy_file(ROOT / "data/dict/nexaloid.nxdict", ROOT / "bindings/rust/nexaloid-sys/data/dict/nexaloid.nxdict")
    copy_hmm(ROOT / "bindings/rust/nexaloid-sys/data/hmm")
    native = ROOT / "bindings/rust/nexaloid-sys/native" / (target_platform or platform_tag())
    for src in core_libs(target_platform):
        copy_file(src, native / src.name)


def stage_rust_platform_crate(target_platform: str) -> None:
    native = ROOT / "bindings" / "rust" / f"nexaloid-sys-{target_platform}" / "native"
    for src in core_libs(target_platform):
        copy_file(src, native / src.name)


def stage_node(include_addon: bool) -> None:
    pkg = ROOT / "bindings/node"
    copy_dict(pkg / "data/dict")
    copy_hmm(pkg / "data/hmm")
    prebuild = pkg / "prebuilds" / platform_tag()
    for src in core_libs():
        if src.suffix != ".lib":
            copy_file(src, prebuild / src.name)
    for src in ensure_plugin_libs():
        copy_file(src, prebuild / src.name)
    if include_addon:
        addon = prebuild / "nexaloid_node.node"
        copy_file(pkg / "build/Release/nexaloid_node.node", addon)
        if sys.platform == "linux" and shutil.which("patchelf"):
            subprocess.run(["patchelf", "--set-rpath", "$ORIGIN", str(addon)], check=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--node-addon", action="store_true")
    parser.add_argument("--platform")
    parser.add_argument("--rust-only", action="store_true")
    parser.add_argument("--rust-platform-crate", action="store_true")
    args = parser.parse_args()
    if args.rust_platform_crate:
        if args.platform is None:
            raise SystemExit("--rust-platform-crate requires --platform")
        stage_rust_platform_crate(args.platform)
        return
    if args.rust_only:
        stage_rust(args.platform)
        return
    stage_python()
    stage_rust(args.platform)
    stage_node(args.node_addon)


if __name__ == "__main__":
    main()
