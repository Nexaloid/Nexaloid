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


def core_libs() -> list[Path]:
    if sys.platform == "win32":
        return [ROOT / "core/zig-out/bin/nexaloid.dll", ROOT / "core/zig-out/lib/nexaloid.lib"]
    if sys.platform == "darwin":
        return [ROOT / "core/zig-out/lib/libnexaloid.dylib"]
    return [ROOT / "core/zig-out/lib/libnexaloid.so"]


def stage_python() -> None:
    pkg = ROOT / "bindings/python/src/nexaloid"
    copy_dict(pkg / "data/dict")
    for src in core_libs():
        if src.suffix != ".lib":
            copy_file(src, pkg / "native" / src.name)


def stage_rust() -> None:
    copy_file(ROOT / "data/dict/nexaloid.nxdict", ROOT / "bindings/rust/nexaloid-sys/data/dict/nexaloid.nxdict")
    native = ROOT / "bindings/rust/nexaloid-sys/native" / platform_tag()
    for src in core_libs():
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
    args = parser.parse_args()
    stage_python()
    stage_rust()
    stage_node(args.node_addon)


if __name__ == "__main__":
    main()
