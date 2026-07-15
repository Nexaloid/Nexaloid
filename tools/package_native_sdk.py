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


def plugin_lib_names(platform: str) -> tuple[str, str]:
    if platform.startswith("windows-"):
        suffix = ".dll"
    elif platform.startswith("darwin-"):
        suffix = ".dylib"
    else:
        suffix = ".so"
    return tuple(f"nexaloid_plugin_{stem}{suffix}" for stem in ("hmm_lattice", "entity_bmes"))


def native_plugins(platform: str) -> list[Path]:
    out = []
    for name in plugin_lib_names(platform):
        matches = list((ROOT / "core" / "zig-out").rglob(name))
        if matches:
            out.append(matches[0])
    return out


def copy(src: Path, dst: Path) -> None:
    if not src.exists():
        raise FileNotFoundError(src)
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)


def copy_hmm(root: Path) -> None:
    src = ROOT / "data" / "hmm"
    for name in (
        "bmes_hmm_wordhub_lattice.nxhmm",
        "bmes_hmm_wordhub_lattice.nxhmm.sha256",
        "bmes_hmm_wordhub_lattice.manifest.json",
    ):
        copy(src / name, root / "data" / "hmm" / name)


def copy_entity(root: Path) -> None:
    src = ROOT / "data" / "entity"
    for name in (
        "entity_bmes_perceptron.nxbmes",
        "entity_bmes_perceptron.nxbmes.sha256",
        "entity_bmes_perceptron.manifest.json",
        "APACHE-2.0.txt",
        "MODEL_LICENSE.txt",
        "THIRD_PARTY_NOTICES.txt",
    ):
        copy(src / name, root / "data" / "entity" / name)


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

    if language in ("all", "c", "cpp", "zig"):
        copy(ROOT / "tools" / "hmm_lattice_plugin.zig", root / "plugins" / "hmm_lattice_plugin.zig")
        copy(ROOT / "tools" / "entity_bmes_plugin.zig", root / "plugins" / "entity_bmes_plugin.zig")


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

## Token Contract

Search preserves every non-whitespace token on the Accurate path, including single-character and repeated-position tokens, and adds in-boundary Han 2-gram / 3-gram expansions. RecallSearch also adds explicit lattice candidates.

`NxToken.source` identifies the token origin. For rule tokens, a nonzero `flags` value is the custom rule's 1-based JSON array index. Plugin tokens use `flags` for plugin-defined subtypes.

## Layout

- `include/`: public C ABI headers and optional C++ wrapper
- `lib/`: platform native library files
- `data/dict/nexaloid.nxdict`: bundled dictionary
- `data/hmm/`: optional BMES HMM lattice artifact and manifest
- `data/entity/`: bundled release-safe entity BMES artifact, manifest, and notices
- `plugins/hmm_lattice_plugin.zig`: optional BMES HMM CandidateProvider plugin source
- `plugins/entity_bmes_plugin.zig`: optional entity BMES CandidateProvider plugin source
- `examples/`: language regression examples

Set the runtime library path to `lib/` before running examples.
If `lib/` contains `nexaloid_plugin_hmm_lattice.*`, load it with `data/hmm/bmes_hmm_wordhub_lattice.nxhmm` as the plugin config path.
For score calibration, pass JSON such as `{{"artifact":"data/hmm/bmes_hmm_wordhub_lattice.nxhmm","hmm_score":-14.0}}`.
Load `lib/nexaloid_plugin_entity_bmes.*` and pass `data/entity/entity_bmes_perceptron.nxbmes` as its config path.
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
        copy_hmm(root)
        copy_entity(root)
        for lib in native_libs(platform):
            copy(lib, root / "lib" / lib.name)
        for plugin in native_plugins(platform):
            copy(plugin, root / "lib" / plugin.name)

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
