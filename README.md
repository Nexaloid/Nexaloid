# Nexaloid

Nexaloid is a Chinese tokenizer runtime, built in Zig with a stable C ABI and bindings for Python, Node.js, C++, Zig, Go, and Rust.

It is aimed at workloads where correctness, throughput, and cross-language consistency matter: search engines, RAG pipelines, e-commerce catalogs, and text analytics.

## What Nexaloid Is

- A dictionary-driven Chinese segmentation engine (double-array trie + Viterbi decoder)
- A search tokenizer that emits dictionary candidates plus 2-gram / 3-gram expansions for recall
- An **explainable** tokenizer: every token carries its origin (base dict, user dict, rule, or unknown fallback) and a score
- A runtime plugin ABI for optional CandidateProvider integrations; the core still runs without plugins
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
npm run test:binding
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

## Built-in Rule Configuration

The rule matcher protects structured tokens such as URLs, email addresses, ISO timestamps, Windows paths, IPv6 addresses, number+unit spans, market-day terms like `T+3日`, and mixed ASCII terms such as `GPT-5.5`.

Rules are enabled by default. Python can disable a built-in rule or override scores:

```python
from nexaloid import Tokenizer

tokenizer = Tokenizer(rule_config={
    "ascii_term": False,
    "scores": {
        "url": 120.0,
        "email": 120.0,
    },
})
```

Supported rule names are:

```text
url, email, timestamp, windows_path, ipv6, number_unit, market_day, ascii_term
```

Default scores are `300.0` for structured rules and `3.0` for `ascii_term`. Lower a score when the rule should lose more often to dictionary candidates; disable a rule when that token shape is noise for your domain.

Custom rules are loaded as JSON and parsed by the Zig core, not by language bindings. V4 supports six structured rule kinds:

```text
prefixed_number, charset_span, ascii_chain, number_unit, literal_sequence, contains_span
```

Common fields are `name`, `kind`, `score`, `enabled`, and `boundary`. `boundary` accepts `none`, `ascii`, or `ascii_or_han`.

```json
{
  "version": 1,
  "rules": [
    {
      "name": "stock",
      "kind": "prefixed_number",
      "prefixes": ["SH", "SZ", "HK"],
      "digits": {"min": 4, "max": 6},
      "score": 80
    },
    {
      "name": "sku",
      "kind": "charset_span",
      "charset": "A-Z0-9-_",
      "min_len": 4,
      "max_len": 32,
      "score": 60
    },
    {
      "name": "model_name",
      "kind": "ascii_chain",
      "charset": "A-Za-z0-9.-",
      "must_contain": ["-", "."],
      "min_len": 4,
      "max_len": 32,
      "score": 80
    },
    {
      "name": "dose",
      "kind": "number_unit",
      "units": ["mg", "%", "mmol/L"],
      "score": 90
    }
  ]
}
```

```python
tokenizer.load_rules_json(rules_json)
tokenizer.load_rules("rules.json")
tokenizer.clear_rules()
```

Node.js, C++, Zig, Go, and Rust expose the same `loadRulesJson` / `load_rules_json` / `LoadRulesJSON` style wrappers; C users call `nx_load_rules_json` directly. All wrappers pass JSON through to core so matching behavior stays identical across languages.

Audit custom rules against expected and rejected tokens:

```powershell
python tools/rule_audit.py data/rules/v4_sample_rules.json data/badcases/rules_v4.json
```

## Architecture

```
UTF-8 text
  → Scanner (codepoints + byte/char offsets + class)
  → Dictionary Matcher (double-array trie walk + overlay trie)
  → Rule Matcher (mixed ASCII terms such as GPT-5.5 and onnxruntime-gpu)
  → CandidateProvider Plugins (optional HMM/NER/domain candidates)
  → Lattice (all candidate edges from dict/rule/plugin/unknown sources)
  → Viterbi Decoder (globally best path)
  → Token Stream (filtered, offset-preserving)
```

The core is a single Zig library (`libnexaloid`). Language bindings call the C ABI and do not reimplement tokenizer logic. Runtime loading is implemented for CandidateProvider plugins; other plugin hook kinds are reserved.

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

`core/include/nexaloid_plugin.h` defines 8 hook kinds: candidate provider, boundary scorer, edge scorer, token filter, token expander, POS tagger, entity recognizer, and normalizer. The current runtime loads CandidateProvider plugins through `nx_load_plugin`; unsupported kinds are rejected. Plugins stream char-offset candidates into the lattice, and the core maps them back to byte offsets before Viterbi decoding.

### HMM Artifact

An optional BMES HMM lattice artifact is bundled at:

```text
data/hmm/bmes_hmm_wordhub_lattice.nxhmm
data/hmm/bmes_hmm_wordhub_lattice.manifest.json
```

This artifact is produced by the `NexaloidHMM` project and consumed by the optional HMM CandidateProvider plugin. It is packaged with Python, Node.js, Rust, and native SDK releases; HMM remains opt-in at the binding layer.

Bindings expose the bundled artifact path for plugin configuration:

```python
from nexaloid import hmm_artifact_path
print(hmm_artifact_path())
from nexaloid import hmm_manifest
print(hmm_manifest()["quality"]["lattice_heldout"]["token_f1"])
```

```javascript
const { hmmArtifactPath, hmmManifest } = require("@nexaloid/nexaloid");
console.log(hmmArtifactPath);
console.log(hmmManifest().quality.lattice_heldout.token_f1);
```

```rust
println!("{}", nexaloid::bundled_hmm_artifact_path().display());
```

The optional HMM plugin accepts either the artifact path directly or JSON config:

```json
{"artifact":"data/hmm/bmes_hmm_wordhub_lattice.nxhmm","hmm_score":-14.0}
```

`tools/hmm_score_audit.py` gates the default score against hand-picked risk cases, WordHub-derived runtime cases, and structured-token probes for URLs, email, ISO timestamps, Windows paths, addresses, and medical terms. In the current audit, `-20` under-recognizes unknown words, while `-8` starts over-merging examples such as `并参与`.

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
NxStatus  nx_set_rule_config(NxEngine *engine, uint32_t enabled_mask,
                             const float *scores, size_t score_count);
NxStatus  nx_load_rules_json(NxEngine *engine, const char *json,
                             size_t json_len);
NxStatus  nx_clear_rules(NxEngine *engine);
NxStatus  nx_load_plugin(NxEngine *engine, const char *plugin_path,
                         const char *config_json);
```

`enabled_mask` uses `1u << NxRuleId`; pass `NX_RULE_ALL_MASK` for defaults. `scores` may be `NULL`, or an array in `NxRuleId` order.

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
| `source` | Origin: `base_dict`, `user_dict`, `rule`, `unknown`, or `plugin`; `domain_dict` is reserved |
| `flags` | Extra metadata; custom rule tokens use a 1-based rule index for audit tooling |
| `score` | Decoder score (higher is better; log-probability for dict tokens) |

## Dictionary Management

Build the base dictionary from jieba's `dict.txt` plus a custom overlay. The command auto-detects an installed `jieba` package; otherwise pass `--jieba-dict path\to\dict.txt`.
`data/dict/demote.tsv` lowers scores for noisy base words before `overlay.tsv` applies manual boosts.

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

Import reviewed dictionary products from `NexaloidData` into generated base candidates. This does not modify the default dictionary. Raw domain dictionaries are skipped by default because they need separate review before use.

```powershell
python tools/import_nexaloid_data.py --data-root F:\Code\03_OpenCode\NexaloidData
python tools/validate_overlay.py data/dict/generated/overlay.generated.tsv
```

## Development

```powershell
cd core
rtk zig build          # compile the shared library
rtk zig build test     # run core tests
cd ..

# Python regression tests
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
| C | `core/include/` | Stable C ABI |
| Python | `bindings/python/` | jieba-compatible API, batch support |
| Node.js | `bindings/node/` | N-API native addon |
| C++ | `bindings/cpp/` | RAII wrapper, header-only |
| Zig | `bindings/zig/` | SDK wrapper over the C ABI |
| Go | `bindings/go/` | cgo binding |
| Rust | `bindings/rust/` | safe wrapper + `-sys` crate |

C, C++, and Zig users can consume language-specific native SDK zip files attached to GitHub Releases:

- `nexaloid-c-<version>-<platform>.zip`
- `nexaloid-cpp-<version>-<platform>.zip`
- `nexaloid-zig-<version>-<platform>.zip`
- `nexaloid-<version>-<platform>.zip` remains the combined native SDK

Native SDK assets are built for `linux-x64`, `windows-x64`, `darwin-x64`, `darwin-arm64`, `linux-arm64`, `windows-arm64`, `linux-musl`, `linux-armv7`, and `riscv64`. Each SDK contains headers, the platform native library, examples, and `data/dict/nexaloid.nxdict`.

Release branches `release/c`, `release/cpp`, and `release/zig` track the latest released language entry files; copy the matching release asset's `lib/` directory into the checkout to run examples. Python and npm packages stay limited to the targets that are built and executed in their package pipelines. Rust uses small target-specific native crates such as `nexaloid-sys-linux-x64` and `nexaloid-sys-darwin-arm64` so Cargo installs can stay below crates.io package size limits.
