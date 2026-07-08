from __future__ import annotations

import hashlib
import json
import struct
import zlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ARTIFACT = ROOT / "data" / "hmm" / "bmes_hmm_wordhub_lattice.nxhmm"
MANIFEST = ROOT / "data" / "hmm" / "bmes_hmm_wordhub_lattice.manifest.json"
MAGIC = b"NXHMM001"
HEADER = "<8sIIIIIIIff"
HEADER_SIZE = struct.calcsize(HEADER)
SCORES_SIZE = (4 + 16 + 4) * 8
EMISSION_SIZE = struct.calcsize("<I4d")


def main() -> int:
    payload = ARTIFACT.read_bytes()
    digest = hashlib.sha256(payload).hexdigest()
    expected = ARTIFACT.with_suffix(ARTIFACT.suffix + ".sha256").read_text(encoding="utf-8").split()[0]
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    assert digest == expected
    assert manifest["artifact_sha256"] == digest
    assert manifest["schema"] == "nexaloid.hmm_manifest.v1"
    assert manifest["artifact_format"] == "nxhmm.v1"
    assert manifest["compression"] == "zlib"

    (
        magic,
        version,
        emission_count,
        lexicon_count,
        raw_lexicon_len,
        compressed_lexicon_len,
        max_word_len,
        max_unknown_len,
        lexicon_bonus,
        unknown_penalty,
    ) = struct.unpack_from(HEADER, payload, 0)
    assert magic == MAGIC
    assert version == 1
    assert emission_count == manifest["emission_size"]
    assert lexicon_count == manifest["lexicon_size"]
    assert max_word_len == manifest["decoder"]["max_word_len"]
    assert max_unknown_len == manifest["decoder"]["max_unknown_len"]
    assert lexicon_bonus == manifest["decoder"]["lexicon_bonus"]
    assert unknown_penalty == manifest["decoder"]["unknown_penalty"]

    lexicon_offset = HEADER_SIZE + SCORES_SIZE + emission_count * EMISSION_SIZE
    compressed = payload[lexicon_offset : lexicon_offset + compressed_lexicon_len]
    assert len(compressed) == compressed_lexicon_len
    raw = zlib.decompress(compressed)
    assert len(raw) == raw_lexicon_len

    words: set[str] = set()
    pos = 0
    while pos < len(raw):
        (length,) = struct.unpack_from("<H", raw, pos)
        pos += 2
        words.add(raw[pos : pos + length].decode("utf-8"))
        pos += length
    assert len(words) == lexicon_count
    for word in ("北京大学", "二甲双胍", "证券市场", "数据结构", "正常运行"):
        assert word in words

    quality = manifest["quality"]["lattice_heldout"]
    assert quality["token_f1"] >= 0.98
    assert quality["boundary_f1"] >= 0.99
    assert quality["passed"] == quality["total"]
    print("hmm_artifact_ok")
    print(f"sha256\t{digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
