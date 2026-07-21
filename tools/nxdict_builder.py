from __future__ import annotations

import argparse
import math
import os
import struct
import tempfile
from collections import deque
from pathlib import Path


MAGIC = b"NXDICT1\0"
MAX_FILE_BYTES = 512 * 1024 * 1024
MAX_LINE_BYTES = 1024 * 1024
MAX_WORD_BYTES = 0xFFFF
MAX_CODEPOINTS = 0x110000
MAX_STATES = 16_000_000
MAX_ENTRIES = 4_000_000
MAX_FLOAT32 = 3.4028234663852886e38


def read_rows(path: Path):
    if path.stat().st_size > MAX_FILE_BYTES:
        raise ValueError(f"{path}: input exceeds {MAX_FILE_BYTES} bytes")
    seen: set[str] = set()
    with path.open("rb") as f:
        line_no = 0
        while raw_bytes := f.readline(MAX_LINE_BYTES + 1):
            line_no += 1
            if len(raw_bytes) > MAX_LINE_BYTES:
                raise ValueError(f"{path}:{line_no}: line exceeds {MAX_LINE_BYTES} bytes")
            try:
                raw = raw_bytes.decode("utf-8")
            except UnicodeDecodeError as exc:
                raise ValueError(f"{path}:{line_no}: invalid UTF-8") from exc
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if "\t" in raw:
                fields = raw.rstrip("\r\n").split("\t")
                word = fields[0].strip()
                score_text = fields[1].strip() if len(fields) > 1 else ""
                score_text = score_text or "1.0"
            else:
                parts = line.split()
                word = parts[0] if parts else ""
                score_text = parts[1] if len(parts) > 1 else "1.0"
            if not word:
                raise ValueError(f"{path}:{line_no}: empty word")
            if word in seen:
                raise ValueError(f"{path}:{line_no}: duplicate word {word!r}")
            try:
                score = float(score_text)
            except ValueError as exc:
                raise ValueError(f"{path}:{line_no}: invalid score {score_text!r}") from exc
            if not math.isfinite(score) or abs(score) > MAX_FLOAT32:
                raise ValueError(f"{path}:{line_no}: score must be a finite float32")
            data = word.encode("utf-8")
            if len(data) > MAX_WORD_BYTES:
                raise ValueError(f"{path}:{line_no}: word exceeds {MAX_WORD_BYTES} UTF-8 bytes")
            seen.add(word)
            if len(seen) > MAX_ENTRIES:
                raise ValueError(f"{path}:{line_no}: entry count exceeds {MAX_ENTRIES}")
            yield word, data, score


def build_trie(rows):
    nodes = [{"word_id": 0, "score": 0.0, "children": {}}]
    entries = []
    for word_id, (word, data, score) in enumerate(rows, 1):
        node = 0
        for ch in word:
            children = nodes[node]["children"]
            cp = ord(ch)
            if cp not in children:
                if len(nodes) >= MAX_STATES:
                    raise ValueError(f"trie state count exceeds {MAX_STATES}")
                children[cp] = len(nodes)
                nodes.append({"word_id": 0, "score": 0.0, "children": {}})
            node = children[cp]
        nodes[node]["word_id"] = word_id
        nodes[node]["score"] = score
        entries.append((data, score))
    return nodes, entries


def find_base(child_codes, used, start):
    base = start
    while True:
        for code in child_codes:
            pos = base + code
            if pos < len(used) and used[pos]:
                break
        else:
            return base
        base += 1


def ensure_len(items, size, fill):
    if len(items) < size:
        items.extend([fill] * (size - len(items)))


def build_dat(nodes):
    codepoints = sorted({cp for node in nodes for cp in node["children"]})
    if len(codepoints) > MAX_CODEPOINTS:
        raise ValueError(f"codepoint count exceeds {MAX_CODEPOINTS}")
    code_id = {cp: i + 1 for i, cp in enumerate(codepoints)}
    trie_to_dat = {0: 0}
    base = [0]
    check = [0]
    used = [True]
    q = deque([0])
    next_base = 1

    while q:
        trie_node = q.popleft()
        dat_state = trie_to_dat[trie_node]
        children = nodes[trie_node]["children"]
        if not children:
            continue
        child_codes = sorted(code_id[cp] for cp in children)
        b = find_base(child_codes, used, next_base)
        next_base = b
        ensure_len(base, dat_state + 1, 0)
        base[dat_state] = b
        for cp, child in children.items():
            target = b + code_id[cp]
            if target >= MAX_STATES:
                raise ValueError(f"double-array state count exceeds {MAX_STATES}")
            ensure_len(base, target + 1, 0)
            ensure_len(check, target + 1, 0)
            ensure_len(used, target + 1, False)
            used[target] = True
            check[target] = dat_state + 1
            trie_to_dat[child] = target
            q.append(child)

    state_count = len(base)
    meta = [(0, 0.0)] * state_count
    for trie_node, dat_state in trie_to_dat.items():
        node = nodes[trie_node]
        meta[dat_state] = (node["word_id"], node["score"])
    return codepoints, base, check, meta


def build(in_path: Path, out_path: Path) -> tuple[int, int, int]:
    rows = list(read_rows(in_path))
    nodes, entries = build_trie(rows)
    codepoints, base, check, meta = build_dat(nodes)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    temp_path = None
    try:
        with tempfile.NamedTemporaryFile("wb", dir=out_path.parent, delete=False) as f:
            temp_path = Path(f.name)
            f.write(MAGIC)
            f.write(struct.pack("<III", len(codepoints), len(base), len(entries)))
            for cp in codepoints:
                f.write(struct.pack("<I", cp))
            for item in base:
                f.write(struct.pack("<I", item))
            for item in check:
                f.write(struct.pack("<I", item))
            for word_id, score in meta:
                f.write(struct.pack("<If", word_id, score))
            for data, score in entries:
                f.write(struct.pack("<HHf", len(data), 0, score))
                f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(temp_path, out_path)
        temp_path = None
    finally:
        if temp_path is not None:
            temp_path.unlink(missing_ok=True)
    return len(entries), len(base), len(codepoints)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    entries, states, codes = build(args.input, args.output)
    print(f"wrote\tentries={entries}\tstates={states}\tcodes={codes}\t{args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
