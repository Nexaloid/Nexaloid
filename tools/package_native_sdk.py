from __future__ import annotations

import argparse
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def native_libs() -> list[Path]:
    if sys.platform == "win32":
        return [
            ROOT / "core" / "zig-out" / "bin" / "nexaloid.dll",
            ROOT / "core" / "zig-out" / "lib" / "nexaloid.lib",
        ]
    if sys.platform == "darwin":
        return [ROOT / "core" / "zig-out" / "lib" / "libnexaloid.dylib"]
    return [ROOT / "core" / "zig-out" / "lib" / "libnexaloid.so"]


def copy(src: Path, dst: Path) -> None:
    if not src.exists():
        raise FileNotFoundError(src)
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)


def zip_dir(src: Path, out: Path) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(out, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(src.rglob("*")):
            if path.is_file():
                archive.write(path, path.relative_to(src.parent).as_posix())


def package(version: str, platform: str, out_dir: Path) -> Path:
    name = f"nexaloid-{version}-{platform}"
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / name
        copy(ROOT / "LICENSE", root / "LICENSE")
        copy(ROOT / "README.md", root / "README.md")
        copy(ROOT / "core" / "include" / "nexaloid.h", root / "include" / "nexaloid.h")
        copy(ROOT / "core" / "include" / "nexaloid_plugin.h", root / "include" / "nexaloid_plugin.h")
        copy(ROOT / "bindings" / "cpp" / "include" / "nexaloid.hpp", root / "include" / "nexaloid.hpp")
        copy(ROOT / "data" / "dict" / "nexaloid.nxdict", root / "data" / "dict" / "nexaloid.nxdict")
        for lib in native_libs():
            copy(lib, root / "lib" / lib.name)

        out = out_dir / f"{name}.zip"
        zip_dir(root, out)
        return out


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--platform", required=True)
    parser.add_argument("--out-dir", type=Path, default=ROOT / "dist" / "native")
    args = parser.parse_args()

    version = args.version.removeprefix("v")
    out = package(version, args.platform, args.out_dir)
    print(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
