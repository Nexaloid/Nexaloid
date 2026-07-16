from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import statistics
import sys
import time
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

from nexaloid import Mode, Tokenizer, entity_artifact_path, entity_plugin_path  # noqa: E402


def load_articles(path: Path, expected_sha256: str | None) -> list[dict[str, str]]:
    raw = gzip.decompress(path.read_bytes())
    digest = hashlib.sha256(raw).hexdigest()
    if expected_sha256 and digest != expected_sha256.lower():
        raise ValueError(f"corpus SHA-256 mismatch: {digest}")
    return [json.loads(line) for line in raw.splitlines()]


def run(tokenizer: Tokenizer, articles: list[dict[str, str]]) -> tuple[float, int, int]:
    token_count = 0
    plugin_count = 0
    start = time.perf_counter()
    for article in articles:
        for field, mode in (("title", Mode.SEARCH), ("content", Mode.RECALL_SEARCH)):
            tokens = tokenizer.tokenize(article[field], mode)
            token_count += len(tokens)
            plugin_count += sum(token.source == "plugin" for token in tokens)
    return time.perf_counter() - start, token_count, plugin_count


def main() -> int:
    parser = argparse.ArgumentParser(description="Measure entity-plugin overhead on a gzipped news JSONL corpus.")
    parser.add_argument("corpus", type=Path)
    parser.add_argument("--dict", dest="dictionary", type=Path, required=True)
    parser.add_argument("--corpus-sha256")
    parser.add_argument("--plugin", type=Path, default=entity_plugin_path())
    parser.add_argument("--artifact", type=Path, default=entity_artifact_path())
    parser.add_argument("--warmup", type=int, default=50)
    parser.add_argument("--rounds", type=int, default=7)
    parser.add_argument("--max-overhead", type=float, default=5.0)
    args = parser.parse_args()
    if args.rounds < 1 or args.warmup < 0:
        parser.error("--rounds must be positive and --warmup must be non-negative")

    articles = load_articles(args.corpus, args.corpus_sha256)
    baseline = Tokenizer()
    combined = Tokenizer()
    try:
        baseline.load_userdict(args.dictionary)
        combined.load_userdict(args.dictionary)
        plugin_load_start = time.perf_counter()
        combined.load_plugin(args.plugin, json.dumps({"artifact": str(args.artifact)}))
        plugin_load_ms = (time.perf_counter() - plugin_load_start) * 1000

        warmup = articles[: args.warmup]
        run(baseline, warmup)
        run(combined, warmup)

        timings: dict[str, list[float]] = {"dictionary": [], "dictionary_plugin": []}
        counts: dict[str, tuple[int, int]] = {}
        tokenizers = {"dictionary": baseline, "dictionary_plugin": combined}
        for round_index in range(args.rounds):
            order = ("dictionary", "dictionary_plugin")
            if round_index % 2:
                order = tuple(reversed(order))
            for name in order:
                elapsed, token_count, plugin_count = run(tokenizers[name], articles)
                timings[name].append(elapsed)
                current = (token_count, plugin_count)
                if name in counts and counts[name] != current:
                    raise RuntimeError(f"unstable token counts for {name}: {counts[name]} != {current}")
                counts[name] = current

        baseline_median = statistics.median(timings["dictionary"])
        combined_median = statistics.median(timings["dictionary_plugin"])
        overhead = (combined_median / baseline_median - 1.0) * 100.0
        result = {
            "articles": len(articles),
            "rounds": args.rounds,
            "dictionary_median_ms": round(baseline_median * 1000, 3),
            "dictionary_plugin_median_ms": round(combined_median * 1000, 3),
            "overhead_percent": round(overhead, 3),
            "max_overhead_percent": args.max_overhead,
            "plugin_load_ms": round(plugin_load_ms, 3),
            "dictionary_tokens": counts["dictionary"][0],
            "dictionary_plugin_tokens": counts["dictionary_plugin"][0],
            "plugin_tokens": counts["dictionary_plugin"][1],
            "passed": overhead <= args.max_overhead,
        }
        print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))
        return 0 if result["passed"] else 1
    finally:
        combined.close()
        baseline.close()


if __name__ == "__main__":
    raise SystemExit(main())
