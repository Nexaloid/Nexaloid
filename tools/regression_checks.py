from __future__ import annotations

import os
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
if str(ROOT / "tools") not in sys.path:
    sys.path.insert(0, str(ROOT / "tools"))

from nexaloid import Tokenizer  # noqa: E402
from nexaloid.tokenizer import NexaloidError  # noqa: E402
from nxdict_builder import build as build_nxdict  # noqa: E402


def expect_error(fn, text: str) -> None:
    try:
        fn()
    except Exception as exc:
        if text in str(exc):
            return
        raise AssertionError(f"expected {text!r}, got {exc!r}") from exc
    raise AssertionError(f"expected error containing {text!r}")


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
            assert tokenizer.lcut("火星基地") == ["火星基地"]
        finally:
            tokenizer.close()


def main() -> int:
    os.environ.setdefault("PYTHONUTF8", "1")
    check_python_close_guard()
    check_invalid_mode()
    check_nxdict_userdict()
    print("regression checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
