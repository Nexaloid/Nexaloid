from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REMOTE_ACTION_RE = re.compile(r"^\s*uses:\s*([^\s#]+)", re.MULTILINE)
PINNED_ACTION_RE = re.compile(r"^[^@\s]+@[0-9a-f]{40}$")
DOWNLOAD_RE = re.compile(r"\b(?:curl|wget|Invoke-WebRequest)\b", re.IGNORECASE)
CHECKSUM_RE = re.compile(r"\b(?:sha256|sha256sum|shasum|Get-FileHash)\b", re.IGNORECASE)


def workflow_files(root: Path) -> list[Path]:
    github = root / ".github"
    return sorted(path for path in github.rglob("*") if path.suffix in {".yml", ".yaml"})


def lint_text(path: Path, text: str) -> list[str]:
    errors: list[str] = []
    for match in REMOTE_ACTION_RE.finditer(text):
        reference = match.group(1)
        if reference.startswith("./") or reference.startswith("docker://"):
            continue
        if not PINNED_ACTION_RE.fullmatch(reference):
            line = text.count("\n", 0, match.start()) + 1
            errors.append(f"{path}:{line}: remote action is not pinned to a 40-character SHA: {reference}")

    lines = text.splitlines()
    for index, line in enumerate(lines):
        if DOWNLOAD_RE.search(line) is None:
            continue
        nearby = "\n".join(lines[index : index + 13])
        if CHECKSUM_RE.search(nearby) is None:
            errors.append(f"{path}:{index + 1}: download is not followed by a SHA-256 check")
    return errors


def lint(root: Path = ROOT) -> list[str]:
    errors: list[str] = []
    for path in workflow_files(root):
        errors.extend(lint_text(path.relative_to(root), path.read_text(encoding="utf-8")))
    return errors


def main() -> int:
    errors = lint()
    for error in errors:
        print(f"FAIL {error}")
    if errors:
        return 1
    print("supply-chain policy checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
