from __future__ import annotations

import argparse
import shutil
import tempfile
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def native_libs(platform: str) -> list[Path]:
    if platform.startswith("windows-"):
        names = ("nexaloid.dll", "nexaloid.lib", "libnexaloid.dll.a")
    elif platform.startswith("darwin-"):
        names = ("libnexaloid.dylib",)
    else:
        names = ("libnexaloid.so",)

    libs = [path for name in names for path in (ROOT / "core" / "zig-out").rglob(name)]
    if not libs:
        raise FileNotFoundError(f"native library for {platform} under core/zig-out")
    return libs


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


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def package_name(version: str, platform: str, language: str) -> str:
    if language == "all":
        return f"nexaloid-{version}-{platform}"
    return f"nexaloid-{language}-{version}-{platform}"


def copy_language_files(language: str, root: Path) -> None:
    if language in ("all", "c", "cpp", "zig"):
        copy(ROOT / "core" / "include" / "nexaloid.h", root / "include" / "nexaloid.h")
        copy(ROOT / "core" / "include" / "nexaloid_plugin.h", root / "include" / "nexaloid_plugin.h")

    if language in ("all", "c"):
        copy(ROOT / "bindings" / "c" / "tests" / "regression.c", root / "examples" / "c" / "regression.c")

    if language in ("all", "cpp"):
        copy(ROOT / "bindings" / "cpp" / "include" / "nexaloid.hpp", root / "include" / "nexaloid.hpp")
        copy(ROOT / "bindings" / "cpp" / "tests" / "regression.cpp", root / "examples" / "cpp" / "regression.cpp")

    if language in ("all", "zig"):
        copy(ROOT / "bindings" / "zig" / "tests" / "regression.zig", root / "examples" / "zig" / "regression.zig")


def write_package_readme(root: Path, version: str, platform: str, language: str) -> None:
    if language == "all":
        title = "Nexaloid Native SDK"
        body = "This package contains the C ABI, C++ header wrapper, Zig example, native library, and bundled NXDICT dictionary."
    else:
        title = f"Nexaloid {language.upper()} SDK"
        body = f"This package contains the Nexaloid {language.upper()} entry files, native library, and bundled NXDICT dictionary."

    write_text(
        root / "README.md",
        f"""# {title}

Version: {version}
Platform: {platform}

{body}

## Layout

- `include/`: public C ABI headers and optional C++ wrapper
- `lib/`: platform native library files
- `data/dict/nexaloid.nxdict`: bundled dictionary
- `examples/`: language regression examples

Set the runtime library path to `lib/` before running examples.
""",
    )


def package(version: str, platform: str, out_dir: Path, language: str) -> Path:
    name = package_name(version, platform, language)
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / name
        copy(ROOT / "LICENSE", root / "LICENSE")
        write_package_readme(root, version, platform, language)
        copy_language_files(language, root)
        copy(ROOT / "data" / "dict" / "nexaloid.nxdict", root / "data" / "dict" / "nexaloid.nxdict")
        for lib in native_libs(platform):
            copy(lib, root / "lib" / lib.name)

        out = out_dir / f"{name}.zip"
        zip_dir(root, out)
        return out


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--platform", required=True)
    parser.add_argument("--language", choices=["all", "c", "cpp", "zig"], default="all")
    parser.add_argument("--out-dir", type=Path, default=ROOT / "dist" / "native")
    args = parser.parse_args()

    version = args.version.removeprefix("v")
    out = package(version, args.platform, args.out_dir, args.language)
    print(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
