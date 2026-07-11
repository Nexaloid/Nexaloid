from __future__ import annotations

import os
import sys
import hashlib
import tempfile
from importlib import metadata
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
if str(ROOT / "tools") not in sys.path:
    sys.path.insert(0, str(ROOT / "tools"))

from nexaloid import Mode, Tokenizer  # noqa: E402
from nexaloid.tokenizer import _resolve_dict_path  # noqa: E402
from nexaloid.tokenizer import NexaloidError  # noqa: E402
from check_hmm_artifact import main as check_hmm_artifact_main  # noqa: E402
from hmm_score_audit import main as hmm_score_audit_main  # noqa: E402
from nxdict_builder import build as build_nxdict  # noqa: E402
from plugin_integration_checks import build_hmm_plugin, hmm_plugin_name, main as plugin_integration_main  # noqa: E402
from rule_audit import main as rule_audit_main  # noqa: E402


def expect_error(fn, text: str) -> None:
    try:
        fn()
    except Exception as exc:
        if text in str(exc):
            return
        raise AssertionError(f"expected {text!r}, got {exc!r}") from exc
    raise AssertionError(f"expected error containing {text!r}")


def assert_token_coverage(text: str, tokens) -> None:
    cursor = 0
    raw = text.encode("utf-8")
    for token in tokens:
        if token.start_byte < cursor:
            raise AssertionError(f"overlapping token at byte {token.start_byte}")
        if raw[cursor : token.start_byte].decode("utf-8").strip():
            raise AssertionError(f"uncovered span: {raw[cursor:token.start_byte]!r}")
        cursor = token.end_byte
    if raw[cursor:].decode("utf-8").strip():
        raise AssertionError(f"uncovered tail: {raw[cursor:]!r}")


def check_python_close_guard() -> None:
    tokenizer = Tokenizer()
    tokenizer.close()
    expect_error(lambda: tokenizer.tokenize("南京市长江大桥"), "closed")
    expect_error(lambda: tokenizer.add_word("测试"), "closed")
    expect_error(lambda: tokenizer.load_userdict("missing.tsv"), "closed")


def check_python_hmm_default_off() -> None:
    old_plugin = os.environ.get("NEXALOID_HMM_PLUGIN")
    os.environ["NEXALOID_HMM_PLUGIN"] = str(ROOT / "missing_hmm_plugin.so")
    tokenizer = Tokenizer()
    try:
        assert tokenizer.lcut("小明硕士毕业") == tokenizer.lcut("小明硕士毕业", HMM=False)
        assert "小明" not in list(tokenizer.cut_for_search("小明硕士毕业"))
    finally:
        tokenizer.close()
        if old_plugin is None:
            os.environ.pop("NEXALOID_HMM_PLUGIN", None)
        else:
            os.environ["NEXALOID_HMM_PLUGIN"] = old_plugin


def check_invalid_mode() -> None:
    tokenizer = Tokenizer()
    try:
        expect_error(lambda: tokenizer.tokenize("南京市长江大桥", 99), "invalid config")
    finally:
        tokenizer.close()


def check_nxdict_userdict() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        tsv = tmp_path / "user.tsv"
        nxdict = tmp_path / "user.nxdict"
        tsv.write_text("火星基地\t50\n", encoding="utf-8")
        build_nxdict(tsv, nxdict)

        tokenizer = Tokenizer(dict_path=tmp_path / "missing.tsv")
        try:
            tokenizer.load_userdict(nxdict)
            assert tokenizer.lcut("火星基地", HMM=False) == ["火星基地"]
        finally:
            tokenizer.close()


def check_del_word_falls_back() -> None:
    tokenizer = Tokenizer()
    try:
        tokenizer.add_word("火山知识库", freq=1000000)
        tokenizer.del_word("火山知识库")
        assert tokenizer.lcut("A火山知识库B", HMM=False) == ["A", "火山", "知识库", "B"]
    finally:
        tokenizer.close()


def check_del_word_base_falls_back() -> None:
    tokenizer = Tokenizer()
    try:
        tokenizer.del_word("火山")
        tokens = tokenizer.tokenize("A火山B")
        assert [token.text for token in tokens] == ["A", "火山", "B"]
        assert_token_coverage("A火山B", tokens)

        tokenizer.del_word("南京市")
        tokens = tokenizer.tokenize("A南京市B")
        assert [token.text for token in tokens] == ["A", "南京市", "B"]
        assert_token_coverage("A南京市B", tokens)
    finally:
        tokenizer.close()


def check_token_coverage() -> None:
    tokenizer = Tokenizer()
    try:
        text = "ChatGPT-5.5 支持中文RAG检索。"
        assert_token_coverage(text, tokenizer.tokenize(text))
    finally:
        tokenizer.close()


def check_traditional_mixed_text() -> None:
    tokenizer = Tokenizer()
    try:
        assert tokenizer.lcut("臺灣使用者登入後，系統會顯示後臺數據。", HMM=False) == [
            "臺灣",
            "使用者",
            "登入",
            "後",
            "，",
            "系統",
            "會",
            "顯示",
            "後臺",
            "數據",
            "。",
        ]
        assert tokenizer.lcut("我們在日本東京做RAG中文檢索實驗", HMM=False) == [
            "我們",
            "在",
            "日本",
            "東京",
            "做",
            "RAG",
            "中文",
            "檢索",
            "實驗",
        ]
        assert tokenizer.lcut("這款Type-C轉HDMI2.1線支援4K輸出", HMM=False) == [
            "這款",
            "Type-C",
            "轉",
            "HDMI2.1",
            "線",
            "支援",
            "4K",
            "輸出",
        ]
        assert tokenizer.lcut("中級人民法院審理合同糾紛案件", HMM=False) == [
            "中級人民法院",
            "審理",
            "合同",
            "糾紛案件",
        ]
        assert tokenizer.lcut("註冊會計師查看資產負債表", HMM=False) == [
            "註冊會計師",
            "查看",
            "資產負債表",
        ]
        assert tokenizer.lcut("患者服用二甲雙胍500mg後血糖下降", HMM=False) == [
            "患者",
            "服用",
            "二甲雙胍",
            "500mg",
            "後",
            "血糖",
            "下降",
        ]
    finally:
        tokenizer.close()


def check_python_rule_config() -> None:
    tokenizer = Tokenizer(
        rule_config={
            "ascii_term": False,
            "custom_rules": [
                {
                    "name": "stock",
                    "kind": "prefixed_number",
                    "prefixes": ["SH"],
                    "digits": {"min": 6, "max": 6},
                    "score": 80,
                }
            ],
        }
    )
    try:
        tokens = tokenizer.tokenize("foo_bar-123")
        assert all(token.source != "rule" for token in tokens)
        assert "foo_bar-123" not in [token.text for token in tokens]
        assert "SH600519" in tokenizer.lcut("买SH600519", HMM=False)
        tokenizer.clear_rules()
        assert "SH600519" not in tokenizer.lcut("买SH600519", HMM=False)
        tokenizer.load_rules_json(
            '{"version":1,"rules":[{"name":"sku","kind":"charset_span","charset":"A-Z0-9-_","min_len":4,"max_len":16,"score":60}]}'
        )
        assert "SKU-AB12" in tokenizer.lcut("买SKU-AB12", HMM=False)
    finally:
        tokenizer.close()


def check_search_vs_recall_search() -> None:
    tokenizer = Tokenizer()
    try:
        search = [token.text for token in tokenizer.tokenize("研究生命起源", Mode.SEARCH)]
        recall = [token.text for token in tokenizer.tokenize("研究生命起源", Mode.RECALL_SEARCH)]
        assert "研究生" not in search
        assert "究生" not in search
        assert "研究生" in recall
    finally:
        tokenizer.close()


def check_whitespace_option() -> None:
    text = "中文 English\t混排\n第二行"
    tokenizer = Tokenizer()
    try:
        assert [token.text for token in tokenizer.tokenize(text)] == ["中文", "English", "混排", "第二行"]
    finally:
        tokenizer.close()

    tokenizer = Tokenizer(preserve_whitespace=True)
    try:
        assert [token.text for token in tokenizer.tokenize(text)] == ["中文", " ", "English", "\t", "混排", "\n", "第二行"]
        assert [token.text for token in tokenizer.tokenize("中文\u3000English")] == ["中文", "\u3000", "English"]
    finally:
        tokenizer.close()


def check_version_exported() -> None:
    import nexaloid

    try:
        expected = metadata.version("nexaloid")
    except metadata.PackageNotFoundError:
        expected = "0.0.0.dev0"
    assert nexaloid.__version__ == expected


def check_repo_dict_preferred() -> None:
    assert _resolve_dict_path(None) == ROOT / "data" / "dict" / "nexaloid.nxdict"


def check_python_hmm_artifact_path() -> None:
    from nexaloid import hmm_artifact_path, hmm_manifest, hmm_manifest_path

    path = hmm_artifact_path()
    assert path == ROOT / "data" / "hmm" / "bmes_hmm_wordhub_lattice.nxhmm"
    assert path.exists()
    assert hmm_manifest_path() == ROOT / "data" / "hmm" / "bmes_hmm_wordhub_lattice.manifest.json"
    manifest = hmm_manifest()
    assert manifest["schema"] == "nexaloid.hmm_manifest.v1"
    assert manifest["quality"]["lattice_heldout"]["token_f1"] >= 0.98


def check_bundled_hmm_artifact() -> None:
    assert check_hmm_artifact_main() == 0


def check_python_entity_artifact_path() -> None:
    from nexaloid import (
        entity_artifact_path,
        entity_manifest,
        entity_manifest_path,
        entity_plugin_path,
    )

    assert entity_artifact_path() == ROOT / "data" / "entity" / "entity_bmes_perceptron.nxbmes"
    assert entity_manifest_path() == ROOT / "data" / "entity" / "entity_bmes_perceptron.manifest.json"
    manifest = entity_manifest()
    assert manifest["distribution"] == {"license_spdx": "Apache-2.0", "scope": "public"}
    assert manifest["quality"]["test"]["f1"] >= 0.86
    digest = hashlib.sha256(entity_artifact_path().read_bytes()).hexdigest()
    expected = entity_artifact_path().with_suffix(".nxbmes.sha256").read_text(encoding="utf-8").split()[0]
    assert digest == expected == manifest["artifact_sha256"]
    assert "Distribution: public" in (ROOT / "data" / "entity" / "MODEL_LICENSE.txt").read_text(encoding="utf-8")
    assert "Apache License" in (ROOT / "data" / "entity" / "APACHE-2.0.txt").read_text(encoding="utf-8")
    assert entity_plugin_path().name.startswith("nexaloid_plugin_entity_bmes")


def check_python_hmm_true_enabled() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        plugin_path = Path(tmp) / hmm_plugin_name()
        build_hmm_plugin(plugin_path)
        old_plugin = os.environ.get("NEXALOID_HMM_PLUGIN")
        os.environ["NEXALOID_HMM_PLUGIN"] = str(plugin_path)
        tokenizer = Tokenizer()
        try:
            assert tokenizer.lcut("南京市长江大桥") == ["南京市", "长江大桥"]
            assert tokenizer.lcut("小明硕士毕业", HMM=False) == ["小", "明", "硕士", "毕业"]
            assert tokenizer.lcut("小明硕士毕业", HMM=True) == ["小明", "硕士", "毕业"]
            assert list(tokenizer.cut_for_search("南京市长江大桥", HMM=True))[:2] == list(tokenizer.cut_for_search("南京市长江大桥", HMM=False))[:2]
            assert "小明" in list(tokenizer.cut_for_search("小明硕士毕业", HMM=True))
            assert "二甲双胍" in list(tokenizer.cut_for_search("患者服用二甲双胍500mg", HMM=True))
        finally:
            tokenizer.close()
            if old_plugin is None:
                os.environ.pop("NEXALOID_HMM_PLUGIN", None)
            else:
                os.environ["NEXALOID_HMM_PLUGIN"] = old_plugin


def check_rust_sys_hmm_artifact_synced() -> None:
    root_artifact = ROOT / "data" / "hmm" / "bmes_hmm_wordhub_lattice.nxhmm"
    rust_artifact = ROOT / "bindings" / "rust" / "nexaloid-sys" / "data" / "hmm" / root_artifact.name
    assert hashlib.sha256(root_artifact.read_bytes()).digest() == hashlib.sha256(rust_artifact.read_bytes()).digest()


def check_plugin_integration() -> None:
    assert plugin_integration_main() == 0


def check_hmm_score_audit() -> None:
    assert hmm_score_audit_main() == 0


def check_rule_audit() -> None:
    assert rule_audit_main() == 0


def main() -> int:
    os.environ.setdefault("PYTHONUTF8", "1")
    checks = [
        check_python_close_guard,
        check_python_hmm_default_off,
        check_invalid_mode,
        check_nxdict_userdict,
        check_del_word_falls_back,
        check_del_word_base_falls_back,
        check_token_coverage,
        check_traditional_mixed_text,
        check_python_rule_config,
        check_search_vs_recall_search,
        check_whitespace_option,
        check_version_exported,
        check_repo_dict_preferred,
        check_python_hmm_artifact_path,
        check_bundled_hmm_artifact,
        check_python_entity_artifact_path,
        check_python_hmm_true_enabled,
        check_rust_sys_hmm_artifact_synced,
        check_plugin_integration,
        check_hmm_score_audit,
        check_rule_audit,
    ]
    failed = 0
    for check in checks:
        try:
            check()
            print(f"PASS {check.__name__}")
        except Exception as exc:
            failed += 1
            print(f"FAIL {check.__name__}: {exc!r}")
    print(f"{len(checks) - failed}/{len(checks)} regression checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
