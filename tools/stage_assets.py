from __future__ import annotations

import argparse
import shutil
import subprocess
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


def stage_python() -> None:
    pkg = ROOT / "bindings/python/src/nexaloid"
    copy_dict(pkg / "data/dict")
    for src in core_libs():
        if src.suffix != ".lib":
            copy_file(src, pkg / "native" / src.name)


def stage_rust(target_platform: str | None = None) -> None:
    copy_file(ROOT / "data/dict/nexaloid.nxdict", ROOT / "bindings/rust/nexaloid-sys/data/dict/nexaloid.nxdict")
    native = ROOT / "bindings/rust/nexaloid-sys/native" / (target_platform or platform_tag())
    for src in core_libs(target_platform):
        copy_file(src, native / src.name)


def stage_node(include_addon: bool) -> None:
    pkg = ROOT / "bindings/node"
    copy_dict(pkg / "data/dict")
    prebuild = pkg / "prebuilds" / platform_tag()
    for src in core_libs():
        if src.suffix != ".lib":
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
    args = parser.parse_args()
    if args.rust_only:
        stage_rust(args.platform)
        return
    stage_python()
    stage_rust(args.platform)
    stage_node(args.node_addon)


if __name__ == "__main__":
    main()
