from __future__ import annotations

import os
import json
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


def hmm_plugin_name() -> str:
    if sys.platform == "win32":
        return "nexaloid_plugin_hmm_lattice.dll"
    if sys.platform == "darwin":
        return "nexaloid_plugin_hmm_lattice.dylib"
    return "nexaloid_plugin_hmm_lattice.so"


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


def build_hmm_plugin(out_path: Path) -> None:
    subprocess.run(
        [
            "zig",
            "build-lib",
            "-dynamic",
            "-lc",
            f"-femit-bin={out_path}",
            str(ROOT / "tools" / "hmm_lattice_plugin.zig"),
        ],
        check=True,
    )


def assert_plugin_tokenizer(tokenizer: Tokenizer) -> None:
    tokens = tokenizer.tokenize("火星基地")
    assert [(token.text, token.source) for token in tokens] == [("火星基地", "plugin")]


def assert_hmm_plugin_tokenizer(plugin_path: Path) -> None:
    artifact_path = ROOT / "data" / "hmm" / "bmes_hmm_wordhub_lattice.nxhmm"
    tokenizer = Tokenizer(dict_path=plugin_path.parent / "missing.tsv")
    try:
        tokenizer.load_plugin(plugin_path, str(artifact_path))
        assert [token.text for token in tokenizer.tokenize("小明硕士毕业")] == ["小明", "硕士", "毕业"]
        assert [token.text for token in tokenizer.tokenize("阿明硕士毕业")] == ["阿明", "硕士", "毕业"]
        assert [token.text for token in tokenizer.tokenize("服用二甲双胍500mg")] == ["服用", "二甲双胍", "500mg"]
    finally:
        tokenizer.close()

    tokenizer = Tokenizer()
    try:
        tokenizer.load_plugin(plugin_path, str(artifact_path))
        assert [token.text for token in tokenizer.tokenize("并参与杭算项目")] == ["并", "参与", "杭算", "项目"]
    finally:
        tokenizer.close()

    tokenizer = Tokenizer()
    try:
        tokenizer.load_plugin(plugin_path, json.dumps({"artifact": str(artifact_path), "hmm_score": -20.0}))
        assert [token.text for token in tokenizer.tokenize("并参与杭算项目")] == ["并", "参与", "杭", "算", "项目"]
    finally:
        tokenizer.close()


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

        hmm_plugin_path = tmp_path / hmm_plugin_name()
        build_hmm_plugin(hmm_plugin_path)
        assert_hmm_plugin_tokenizer(hmm_plugin_path)

    print("plugin integration checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
