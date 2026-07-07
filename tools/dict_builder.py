from __future__ import annotations

import argparse
import importlib.util
import math
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def find_jieba_dict() -> Path | None:
    spec = importlib.util.find_spec("jieba")
    if spec is None or not spec.submodule_search_locations:
        return None
    path = Path(next(iter(spec.submodule_search_locations))) / "dict.txt"
    return path if path.exists() else None


def read_jieba(path: Path) -> list[tuple[str, float, str]]:
    rows: list[tuple[str, float, str]] = []
    total = 0.0
    raw: list[tuple[str, float, str]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        try:
            freq = float(parts[1])
        except ValueError:
            continue
        if freq <= 0:
            continue
        pos = parts[2] if len(parts) > 2 else guess_pos(parts[0])
        raw.append((parts[0], freq, pos))
        total += freq
    total = max(total, 1.0)
    for word, freq, pos in raw:
        rows.append((word, math.log(freq) - math.log(total), pos))
    return rows


def read_overlay(path: Path) -> list[tuple[str, float, str]]:
    if not path.exists():
        return []
    rows: list[tuple[str, float, str]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        rows.append((parts[0], float(parts[1]), parts[2] if len(parts) > 2 else guess_pos(parts[0])))
    return rows


def read_demotions(path: Path) -> list[tuple[str, float]]:
    if not path.exists():
        return []
    rows: list[tuple[str, float]] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        rows.append((parts[0], float(parts[1])))
    return rows


def guess_pos(word: str) -> str:
    if any(ch.isascii() and ch.isalnum() for ch in word):
        return "nx"
    if word.endswith(("市", "省", "县", "区")):
        return "ns"
    if word.endswith(("公司", "大学", "学院", "研究所")):
        return "nt"
    return "n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--jieba-dict", type=Path)
    parser.add_argument("--overlay", type=Path, default=ROOT / "data" / "dict" / "overlay.tsv")
    parser.add_argument("--demote", type=Path, default=ROOT / "data" / "dict" / "demote.tsv")
    parser.add_argument("--out", type=Path, default=ROOT / "data" / "dict" / "nexaloid.tsv")
    args = parser.parse_args()

    jieba_dict = args.jieba_dict or find_jieba_dict()
    if jieba_dict is None:
        raise SystemExit("jieba dict not found")

    merged: dict[str, tuple[float, str]] = {}
    for word, score, pos in read_jieba(jieba_dict):
        merged[word] = (score, pos)
    for word, score in read_demotions(args.demote):
        if word in merged:
            merged[word] = (score, merged[word][1])
    for word, score, pos in read_overlay(args.overlay):
        merged[word] = (score, pos)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", encoding="utf-8", newline="\n") as f:
        for word, (score, pos) in merged.items():
            f.write(f"{word}\t{score:.8f}\t{pos}\n")
    print(f"wrote {len(merged)} entries to {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
