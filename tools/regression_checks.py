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

from nexaloid import Tokenizer  # noqa: E402
from nexaloid.tokenizer import _resolve_dict_path  # noqa: E402
from nexaloid.tokenizer import NexaloidError  # noqa: E402
from check_hmm_artifact import main as check_hmm_artifact_main  # noqa: E402
from hmm_score_audit import main as hmm_score_audit_main  # noqa: E402
from nxdict_builder import build as build_nxdict  # noqa: E402
from plugin_integration_checks import main as plugin_integration_main  # noqa: E402


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
    assert path == ROOT / "data" / "hmm" / "bmes_hmm_wordhub_lattice.json"
    assert path.exists()
    assert hmm_manifest_path() == ROOT / "data" / "hmm" / "bmes_hmm_wordhub_lattice.manifest.json"
    manifest = hmm_manifest()
    assert manifest["schema"] == "nexaloid.hmm_manifest.v1"
    assert manifest["quality"]["lattice_heldout"]["token_f1"] >= 0.98


def check_bundled_hmm_artifact() -> None:
    assert check_hmm_artifact_main() == 0


def check_python_hmm_true_enabled() -> None:
    tokenizer = Tokenizer()
    try:
        assert tokenizer.lcut("小明硕士毕业", HMM=False) == ["小", "明", "硕士", "毕业"]
        assert tokenizer.lcut("小明硕士毕业", HMM=True) == ["小明", "硕士", "毕业"]
    finally:
        tokenizer.close()


def check_rust_sys_hmm_artifact_synced() -> None:
    root_artifact = ROOT / "data" / "hmm" / "bmes_hmm_wordhub_lattice.json"
    rust_artifact = ROOT / "bindings" / "rust" / "nexaloid-sys" / "data" / "hmm" / root_artifact.name
    assert hashlib.sha256(root_artifact.read_bytes()).digest() == hashlib.sha256(rust_artifact.read_bytes()).digest()


def check_plugin_integration() -> None:
    assert plugin_integration_main() == 0


def check_hmm_score_audit() -> None:
    assert hmm_score_audit_main() == 0


def main() -> int:
    os.environ.setdefault("PYTHONUTF8", "1")
    checks = [
        check_python_close_guard,
        check_invalid_mode,
        check_nxdict_userdict,
        check_del_word_falls_back,
        check_del_word_base_falls_back,
        check_token_coverage,
        check_version_exported,
        check_repo_dict_preferred,
        check_python_hmm_artifact_path,
        check_bundled_hmm_artifact,
        check_python_hmm_true_enabled,
        check_rust_sys_hmm_artifact_synced,
        check_plugin_integration,
        check_hmm_score_audit,
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
