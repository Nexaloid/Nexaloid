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

from nexaloid import Mode, Tokenizer  # noqa: E402


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
            "-O",
            "ReleaseFast",
            "-mcpu",
            "baseline",
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
            "-O",
            "ReleaseFast",
            "-mcpu",
            "baseline",
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
        prefixed = tokenizer.tokenize("🙂A服用二甲双胍500mg")
        metformin = next(token for token in prefixed if token.text == "二甲双胍")
        assert (
            metformin.start_byte,
            metformin.end_byte,
            metformin.start_char,
            metformin.end_char,
        ) == (11, 23, 4, 8)
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
            ("团队计划前往云海数据研究院开展调研。", "云海数据研究院"),
            ("欧盟委员会发布公告。", "欧盟委员会"),
            ("韩国财政部公布数据。", "韩国财政部"),
            ("美国国务院发表声明。", "美国国务院"),
        ):
            entities = [
                token.text
                for token in tokenizer.tokenize(text)
                if token.source == "plugin" and token.flags == 4
            ]
            assert expected in entities, (text, entities)

        for text, rejected in (
            ("央行票据 支持财政部", "央行票据 支持财政部"),
            ("事关国民经济", "事关国民经济"),
            ("国家开发银行湖南省", "国家开发银行湖南省"),
            ("超卓航科：控股股东", "超卓航科：控股股东"),
            ("公司上涨实现季度增长", "公司上涨实现"),
        ):
            entities = [token for token in tokenizer.tokenize(text) if token.source == "plugin" and token.flags == 4]
            assert rejected not in {token.text for token in entities}, (text, entities)
            assert all(not any(boundary in token.text for boundary in " \t\r\n：，。；！？、《》") for token in entities)
            assert all(token.score <= 400.0 for token in entities)

        book_title = tokenizer.tokenize("《欧盟委员会》发布公告")
        assert "欧盟委员会" in {token.text for token in book_title if token.source == "plugin"}
        for word in ("公司", "上涨", "实现", "季度"):
            assert not [token for token in tokenizer.tokenize(word) if token.source == "plugin"], word
    finally:
        tokenizer.close()

    tokenizer = Tokenizer(dict_path=plugin_path.parent / "missing.tsv")
    try:
        tokenizer.load_plugin(
            plugin_path,
            json.dumps({"artifact": str(artifact_path), "min_margin": 1_000_000.0}),
        )
        assert not [token for token in tokenizer.tokenize("云海数据研究院") if token.source == "plugin"]
    finally:
        tokenizer.close()


def assert_user_dictionary_beats_entity_superspans(
    plugin_path: Path,
    artifact_path: Path,
    tmp_path: Path,
) -> None:
    user_dict = tmp_path / "entity-user-dict.tsv"
    words = ("国民经济", "控股股东", "股份有限公司", "开发银行", "财政部")
    user_dict.write_text("".join(f"{word}\t-5\tn\n" for word in words), encoding="utf-8")
    tokenizer = Tokenizer(dict_path=tmp_path / "missing.tsv")
    try:
        tokenizer.load_userdict(user_dict)
        tokenizer.load_plugin(plugin_path, json.dumps({"artifact": str(artifact_path)}))
        cases = (
            ("事关国民经济", "国民经济"),
            ("超卓航科：控股股东拟减持股份", "控股股东"),
            ("某股份有限公司发布公告", "股份有限公司"),
            ("国家开发银行湖南省分行", "开发银行"),
            ("央行票据 支持财政部", "财政部"),
        )
        for mode in (Mode.ACCURATE, Mode.SEARCH):
            for text, word in cases:
                start = text.index(word)
                spans = {(token.text, token.start_char, token.end_char) for token in tokenizer.tokenize(text, mode)}
                assert (word, start, start + len(word)) in spans, (mode, text, spans)
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
        tokens = tokenizer.tokenize("阿强加入云海数据研究院")
        assert ("加入", "plugin", 1) in [
            (token.text, token.source, token.flags) for token in tokens
        ]
        assert ("云海数据研究院", "plugin", 4) in [
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
            assert_user_dictionary_beats_entity_superspans(entity_plugin_path, entity_artifact, tmp_path)
            assert_entity_hmm_coexist(entity_plugin_path, entity_artifact, hmm_plugin_path)
        else:
            print("entity BMES artifact not present; inference checks skipped")

    print("plugin integration checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
