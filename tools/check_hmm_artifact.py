from __future__ import annotations

import hashlib
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ARTIFACT = ROOT / "data" / "hmm" / "bmes_hmm_wordhub_lattice.json"
MANIFEST = ROOT / "data" / "hmm" / "bmes_hmm_wordhub_lattice.manifest.json"


def main() -> int:
    payload = ARTIFACT.read_bytes()
    digest = hashlib.sha256(payload).hexdigest()
    expected = ARTIFACT.with_suffix(ARTIFACT.suffix + ".sha256").read_text(encoding="utf-8").split()[0]
    model = json.loads(payload.decode("utf-8"))
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    assert digest == expected
    assert manifest["artifact_sha256"] == digest
    assert manifest["schema"] == "nexaloid.hmm_manifest.v1"
    assert manifest["decoder"] == model["decoder"]
    assert manifest["inputs"] == model["inputs"]
    assert manifest["quality"] == model["quality"]
    assert manifest["lexicon_size"] == len(model["lexicon"])
    assert model["schema"] == "nexaloid.hmm_artifact.v1"
    assert model["model_schema"] == "nexaloid.hmm_bmes.v2"
    assert model["decoder"]["kind"] == "bmes_hmm_lexicon_lattice"
    assert model["quality"]["lattice_heldout"]["token_f1"] >= 0.98
    assert model["quality"]["lattice_heldout"]["boundary_f1"] >= 0.99
    assert model["quality"]["lattice_heldout"]["passed"] == model["quality"]["lattice_heldout"]["total"]
    lexicon = set(model["lexicon"])
    for word in (
        "北京大学",
        "二甲双胍",
        "证券市场",
        "调查报告",
        "人民医院",
        "参数传递",
        "系统调用",
        "数据结构",
        "类型转换",
        "支持环",
        "正常运行",
    ):
        assert word in lexicon
    for word in ("合同约定", "春节前发表", "字符串优化知识库"):
        assert word not in lexicon
    print("hmm_artifact_ok")
    print(f"sha256\t{digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
