from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

from platform_tag import platform_tag


ROOT = Path(__file__).resolve().parents[1]
PLUGIN_SOURCES = {
    "hmm_lattice": ROOT / "tools" / "hmm_lattice_plugin.zig",
    "entity_bmes": ROOT / "tools" / "entity_bmes_plugin.zig",
}


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
        "bmes_hmm_wordhub_lattice.nxhmm",
        "bmes_hmm_wordhub_lattice.nxhmm.sha256",
        "bmes_hmm_wordhub_lattice.manifest.json",
    ):
        copy_file(src / name, dst / name)


def copy_entity(dst: Path) -> None:
    src = ROOT / "data" / "entity"
    dst.mkdir(parents=True, exist_ok=True)
    for name in (
        "entity_bmes_perceptron.nxbmes",
        "entity_bmes_perceptron.nxbmes.sha256",
        "entity_bmes_perceptron.manifest.json",
        "APACHE-2.0.txt",
        "MODEL_LICENSE.txt",
        "THIRD_PARTY_NOTICES.txt",
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


def plugin_filename(stem: str, target_platform: str) -> str:
    base = f"nexaloid_plugin_{stem}"
    if target_platform.startswith("windows-"):
        return f"{base}.dll"
    if target_platform.startswith("darwin-"):
        return f"{base}.dylib"
    return f"{base}.so"


def plugin_libs(target_platform: str | None = None) -> list[Path]:
    target_platform = target_platform or platform_tag()
    out = []
    for stem in PLUGIN_SOURCES:
        matches = list((ROOT / "core/zig-out").rglob(plugin_filename(stem, target_platform)))
        if matches:
            out.append(matches[0])
    return out


def ensure_plugin_libs(
    target_platform: str | None = None,
    zig_target: str | None = None,
) -> list[Path]:
    target_platform = target_platform or platform_tag()
    out_dir = ROOT / "core" / "zig-out" / "lib"
    out_dir.mkdir(parents=True, exist_ok=True)
    for stem, source in PLUGIN_SOURCES.items():
        name = plugin_filename(stem, target_platform)
        if zig_target is None and any((ROOT / "core/zig-out").rglob(name)):
            continue
        command = [
            "zig",
            "build-lib",
            "-O",
            "ReleaseFast",
            "-mcpu",
            "baseline",
            "-dynamic",
            "-lc",
            "--name",
            f"nexaloid_plugin_{stem}",
        ]
        if zig_target is not None:
            command.extend(("-target", zig_target))
        command.append(str(source))
        subprocess.run(command, cwd=ROOT, check=True)
        emitted = ROOT / (name if target_platform.startswith("windows-") else f"lib{name}")
        copy_file(emitted, out_dir / name)
    libs = plugin_libs(target_platform)
    if len(libs) != len(PLUGIN_SOURCES):
        raise FileNotFoundError("not all plugin libraries were built")
    return libs


def stage_python() -> None:
    pkg = ROOT / "bindings/python/src/nexaloid"
    copy_dict(pkg / "data/dict")
    copy_hmm(pkg / "data/hmm")
    copy_entity(pkg / "data/entity")
    for src in core_libs():
        if src.suffix != ".lib":
            copy_file(src, pkg / "native" / src.name)
    for src in ensure_plugin_libs():
        copy_file(src, pkg / "native" / src.name)


def stage_rust_data() -> None:
    copy_file(ROOT / "data/dict/nexaloid.nxdict", ROOT / "bindings/rust/nexaloid-sys/data/dict/nexaloid.nxdict")
    copy_hmm(ROOT / "bindings/rust/nexaloid-sys/data/hmm")
    copy_entity(ROOT / "bindings/rust/nexaloid/data/entity")


def stage_rust(
    target_platform: str | None = None,
    zig_target: str | None = None,
) -> None:
    stage_rust_data()
    target_platform = target_platform or platform_tag()
    native_dirs = (
        ROOT / "bindings/rust/nexaloid-sys/native" / target_platform,
        ROOT / "bindings" / "rust" / f"nexaloid-sys-{target_platform}" / "native",
    )
    runtime_libs = core_libs(target_platform) + ensure_plugin_libs(
        target_platform, zig_target
    )
    for native in native_dirs:
        for src in runtime_libs:
            copy_file(src, native / src.name)


def stage_rust_platform_crate(target_platform: str, zig_target: str | None = None) -> None:
    stage_rust_data()
    native = ROOT / "bindings" / "rust" / f"nexaloid-sys-{target_platform}" / "native"
    for src in core_libs(target_platform):
        copy_file(src, native / src.name)
    for src in ensure_plugin_libs(target_platform, zig_target):
        copy_file(src, native / src.name)


def stage_node(include_addon: bool) -> None:
    pkg = ROOT / "bindings/node"
    copy_dict(pkg / "data/dict")
    copy_hmm(pkg / "data/hmm")
    copy_entity(pkg / "data/entity")
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
    parser.add_argument("--zig-target")
    parser.add_argument("--rust-only", action="store_true")
    parser.add_argument("--rust-platform-crate", action="store_true")
    args = parser.parse_args()
    if args.rust_platform_crate:
        if args.platform is None:
            raise SystemExit("--rust-platform-crate requires --platform")
        stage_rust_platform_crate(args.platform, args.zig_target)
        return
    if args.rust_only:
        stage_rust(args.platform, args.zig_target)
        return
    stage_python()
    stage_rust(args.platform, args.zig_target)
    stage_node(args.node_addon)


if __name__ == "__main__":
    main()
