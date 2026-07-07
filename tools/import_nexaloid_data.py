from __future__ import annotations

import argparse
import math
import shutil
import unicodedata
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DATA_ROOT = Path(r"F:\Code\03_OpenCode\NexaloidData")
BAD_PREFIXES = ("很", "挺", "太", "真", "更", "最", "也", "都", "不", "没", "再", "还")
BAD_SUFFIXES = ("的", "了", "着", "过", "吗", "呢", "吧", "啊", "嘛", "么")
SENTENCE_PUNCT = set("，。！？；：、,!?;:()（）[]【】《》“”\"'")
TECH_PUNCT = set(".#+-_/")
DOMAIN_STOPLIKE = {
    "一样",
    "一般",
    "什么",
    "没有",
    "可以",
    "了一",
    "现在",
    "时候",
    "怎么",
    "还是",
    "哈哈",
    "仿佛",
    "他们",
    "但是",
    "我们",
    "感觉",
    "因为",
    "起来",
    "不过",
    "出来",
}
AUDITED_BASE_REJECTS = {
    "促进社会和谐",
    "戴维",
    "达路",
    "道酒",
    "国际上",
    "果后",
    "果佳",
    "港红",
    "红柿",
    "健力",
    "基摩",
    "经研究",
    "刘涛",
    "刘伟",
    "力存",
    "利欧",
    "利嘉",
    "李斌",
    "李伟",
    "露丝",
    "马云",
    "面鲜",
    "某甲",
    "多宝",
    "全保",
    "如虎",
    "润明",
    "手按",
    "施行后",
    "王毅",
    "王刚",
    "王磊",
    "王伟",
    "华凌",
    "向北",
    "肖子",
    "无法识别",
    "未有效",
    "新凯",
    "小灯",
    "小火煮",
    "小雀",
    "新红",
    "新一",
    "刑复",
    "有车",
    "上都",
    "自告",
    "全部到位",
    "张杰",
    "张记",
    "周强",
    "隆鑫",
    "柴静",
    "孙俪",
    "天果",
    "唯一代表",
    "维护社会公平正义",
    "法院经审理查明",
    "话李",
    "小鲤",
    "小鸥",
    "加去",
    "年在",
    "年度车",
    "小野猪",
    "张璐",
    "新开",
}


def read_current_words(path: Path) -> set[str]:
    words: set[str] = set()
    if not path.exists():
        return words
    with path.open("r", encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if line and not line.startswith("#"):
                words.add(line.split("\t", 1)[0])
    return words


def read_duplicate_counts(path: Path) -> dict[str, int]:
    counts: dict[str, int] = {}
    if not path.exists():
        return counts
    with path.open("r", encoding="utf-8") as f:
        next(f, None)
        for raw in f:
            parts = raw.rstrip("\n").split("\t")
            if len(parts) >= 5:
                try:
                    counts[parts[0].lstrip("\ufeff")] = int(parts[4])
                except ValueError:
                    pass
    return counts


def is_ascii_word(word: str) -> bool:
    return all(ord(ch) < 128 for ch in word)


def is_tech_like(word: str) -> bool:
    return any(ch.isascii() and ch.isalnum() for ch in word) and all(
        (ch.isascii() and (ch.isalnum() or ch in TECH_PUNCT)) or "\u3400" <= ch <= "\u9fff"
        for ch in word
    )


def symbol_ratio(word: str) -> float:
    if not word:
        return 1.0
    return sum(1 for ch in word if unicodedata.category(ch)[0] in {"P", "S"}) / len(word)


def reject_reason(word: str, pos: str, source: str, duplicate_count: int, current_words: set[str]) -> str | None:
    if not word:
        return "empty"
    if pos == "nr":
        return "person_name"
    if word in current_words:
        return "already_in_current"
    if word in AUDITED_BASE_REJECTS:
        return "audited_noise"
    if len(word) == 1 and word.isascii():
        return "single_ascii"
    if any(ch.isspace() for ch in word):
        return "has_space"
    if any(ch in SENTENCE_PUNCT for ch in word):
        return "has_sentence_punct"
    if len(word) >= 2 and (word.startswith(BAD_PREFIXES) or word.endswith(BAD_SUFFIXES)):
        return "bad_affix"
    if is_tech_like(word):
        if len(word) > 32:
            return "tech_too_long"
    elif is_ascii_word(word):
        if len(word) > 32:
            return "ascii_too_long"
    elif len(word) > 10:
        return "too_long_for_base"
    if not is_tech_like(word) and symbol_ratio(word) > 0.35:
        return "too_many_symbols"
    if source != "thuocl" and duplicate_count < 2:
        return "low_source_confidence"
    return None


def runtime_score(raw_score: float, source: str, duplicate_count: int) -> float:
    source_boost = 3.0 if source == "thuocl" else 1.0
    duplicate_boost = min(math.log1p(max(duplicate_count - 1, 0)) * 2.0, 4.0)
    frequency_boost = max(0.0, min(4.0, 12.0 + raw_score))
    return 8.0 + source_boost + duplicate_boost + frequency_boost


def guess_pos(word: str, pos: str) -> str:
    if pos:
        return pos
    if any(ch.isascii() and ch.isalnum() for ch in word):
        return "nx"
    if word.endswith(("市", "省", "县", "区")):
        return "ns"
    if word.endswith(("公司", "大学", "学院", "研究所")):
        return "nt"
    return "n"


def import_base_candidates(data_root: Path, out_dir: Path, top: int) -> None:
    source = data_root / "data" / "releases" / "hanseg_dict_v1_filtered.tsv"
    duplicates = read_duplicate_counts(data_root / "data" / "releases" / "hanseg_dict_v1_duplicates.tsv")
    current_words = read_current_words(ROOT / "data" / "dict" / "nexaloid.tsv")
    kept: list[tuple[str, float, str, str, float, int]] = []
    rejects: list[tuple[str, str, str, float, int]] = []

    with source.open("r", encoding="utf-8-sig", errors="ignore") as f:
        for raw in f:
            parts = raw.rstrip("\n").split("\t")
            if len(parts) < 2:
                continue
            word = parts[0].lstrip("\ufeff")
            try:
                raw_score = float(parts[1])
            except ValueError:
                continue
            pos = guess_pos(word, parts[2] if len(parts) > 2 else "")
            row_source = parts[3] if len(parts) > 3 else ""
            duplicate_count = duplicates.get(word, 1)
            reason = reject_reason(word, pos, row_source, duplicate_count, current_words)
            if reason:
                if reason != "already_in_current":
                    rejects.append((word, reason, row_source, raw_score, duplicate_count))
                continue
            score = runtime_score(raw_score, row_source, duplicate_count)
            kept.append((word, score, pos, row_source, raw_score, duplicate_count))

    kept.sort(key=lambda row: (-row[1], -row[5], row[0]))
    kept = kept[:top]
    out_dir.mkdir(parents=True, exist_ok=True)
    with (out_dir / "overlay.generated.tsv").open("w", encoding="utf-8", newline="\n") as f:
        f.write("# word\tscore\tpos\tsource\traw_score\tduplicate_count\n")
        for word, score, pos, source_name, raw_score, duplicate_count in kept:
            f.write(f"{word}\t{score:.4f}\t{pos}\t{source_name}\t{raw_score:.8f}\t{duplicate_count}\n")
    with (out_dir / "rejects.generated.tsv").open("w", encoding="utf-8", newline="\n") as f:
        f.write("word\treason\tsource\traw_score\tduplicate_count\n")
        for word, reason, source_name, raw_score, duplicate_count in rejects:
            f.write(f"{word}\t{reason}\t{source_name}\t{raw_score:.8f}\t{duplicate_count}\n")
    print(f"base_candidates\t{len(kept)}")
    print(f"rejects\t{len(rejects)}")


def copy_domain_dicts(data_root: Path, out_dir: Path, include_raw: bool) -> None:
    if not include_raw:
        shutil.rmtree(out_dir / "domain", ignore_errors=True)
        (out_dir / "domain.rejects.generated.tsv").unlink(missing_ok=True)
        print("domain_dicts_skipped\traw domain dictionaries need review")
        return

    src = data_root / "data" / "releases" / "domain_dicts"
    dst = out_dir / "domain"
    dst.mkdir(parents=True, exist_ok=True)
    current_words = read_current_words(ROOT / "data" / "dict" / "nexaloid.tsv")
    count = 0
    rejected = 0
    rejects = out_dir / "domain.rejects.generated.tsv"
    reject_rows: list[tuple[str, str, str]] = []
    for path in sorted(src.glob("*.tsv")):
        with path.open("r", encoding="utf-8") as f, (dst / path.name).open("w", encoding="utf-8", newline="\n") as out:
            for raw in f:
                word = raw.split("\t", 1)[0].strip()
                if word in DOMAIN_STOPLIKE:
                    reject_rows.append((path.stem, word, "domain_stoplike"))
                    rejected += 1
                    continue
                if word in current_words:
                    reject_rows.append((path.stem, word, "already_in_current"))
                    rejected += 1
                    continue
                out.write(raw)
        count += 1
    with rejects.open("w", encoding="utf-8", newline="\n") as f:
        f.write("domain\tword\treason\n")
        for domain, word, reason in reject_rows:
            f.write(f"{domain}\t{word}\t{reason}\n")
    print(f"domain_dicts\t{count}")
    print(f"domain_rejects\t{rejected}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-root", type=Path, default=DEFAULT_DATA_ROOT)
    parser.add_argument("--out-dir", type=Path, default=ROOT / "data" / "dict" / "generated")
    parser.add_argument("--top", type=int, default=5000)
    parser.add_argument("--include-domain-raw", action="store_true")
    args = parser.parse_args()

    import_base_candidates(args.data_root, args.out_dir, args.top)
    copy_domain_dicts(args.data_root, args.out_dir, args.include_domain_raw)
    print(f"out_dir\t{args.out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
