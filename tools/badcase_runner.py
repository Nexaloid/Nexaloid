from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PY_SRC = ROOT / "bindings" / "python" / "src"
if str(PY_SRC) not in sys.path:
    sys.path.insert(0, str(PY_SRC))

import nexaloid.compat_jieba as jieba  # noqa: E402


def run(path: Path) -> int:
    cases = json.loads(path.read_text(encoding="utf-8"))
    failed = 0

    for case in cases:
        case_id = case["id"]
        text = case["text"]
        if "expected" in case:
            actual = jieba.lcut(text)
            expected = case["expected"]
            ok = actual == expected
        else:
            actual = list(jieba.cut_for_search(text))
            expected = case["expected_search_contains"]
            ok = all(word in actual for word in expected)

        if ok:
            print(f"PASS {case_id}")
        else:
            failed += 1
            print(f"FAIL {case_id}")
            print(f"  text: {text}")
            print(f"  expected: {expected}")
            print(f"  actual:   {actual}")

    total = len(cases)
    print(f"{total - failed}/{total} passed")
    return 1 if failed else 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "path",
        nargs="?",
        default=ROOT / "data" / "badcases" / "core.json",
        type=Path,
    )
    args = parser.parse_args()
    os.environ.setdefault("PYTHONUTF8", "1")
    return run(args.path)


if __name__ == "__main__":
    raise SystemExit(main())

