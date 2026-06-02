# nexaloid

nexaloid is a multilingual tokenizer runtime centered on a traditional engineering Chinese segmentation core, with plugins for neural-model ecosystem integration.

It is not a jieba rewrite, a ModelScope/HuggingFace/ONNX binding, a Python-only NLP package, an LLM tokenizer, or a heavy NLP framework.

## Scope

Core first:

- Chinese segmentation engine
- Chinese search tokenizer
- RAG preprocessing tokenizer
- Explainable dictionary segmentation
- Optional neural segmentation plugins
- Stable cross-language runtime through a C ABI

## v0.1 Target

`nexaloid-core-alpha` focuses on:

- UTF-8 scanner with byte and character offsets
- Dictionary candidate matching
- Lattice construction
- Viterbi decoding
- Accurate and search modes
- Stable C ABI
- Python binding
- Small jieba compatibility adapter
- Benchmark and badcase runner

## Development

```powershell
cd core
rtk zig build
rtk zig build test
cd ..
$env:PYTHONPATH = "$PWD\bindings\python\src"
python tools\badcase_runner.py
python tools\validate_overlay.py
python tools\benchmark.py
```

Neural model integrations, ONNX, ModelScope, HuggingFace, POS, NER, TextRank, and full language bindings are out of scope for v0.1.

## Documents

- [Vision](docs/vision.md)
- [Architecture](docs/architecture.md)
- [Dictionary Format](docs/dictionary_format.md)
- [Plugin ABI](docs/plugin_abi.md)
- [jieba Compatibility](docs/jieba_compat.md)
- [Language Binding Ecosystem](docs/bindings_ecosystem.md)
- [Roadmap](docs/roadmap.md)
