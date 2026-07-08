from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PY_SRC = ROOT / "bindings" / "python" / "src"
if str(PY_SRC) not in sys.path:
    sys.path.insert(0, str(PY_SRC))

from nexaloid import Tokenizer  # noqa: E402


_BUILTIN_RULES = [
    "url",
    "email",
    "timestamp",
    "windows_path",
    "ipv6",
    "number_unit",
    "market_day",
    "ascii_term",
]


def run(rules_path: Path, cases_path: Path) -> int:
    rules = rules_path.read_text(encoding="utf-8")
    rule_doc = json.loads(rules)
    rule_names = [rule.get("name") or f"rule_{index + 1}" for index, rule in enumerate(rule_doc.get("rules", []))]
    cases = json.loads(cases_path.read_text(encoding="utf-8"))
    tokenizer = Tokenizer(rule_config={"builtin_rules": {name: False for name in _BUILTIN_RULES}})
    tokenizer.load_rules_json(rules)
    try:
        failed = 0
        total_tokens = 0
        hit_counts = {name: 0 for name in rule_names}
        start = time.perf_counter()
        for case in cases:
            rule_tokens = [token for token in tokenizer.tokenize(case["text"]) if token.source == "rule"]
            token_texts = [token.text for token in rule_tokens]
            total_tokens += len(rule_tokens)
            named_tokens: list[str] = []
            for token in rule_tokens:
                if 0 < token.flags <= len(rule_names):
                    rule_name = rule_names[token.flags - 1]
                else:
                    rule_name = "unknown_rule"
                hit_counts[rule_name] = hit_counts.get(rule_name, 0) + 1
                named_tokens.append(f"{rule_name}:{token.text}")
            missing = [word for word in case.get("expect", []) if word not in token_texts]
            unexpected = [word for word in case.get("reject", []) if word in token_texts]
            if missing or unexpected:
                failed += 1
                print(f"FAIL {case['id']}")
                if missing:
                    print(f"  missing: {missing}")
                if unexpected:
                    print(f"  unexpected: {unexpected}")
                print(f"  tokens: {' / '.join(named_tokens)}")
            else:
                print(f"PASS {case['id']}")
                print(f"  tokens: {' / '.join(named_tokens)}")
        elapsed_ms = (time.perf_counter() - start) * 1000.0
        print(f"{len(cases) - failed}/{len(cases)} passed")
        print(f"tokens={total_tokens} elapsed_ms={elapsed_ms:.3f} avg_case_ms={elapsed_ms / max(len(cases), 1):.3f}")
        print("rule_hits:")
        for name in rule_names:
            print(f"  {name}: {hit_counts.get(name, 0)}")
        return 1 if failed else 0
    finally:
        tokenizer.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("rules", type=Path, nargs="?", default=ROOT / "data" / "rules" / "v4_sample_rules.json")
    parser.add_argument("cases", type=Path, nargs="?", default=ROOT / "data" / "badcases" / "rules_v4.json")
    args = parser.parse_args()
    os.environ.setdefault("PYTHONUTF8", "1")
    return run(args.rules, args.cases)


if __name__ == "__main__":
    raise SystemExit(main())
