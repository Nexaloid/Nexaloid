# Nexaloid

Nexaloid is a high-performance Chinese tokenizer runtime, built in Zig with a stable C ABI and first-class bindings for Python, Node.js, C++, Go, and Rust.

It is designed for production workloads where correctness, throughput, and cross-language consistency matter: search engines, RAG pipelines, e-commerce catalogs, and text analytics.

## What Nexaloid Is

- A dictionary-driven Chinese segmentation engine (double-array trie + Viterbi decoder)
- A search tokenizer that emits n-gram expansions for recall
- An **explainable** tokenizer: every token carries its origin (base dict, user dict, rule, or plugin) and a score
- A **pluggable** segmentation runtime with a defined plugin ABI for neural-model integration
- Infrastructure for byte- and character-offset-preserving token output across all language bindings

## What Nexaloid Is Not

Nexaloid is not a jieba rewrite, a HuggingFace / ONNX binding, a Python-only NLP package, an LLM tokenizer, or a heavy NLP framework. The core has zero Python, PyTorch, or TensorFlow dependencies.

## Quick Start

### Python

```python
from nexaloid import Tokenizer

tokenizer = Tokenizer()
for token in tokenizer.tokenize("南京市长江大桥"):
    print(token.text, token.start_byte, token.end_byte, token.source, token.score)

# Jieba-compatible API
import nexaloid.compat_jieba as jieba
print(jieba.lcut("研究生命起源"))
# ['研究', '生命', '起源']
```

```powershell
$env:PYTHONPATH = "$PWD\bindings\python\src"
python -c "import nexaloid.compat_jieba as jieba; print(jieba.lcut('南京市长江大桥'))"
```

### Node.js

```javascript
const { Tokenizer } = require("@nexaloid/nexaloid");

const tokenizer = new Tokenizer();
console.log(tokenizer.lcut("南京市长江大桥"));
// ['南京市', '长江大桥']
tokenizer.close();
```

```powershell
cd bindings/node
npm run build
npm run smoke
```

### C++

```cpp
#include <nexaloid.hpp>

NxConfig cfg{};
cfg.dict_path = "data/dict/nexaloid.tsv";
nexaloid::Tokenizer tokenizer(cfg);
for (const auto& word : tokenizer.cut("南京市长江大桥"))
    std::cout << word << "\n";
```

### Go

```go
tokenizer, _ := nexaloid.New("data/dict/nexaloid.tsv")
defer tokenizer.Close()
tokens, _ := tokenizer.Tokenize("南京市长江大桥", nexaloid.Accurate)
```

### Rust

```rust
let tokenizer = Tokenizer::new(config)?;
let tokens = tokenizer.tokenize("南京市长江大桥", Mode::Accurate)?;
```

## Tokenization Modes

| Mode | Behavior |
|------|----------|
| **Accurate** | Viterbi shortest-path decoding; filters pure whitespace tokens |
| **Search** | Emits all dictionary candidates + 2-gram / 3-gram expansions for recall |
| **Full** | Reserved for API compatibility; behaves like Accurate in v0.1 |

## Architecture

```
UTF-8 text
  → Scanner (codepoints + byte/char offsets + class)
  → Dictionary Matcher (double-array trie walk + overlay trie)
  → Rule Matcher (mixed-script boundaries, number + unit patterns)
  → Lattice (all candidate edges from dict/rule/unknown sources)
  → Viterbi Decoder (globally best path)
  → Token Stream (filtered, offset-preserving)
```

The core is a single Zig library (`libnexaloid`). Language bindings call the C ABI and never reimplement tokenizer logic. Plugins (neural scorers, POS taggers, NER) hook into the pipeline via the stable plugin ABI — the core runs without them.

## Features

### Dictionary System

- **Base dictionary**: 350,000+ words, stored as a memory-mapped double-array trie (mmap on Windows, zero-copy)
- **User dictionary**: runtime overlay trie, loaded from TSV or binary NXDICT format
- **Domain overlay**: appended as an overlay on init via `NxConfig.user_dict_path`
- **Binary format (NXDICT)**: compact packed trie with unified DAT + entries; ~38 MB for 350k words

### Performance

- **Batch parallel tokenization**: multi-threaded worker pool with in-order callback emission
- **Segmented long-input processing**: inputs split on sentence boundaries (newline, period, exclamation, CJK punctuation) into ≤512-char chunks
- **Lattice indexed by start character**: O(1) edge lookup per position

### Cross-Language Consistency

All bindings share the same core. A token produced by the Python binding is byte-identical to a token from the C++ or Go binding for the same input and dictionary.

### Plugin ABI (v0.2+)

The plugin system defines 8 hook points (candidate provider, boundary scorer, edge scorer, token filter, token expander, POS tagger, entity recognizer, normalizer). Plugins are dynamic libraries loaded at runtime — the core defines the ABI, plugins implement it.

## C ABI

```c
NxStatus nx_engine_new(const NxConfig *config, NxEngine **out_engine);
void      nx_engine_free(NxEngine *engine);
NxStatus  nx_tokenize(NxEngine *engine, const char *text, size_t text_len,
                      NxMode mode, NxTokenCallback callback, void *user_data);
NxStatus  nx_tokenize_batch(NxEngine *engine, const char *const *texts,
                            const size_t *text_lens, size_t text_count,
                            NxMode mode, uint32_t thread_count,
                            NxBatchTokenCallback callback, void *user_data);
NxStatus  nx_add_word(NxEngine *engine, const char *word, size_t word_len,
                      uint32_t word_id, float score, uint16_t pos_id);
NxStatus  nx_reload_user_dict(NxEngine *engine, const char *user_dict_path);
```

Headers: `core/include/nexaloid.h`, `core/include/nexaloid_plugin.h`

## Token Output

Every token includes:

| Field | Description |
|-------|-------------|
| `text` | The matched substring |
| `start_byte` / `end_byte` | UTF-8 byte offsets in the original input |
| `start_char` / `end_char` | Unicode codepoint offsets |
| `word_id` | Dictionary word ID (0 for unknown / rule tokens) |
| `pos_id` | POS tag ID (reserved, unresolved in v0.1) |
| `source` | Origin: `base_dict`, `user_dict`, `domain_dict`, `rule`, `unknown`, or `plugin` |
| `score` | Decoder score (higher is better; log-probability for dict tokens) |

## Dictionary Management

Build the base dictionary from jieba's `dict.txt` plus a custom overlay:

```powershell
python tools/dict_builder.py --out data/dict/nexaloid.tsv
```

Compile to the packed binary format for mmap-accelerated loading:

```powershell
python tools/nxdict_builder.py data/dict/nexaloid.tsv data/dict/nexaloid.nxdict
```

Validate the overlay dictionary:

```powershell
python tools/validate_overlay.py data/dict/overlay.tsv
```

## Development

```powershell
cd core
rtk zig build          # compile the shared library
rtk zig build test     # run core tests
cd ..

# Python smoke tests
$env:PYTHONPATH = "$PWD\bindings\python\src"
python tools\badcase_runner.py
python tools\validate_overlay.py
python tools\benchmark.py
```

## Benchmark

```powershell
$env:PYTHONPATH = "$PWD\bindings\python\src"
python tools\benchmark.py -n 1000
```

## Language Bindings

| Language | Directory | Status |
|----------|-----------|--------|
| Python | `bindings/python/` | jieba-compatible API, batch support |
| Node.js | `bindings/node/` | N-API native addon |
| C++ | `bindings/cpp/` | RAII wrapper, header-only |
| Go | `bindings/go/` | cgo binding |
| Rust | `bindings/rust/` | safe wrapper + `-sys` crate |
