from __future__ import annotations

import json
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
from plugin_integration_checks import build_hmm_plugin, hmm_plugin_name  # noqa: E402


CASES = [
    ("阿明硕士毕业", ["阿明", "硕士", "毕业"]),
    ("晓红硕士毕业", ["晓红", "硕士", "毕业"]),
    ("并参与杭算项目", ["并", "参与", "杭算", "项目"]),
    ("合同约定春节前发表讲话", ["合同", "约定", "春节前", "发表", "讲话"]),
    ("字符串优化知识库", ["字符串", "优化", "知识库"]),
    ("研究生命起源", ["研究", "生命", "起源"]),
    ("北京市海淀区中关村东路1号院8号楼B座", ["北京市", "海淀区", "中关村", "东路", "1", "号院", "8", "号楼", "B座"]),
    ("患者服用二甲双胍500mg", ["患者", "服用", "二甲双胍", "500mg"]),
]

CASE_FILE = ROOT / "data" / "hmm" / "hmm_score_audit.tsv"
SCORES = [-20.0, -16.0, -14.0, -12.0, -10.0, -8.0]
DEFAULT_SCORE = -14.0


def load_cases() -> list[tuple[str, list[str]]]:
    cases = list(CASES)
    if not CASE_FILE.exists():
        return cases
    for raw in CASE_FILE.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        text, expected = line.split("\t", 1)
        cases.append((text, expected.split()))
    return cases


def run_score(plugin_path: Path, score: float) -> tuple[int, list[str]]:
    artifact = ROOT / "data" / "hmm" / "bmes_hmm_wordhub_lattice.json"
    tokenizer = Tokenizer()
    failures: list[str] = []
    cases = load_cases()
    try:
        tokenizer.load_plugin(plugin_path, json.dumps({"artifact": str(artifact), "hmm_score": score}))
        for text, expected in cases:
            actual = tokenizer.lcut(text)
            if actual != expected:
                failures.append(f"{text}: {'/'.join(actual)} != {'/'.join(expected)}")
    finally:
        tokenizer.close()
    return len(cases) - len(failures), failures


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        plugin_path = Path(tmp) / hmm_plugin_name()
        build_hmm_plugin(plugin_path)
        default_failures: list[str] = []
        total = len(load_cases())
        for score in SCORES:
            passed, failures = run_score(plugin_path, score)
            print(f"hmm_score={score:g}\t{passed}/{total}")
            if score == DEFAULT_SCORE:
                default_failures = failures
    for failure in default_failures:
        print(f"FAIL\t{failure}")
    return 1 if default_failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
