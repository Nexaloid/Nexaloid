from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
if sys.platform == "win32":
    os.environ.setdefault("NEXALOID_LIB", str(ROOT / "core" / "zig-out" / "bin" / "nexaloid.dll"))
elif sys.platform == "darwin":
    os.environ.setdefault("NEXALOID_LIB", str(ROOT / "core" / "zig-out" / "lib" / "libnexaloid.dylib"))
else:
    os.environ.setdefault("NEXALOID_LIB", str(ROOT / "core" / "zig-out" / "lib" / "libnexaloid.so"))

PY_SRC = ROOT / "bindings" / "python" / "src"
if str(PY_SRC) not in sys.path:
    sys.path.insert(0, str(PY_SRC))

from nexaloid import Tokenizer  # noqa: E402


def plugin_name() -> str:
    if sys.platform == "win32":
        return "nexaloid_plugin_demo_candidate.dll"
    if sys.platform == "darwin":
        return "nexaloid_plugin_demo_candidate.dylib"
    return "nexaloid_plugin_demo_candidate.so"


def build_plugin(out_path: Path) -> None:
    subprocess.run(
        [
            "zig",
            "cc",
            "-shared",
            "-I",
            str(ROOT / "core" / "include"),
            "-o",
            str(out_path),
            str(ROOT / "tools" / "demo_candidate_plugin.c"),
        ],
        check=True,
    )


def assert_plugin_tokenizer(tokenizer: Tokenizer) -> None:
    tokens = tokenizer.tokenize("火星基地")
    assert [(token.text, token.source) for token in tokens] == [("火星基地", "plugin")]


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        plugin_path = tmp_path / plugin_name()
        build_plugin(plugin_path)

        tokenizer = Tokenizer(dict_path=tmp_path / "missing.tsv")
        try:
            tokenizer.load_plugin(plugin_path)
            assert_plugin_tokenizer(tokenizer)
        finally:
            tokenizer.close()

        tokenizer = Tokenizer(dict_path=tmp_path / "missing.tsv", plugin_dir=tmp_path)
        try:
            assert_plugin_tokenizer(tokenizer)
        finally:
            tokenizer.close()

        tokenizer = Tokenizer(dict_path=tmp_path / "missing.tsv")
        try:
            tokenizer.load_plugins(tmp_path)
            assert_plugin_tokenizer(tokenizer)
        finally:
            tokenizer.close()

    print("plugin integration checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
