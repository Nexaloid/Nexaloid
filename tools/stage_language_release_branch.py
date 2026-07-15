from __future__ import annotations

import argparse
import shutil
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def copy(src: Path, dst: Path) -> None:
    if not src.exists():
        raise FileNotFoundError(src)
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def copy_hmm(out_dir: Path) -> None:
    src = ROOT / "data" / "hmm"
    for name in (
        "bmes_hmm_wordhub_lattice.nxhmm",
        "bmes_hmm_wordhub_lattice.nxhmm.sha256",
        "bmes_hmm_wordhub_lattice.manifest.json",
    ):
        copy(src / name, out_dir / "data" / "hmm" / name)


def copy_entity(out_dir: Path) -> None:
    src = ROOT / "data" / "entity"
    for name in (
        "entity_bmes_perceptron.nxbmes",
        "entity_bmes_perceptron.nxbmes.sha256",
        "entity_bmes_perceptron.manifest.json",
        "APACHE-2.0.txt",
        "MODEL_LICENSE.txt",
        "THIRD_PARTY_NOTICES.txt",
    ):
        copy(src / name, out_dir / "data" / "entity" / name)


def stage(language: str, version: str, out_dir: Path) -> None:
    if out_dir.exists():
        shutil.rmtree(out_dir)
    out_dir.mkdir(parents=True)

    copy(ROOT / "LICENSE", out_dir / "LICENSE")
    copy(ROOT / "core" / "include" / "nexaloid.h", out_dir / "include" / "nexaloid.h")
    copy(ROOT / "core" / "include" / "nexaloid_plugin.h", out_dir / "include" / "nexaloid_plugin.h")
    copy(ROOT / "data" / "dict" / "nexaloid.nxdict", out_dir / "data" / "dict" / "nexaloid.nxdict")
    copy_hmm(out_dir)
    copy_entity(out_dir)
    copy(ROOT / "tools" / "hmm_lattice_plugin.zig", out_dir / "plugins" / "hmm_lattice_plugin.zig")
    copy(ROOT / "tools" / "entity_bmes_plugin.zig", out_dir / "plugins" / "entity_bmes_plugin.zig")

    if language == "c":
        copy(ROOT / "bindings" / "c" / "tests" / "regression.c", out_dir / "examples" / "regression.c")
        command = "cc -std=c11 -Iinclude examples/regression.c -Llib -lnexaloid -o regression"
    elif language == "cpp":
        copy(ROOT / "bindings" / "cpp" / "include" / "nexaloid.hpp", out_dir / "include" / "nexaloid.hpp")
        copy(ROOT / "bindings" / "cpp" / "tests" / "regression.cpp", out_dir / "examples" / "regression.cpp")
        command = "c++ -std=c++17 -Iinclude examples/regression.cpp -Llib -lnexaloid -o regression"
    elif language == "zig":
        copy(ROOT / "bindings" / "zig" / "tests" / "regression.zig", out_dir / "examples" / "regression.zig")
        command = "zig build-exe examples/regression.zig -Iinclude -Llib -lnexaloid -lc"
    else:
        raise ValueError(language)

    write_text(
        out_dir / "README.md",
        f"""# Nexaloid {language.upper()} Release Branch

This branch tracks the latest released Nexaloid {language.upper()} entry files.

Version: {version.removeprefix("v")}

## Use

Download the matching `nexaloid-{language}-<version>-<platform>.zip` asset from the GitHub Release for native libraries, or copy its `lib/` directory into this checkout.

```sh
{command}
```

The dictionary is bundled at `data/dict/nexaloid.nxdict`.

## Token Contract

Search preserves every non-whitespace token on the Accurate path, including single-character and repeated-position tokens, and adds in-boundary Han 2-gram / 3-gram expansions. RecallSearch also adds explicit lattice candidates.

`NxToken.source` identifies the token origin. For rule tokens, a nonzero `flags` value is the custom rule's 1-based JSON array index. Plugin tokens use `flags` for plugin-defined subtypes.

The optional BMES HMM lattice artifact is bundled at `data/hmm/bmes_hmm_wordhub_lattice.nxhmm`.
The optional HMM CandidateProvider plugin source is bundled at `plugins/hmm_lattice_plugin.zig`.
The entity CandidateProvider plugin source is bundled at `plugins/entity_bmes_plugin.zig`.
Matching release assets include prebuilt `lib/nexaloid_plugin_hmm_lattice.*` and
`lib/nexaloid_plugin_entity_bmes.*` libraries when available.
Use the artifact path directly as plugin config, or pass JSON like `{{"artifact":"data/hmm/bmes_hmm_wordhub_lattice.nxhmm","hmm_score":-14.0}}` to calibrate HMM candidate weight.
The release-safe entity model is bundled at `data/entity/entity_bmes_perceptron.nxbmes`.
""",
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--language", choices=["c", "cpp", "zig"], required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    args = parser.parse_args()
    stage(args.language, args.version, args.out_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
