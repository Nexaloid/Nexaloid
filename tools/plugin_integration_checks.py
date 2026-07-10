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


def entity_plugin_name() -> str:
    if sys.platform == "win32":
        return "nexaloid_plugin_entity_bmes.dll"
    if sys.platform == "darwin":
        return "nexaloid_plugin_entity_bmes.dylib"
    return "nexaloid_plugin_entity_bmes.so"


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


def build_entity_plugin(out_path: Path) -> None:
    subprocess.run(
        [
            "zig",
            "build-lib",
            "-dynamic",
            "-lc",
            f"-femit-bin={out_path}",
            str(ROOT / "tools" / "entity_bmes_plugin.zig"),
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


def assert_entity_plugin_tokenizer(plugin_path: Path, artifact_path: Path) -> None:
    tokenizer = Tokenizer(dict_path=plugin_path.parent / "missing.tsv")
    try:
        tokenizer.load_plugin(plugin_path, json.dumps({"artifact": str(artifact_path)}))
        for text, expected in (
            ("患者服用阿司匹林治疗冠心病。", "阿司匹林"),
            ("苹果公司发布iPhone 16 Pro", "iPhone 16 Pro"),
            ("该系统采用Transformer和CUDA加速。", "Transformer"),
        ):
            entities = [
                token.text
                for token in tokenizer.tokenize(text)
                if token.source == "plugin" and token.flags == 4
            ]
            assert expected in entities, (text, entities)
    finally:
        tokenizer.close()


def assert_entity_hmm_coexist(
    entity_plugin_path: Path,
    entity_artifact_path: Path,
    hmm_plugin_path: Path,
) -> None:
    tokenizer = Tokenizer(dict_path=entity_plugin_path.parent / "missing.tsv")
    try:
        tokenizer.load_plugin(
            hmm_plugin_path,
            str(ROOT / "data" / "hmm" / "bmes_hmm_wordhub_lattice.nxhmm"),
        )
        tokenizer.load_plugin(entity_plugin_path, str(entity_artifact_path))
        tokens = tokenizer.tokenize("苹果公司发布iPhone 16 Pro")
        assert ("苹果", "plugin", 1) in [
            (token.text, token.source, token.flags) for token in tokens
        ]
        assert ("iPhone 16 Pro", "plugin", 4) in [
            (token.text, token.source, token.flags) for token in tokens
        ]
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

        entity_plugin_path = tmp_path / entity_plugin_name()
        build_entity_plugin(entity_plugin_path)
        entity_artifact = Path(
            os.environ.get(
                "NEXALOID_ENTITY_BMES_ARTIFACT",
                ROOT / "data" / "entity" / "entity_bmes_perceptron.nxbmes",
            )
        )
        if entity_artifact.exists():
            assert_entity_plugin_tokenizer(entity_plugin_path, entity_artifact)
            assert_entity_hmm_coexist(entity_plugin_path, entity_artifact, hmm_plugin_path)
        else:
            print("entity BMES artifact not present; inference checks skipped")

    print("plugin integration checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
