from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PY_SRC = ROOT / "bindings" / "python" / "src"
if str(PY_SRC) not in sys.path:
    sys.path.insert(0, str(PY_SRC))

from nexaloid import Tokenizer  # noqa: E402


SAMPLES = [
    "南京市长江大桥",
    "研究生命起源",
    "我在使用GPT-5.5 Thinking模型",
    "男款运动百搭纯色中筒袜",
    "中国科学院计算技术研究所",
    "Python3.11在Windows上安装onnxruntime-gpu失败",
    "苹果手机壳透明防摔MagSafe磁吸",
]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("-n", "--repeat", type=int, default=1000)
    args = parser.parse_args()

    start = time.perf_counter()
    tokenizer = Tokenizer()
    init_s = time.perf_counter() - start

    texts = SAMPLES * args.repeat
    start = time.perf_counter()
    token_count = 0
    byte_count = 0
    for text in texts:
        token_count += len(tokenizer.tokenize(text))
        byte_count += len(text.encode("utf-8"))
    single_s = time.perf_counter() - start

    start = time.perf_counter()
    batch = tokenizer.tokenize_batch(texts)
    batch_s = time.perf_counter() - start
    batch_token_count = sum(len(row) for row in batch)

    print(f"init_s={init_s:.4f}")
    print(f"texts={len(texts)}")
    print(f"tokens={token_count}")
    print(f"bytes={byte_count}")
    print(f"single_s={single_s:.4f}")
    print(f"single_texts_per_s={len(texts) / single_s:.0f}")
    print(f"single_mb_per_s={(byte_count / 1024 / 1024) / single_s:.2f}")
    print(f"batch_s={batch_s:.4f}")
    print(f"batch_tokens={batch_token_count}")
    print(f"batch_texts_per_s={len(texts) / batch_s:.0f}")
    print(f"batch_mb_per_s={(byte_count / 1024 / 1024) / batch_s:.2f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
