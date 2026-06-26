from __future__ import annotations

import argparse
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def validate(path: Path) -> int:
    seen: dict[str, int] = {}
    errors: list[str] = []

    for line_no, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 2:
            errors.append(f"{line_no}: expected at least word<TAB>score")
            continue
        word, score = parts[0].strip(), parts[1].strip()
        if not word:
            errors.append(f"{line_no}: empty word")
        if word in seen:
            errors.append(f"{line_no}: duplicate word {word!r}, first seen at {seen[word]}")
        seen[word] = line_no
        try:
            value = float(score)
            if value <= 0:
                errors.append(f"{line_no}: score must be positive")
        except ValueError:
            errors.append(f"{line_no}: invalid score {score!r}")

    for error in errors:
        print(f"FAIL {error}")
    print(f"{len(seen)} entries checked")
    return 1 if errors else 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "path",
        nargs="?",
        default=ROOT / "data" / "dict" / "overlay.tsv",
        type=Path,
    )
    return validate(parser.parse_args().path)


if __name__ == "__main__":
    raise SystemExit(main())

