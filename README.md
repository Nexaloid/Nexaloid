# Nexaloid

Nexaloid is a Chinese tokenizer runtime, built in Zig with a stable C ABI and bindings for Python, Node.js, C++, Go, and Rust.

It is aimed at workloads where correctness, throughput, and cross-language consistency matter: search engines, RAG pipelines, e-commerce catalogs, and text analytics.

## What Nexaloid Is

- A dictionary-driven Chinese segmentation engine (double-array trie + Viterbi decoder)
- A search tokenizer that emits dictionary candidates plus 2-gram / 3-gram expansions for recall
- An **explainable** tokenizer: every token carries its origin (base dict, user dict, rule, or unknown fallback) and a score
- A defined plugin ABI for future neural-model integration; the current core runs without loading plugins
- Byte- and character-offset-preserving token output through the C ABI and language bindings

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

#### jieba API Compatibility

Existing jieba users can keep common jieba function names by changing the import:

```python
import nexaloid.compat_jieba as jieba
```

The adapter exports a module-level tokenizer, like jieba's global API. Current compatible names are `cut`, `lcut`, `cut_for_search`, `lcut_for_search`, `load_userdict`, `add_word`, `del_word`, and `suggest_freq`.

`cut` returns an iterator of strings, `lcut` returns a list, and search mode de-duplicates multi-character search tokens. `load_userdict` accepts jieba-style `word freq tag` text dictionaries; tags, `HMM`, and `use_paddle` are accepted for API shape but ignored by the current adapter. Use `nexaloid.Tokenizer` directly when you need offsets, token source, scores, or batch tokenization. See [docs/jieba_compat.md](docs/jieba_compat.md) for the compatibility boundary.

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
use nexaloid::{Mode, Tokenizer};

let tokenizer = Tokenizer::new_default()?;
let tokens = tokenizer.tokenize("南京市长江大桥", Mode::Accurate)?;
```

## Tokenization Modes

| Mode | Behavior |
|------|----------|
| **Accurate** | Viterbi shortest-path decoding; filters pure whitespace tokens |
| **Search** | Emits explicit non-unknown candidates + 2-gram / 3-gram expansions for recall |
| **Full** | Reserved for API compatibility; behaves like Accurate in v0.1 |

## Architecture

```
UTF-8 text
  → Scanner (codepoints + byte/char offsets + class)
  → Dictionary Matcher (double-array trie walk + overlay trie)
  → Rule Matcher (mixed ASCII terms such as GPT-5.5 and onnxruntime-gpu)
  → Lattice (all candidate edges from dict/rule/unknown sources)
  → Viterbi Decoder (globally best path)
  → Token Stream (filtered, offset-preserving)
```

The core is a single Zig library (`libnexaloid`). Language bindings call the C ABI and do not reimplement tokenizer logic. The plugin ABI header is present for v0.2 work, but current runtime plugin loading is not implemented.

## Features

### Dictionary System

- **Base dictionary**: about 349k words, stored as a double-array trie; NXDICT base dictionaries can be memory-mapped on Windows
- **User dictionary**: runtime overlay trie, loaded from TSV or binary NXDICT format
- **Domain overlay**: loaded through the same user-dictionary overlay path via `NxConfig.user_dict_path`
- **Binary format (NXDICT)**: compact packed trie; the current bundled dictionary is about 38 MiB

### Performance

- **Batch tokenization**: native worker threads with in-order callback emission
- **Segmented long-input processing**: inputs split on sentence boundaries (newline, period, exclamation, CJK punctuation) into ≤512-char chunks
- **Lattice indexed by start character**: O(1) edge lookup per position
- **Thread model**: concurrent tokenization on one engine is allowed; do not call `nx_add_word` or `nx_reload_user_dict` while that same engine is tokenizing

### Cross-Language Consistency

All bindings call the same core tokenizer. Token text and offsets should match across bindings for the same input and dictionary.

### Plugin ABI

`core/include/nexaloid_plugin.h` defines 8 planned hook kinds: candidate provider, boundary scorer, edge scorer, token filter, token expander, POS tagger, entity recognizer, and normalizer. Runtime loading is reserved for v0.2+ and is not active in the current core.

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
| `source` | Origin: `base_dict`, `user_dict`, `rule`, or `unknown`; `domain_dict` and `plugin` are reserved source values |
| `score` | Decoder score (higher is better; log-probability for dict tokens) |

## Dictionary Management

Build the base dictionary from jieba's `dict.txt` plus a custom overlay. The command auto-detects an installed `jieba` package; otherwise pass `--jieba-dict path\to\dict.txt`.

```powershell
python tools/dict_builder.py --out data/dict/nexaloid.tsv
```

Compile to the packed NXDICT binary format. Windows base-dictionary loading can mmap this format.

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

# Windows: Go tests need the native DLL on PATH
$env:PATH = "$PWD\core\zig-out\bin;$env:PATH"
cd bindings\go
rtk go test ./nexaloid
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
