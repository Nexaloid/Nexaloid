# Nexaloid

[English](README.md) | [中文](README.zh-CN.md)

Nexaloid is a Chinese tokenizer runtime. The core is implemented in Zig, exposes a stable C ABI, and ships bindings for Python, Node.js, C++, Zig, Go, and Rust.

It is designed for workloads that need correctness, throughput, and cross-language consistency, such as search engines, RAG pipelines, e-commerce catalogs, and text analytics.

---

## What Nexaloid Is

- A dictionary-based Chinese segmentation engine using a double-array trie and Viterbi decoding
- A conservative **Search** mode: it expands only the Accurate/Viterbi best path; **RecallSearch** is available when you need more aggressive candidate recall over all lattice edges
- An explainable tokenizer: every token carries source, offsets, and score
- An optional CandidateProvider plugin ABI; the core runs independently without plugins
- C ABI and language bindings preserve both UTF-8 byte offsets and Unicode character offsets

---

## Quick Start

### Python

```python
from nexaloid import Tokenizer

tokenizer = Tokenizer()
for token in tokenizer.tokenize("武汉市长江大桥"):
    print(token.text, token.start_byte, token.end_byte, token.source, token.score)

# jieba-compatible API
import nexaloid.compat_jieba as jieba
print(jieba.lcut("研究生命起源"))
# ['研究', '生命', '起源']
```

```powershell
$env:PYTHONPATH = "$PWD\bindings\python\src"
python -c "import nexaloid.compat_jieba as jieba; print(jieba.lcut('武汉市长江大桥'))"
```

#### jieba API Compatibility

Projects that already use jieba can keep common function names by changing the import:

```python
import nexaloid.compat_jieba as jieba
```

The currently compatible module-level APIs include `cut`, `lcut`, `cut_for_search`, `lcut_for_search`, `load_userdict`, `add_word`, `del_word`, and `suggest_freq`.

`cut` returns an iterator of strings, and `lcut` returns a list. `cut_for_search` uses the conservative `Search` mode, which avoids cross-boundary candidates such as `市长` in `武汉市长江大桥`; use the native `Mode.RECALL_SEARCH` when you need more aggressive recall. `load_userdict` accepts jieba-style `word freq tag` text dictionaries. Passing `tag` to `add_word` emits a warning because POS tagging is unavailable, while `use_paddle=True` raises `NotImplementedError`; `HMM=True` loads the bundled BMES HMM plugin to recover unknown words. Use `nexaloid.Tokenizer` directly when you need offsets, source, score, or batch tokenization.

### Node.js

```javascript
const { Tokenizer } = require("@nexaloid/nexaloid");

const tokenizer = new Tokenizer();
console.log(tokenizer.lcut("武汉市长江大桥"));
// ['武汉市', '长江大桥']
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
cfg.dict_path = "data/dict/nexaloid.tsv";   // .nxdict is also supported
nexaloid::Tokenizer tokenizer(cfg);
for (const auto& word : tokenizer.cut("武汉市长江大桥"))
    std::cout << word << "\n";
```

### Go

```go
tokenizer, _ := nexaloid.New("data/dict/nexaloid.tsv")
defer tokenizer.Close()
tokens, _ := tokenizer.Tokenize("武汉市长江大桥", nexaloid.Accurate)
```

### Rust

```rust
use nexaloid::{Mode, Tokenizer};

let tokenizer = Tokenizer::new_default()?;
let tokens = tokenizer.tokenize("武汉市长江大桥", Mode::Accurate)?;
```

---

## Tokenization Modes

| Mode | Behavior |
|------|----------|
| **Accurate** | Viterbi shortest-path decoding; pure whitespace tokens are filtered by default, unless `preserve_whitespace` is enabled |
| **Search** | Runs Accurate first, then expands tokens on the best path with Han 2-gram / 3-gram tokens; avoids cross-boundary semantic noise |
| **RecallSearch** | Does not depend on the best path; expands all lattice candidate edges with Han 2-gram / 3-gram tokens for maximum recall |
| **Full** | Kept for compatibility with jieba's `cut_all` / full-mode API shape; in the current version it behaves exactly like Accurate |

---

## Whitespace

Nexaloid filters pure whitespace tokens by default, which is usually better for search and RAG pipelines. Enable whitespace preservation when you need to reconstruct the input shape; spaces, tabs, newlines, full-width spaces, and similar spans are emitted as standalone tokens:

```python
tokenizer = Tokenizer(preserve_whitespace=True)
print(tokenizer.lcut("中文 English\t混排\n第二行"))
# ['中文', ' ', 'English', '\t', '混排', '\n', '第二行']
```

The same switch is exposed through `NxConfig.preserve_whitespace` in the C ABI and through constructor options in each language binding.

---

## Default Dictionary and Formats

The core engine supports both the text format (`.tsv`) and the binary packed-trie format (`.nxdict`).
`.nxdict` is compact, about 38 MiB, loads quickly, and can be memory-mapped on Windows. `.tsv` must be parsed and inserted line by line, so startup is slower; it is mainly useful for development and debugging. Use `.nxdict` in production.

Default constructor behavior by binding:

| Language | Default dictionary behavior |
|----------|-----------------------------|
| **Python** | `Tokenizer()` first looks for packaged `nexaloid.nxdict`, then falls back to `.tsv` |
| **Node.js** | `new Tokenizer()` loads `data/dict/nexaloid.tsv` by default |
| **Rust** | `Tokenizer::new_default()` loads the bundled `nexaloid.nxdict` |
| **C++** | `Tokenizer(NxConfig{})` does not auto-load a dictionary; set `dict_path` explicitly |
| **Go** | `New("")` does not auto-load a dictionary; pass a path or use `NewWithOptions` |

---

## Built-in Rule Configuration

The rule matcher adds candidates for structured tokens such as URLs, email addresses, ISO timestamps, Windows paths, IPv6 addresses, number-unit spans, market-day expressions such as `T+3日`, and mixed ASCII terms such as `GPT-5.5`. Built-in rules are enabled by default.

### Configurable Built-in Rules

| Rule name | Example | Default score |
|-----------|---------|---------------|
| `url` | `https://example.com/path` | 300.0 |
| `email` | `user@example.com` | 300.0 |
| `timestamp` | `2025-03-15T10:30:00` | 300.0 |
| `windows_path` | `C:\Users\name\file.txt` | 300.0 |
| `ipv6` | `::1`, `2001:db8::1` | 300.0 |
| `number_unit` | `100mg`, `5%` | 300.0 |
| `market_day` | `T+3日`, `T-1日` | 300.0 |
| `ascii_term` | `onnxruntime-gpu`, `GPT-5.5` | 3.0 |

Scores are internal decoder weights, not strict probabilities. During Viterbi decoding, each candidate edge's `score` is added directly to the path base score. A high score such as 300.0 strongly protects structured tokens from being split, while a low score such as 3.0 for `ascii_term` can still lose to higher-scoring dictionary entries.

### Configuration Example

```python
from nexaloid import Tokenizer

tokenizer = Tokenizer(rule_config={
    "ascii_term": False,        # Disable the ascii_term rule
    "scores": {
        "url": 120.0,
        "email": 120.0,
    },
})
```

> Rule configuration only controls candidates generated by rules. Entries from the base or user dictionary can still cover the same span and keep their own source. For example, if `GPT-5.5` already exists in the dictionary, the final token may have `source=base_dict` even though the `ascii_term` rule can also propose the same span.

---

## Custom Rules

Custom rules are defined as JSON, parsed by the Zig core, and behave consistently across all language bindings.

### Supported Rule Kinds

| Kind | Description | Example |
|------|-------------|---------|
| `prefixed_number` | Prefix + digits | `SH600519` |
| `charset_span` | Continuous span constrained to a charset | Uppercase alphanumeric SKU |
| `ascii_chain` | Constrained charset span that must contain specified substrings | `onnxruntime-gpu` |
| `number_unit` | Number + unit | `50mg`, `10%` |
| `literal_sequence` | Ordered sequence of literals, numbers, or charset spans | `T+3日`-style expressions |
| `contains_span` | Left boundary + middle charset span + right boundary | Domain-specific wrapped formats |

Common fields are `name`, `kind`, `score`, `enabled`, and `boundary`. `boundary` accepts `none`, `ascii`, or `ascii_or_han`.

### JSON Rule Example

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

### Loading APIs

| Function | Description |
|----------|-------------|
| `load_rules_json(json_str)` | Load rules from a JSON string |
| `load_rules(file_path)` | Load rules from a JSON file |
| `clear_rules()` | Clear all custom rules |

All bindings (C, Node.js, C++, Zig, Go, Rust) expose equivalent functions and pass JSON through to the core unchanged, keeping matching behavior consistent.

### Custom Rule Token Flags

For tokens produced by custom rules, the `flags` field stores the **1-based index in the JSON rules array**. The first rule has index 1. This index applies only to custom rules and does not include built-in rules. Disabled rules still occupy their array position, so indexes remain stable for auditing and debugging.

### Audit Tool

```powershell
python tools/rule_audit.py data/rules/v4_sample_rules.json data/badcases/rules_v4.json
```

---

## Architecture

```text
UTF-8 text
  -> Scanner (codepoints + byte/char offsets + class)
  -> Dictionary Matcher (double-array trie traversal + overlay trie)
  -> Rule Matcher (built-in/custom rules)
  -> CandidateProvider Plugins (optional HMM/NER/domain candidates)
  -> Lattice (all candidate edges from dict/rule/plugin/unknown sources)
  -> Viterbi Decoder (globally best path)
  -> Token Stream (filtering, offset preservation)
```

The core is a single Zig library, `libnexaloid`. All language bindings call the C ABI and do not reimplement tokenization logic. Runtime plugins currently support only CandidateProvider; the other hook kinds are reserved ABI surface.

### Core Source Files

| File | Responsibility |
|------|----------------|
| `core/src/matcher/rule_matcher.zig` | Rule matcher facade and built-in/custom rule orchestration |
| `core/src/matcher/rule_config.zig` | Rule IDs, default scores, enabled masks |
| `core/src/matcher/builtin_rules.zig` | Built-in structured rules for URL, email, IPv6, and similar tokens |
| `core/src/matcher/custom_rules.zig` | Custom rule facade |
| `core/src/matcher/custom_rule_types.zig` | Shared custom-rule structures and limits |
| `core/src/matcher/custom_rule_parser.zig` | Custom-rule JSON parsing |
| `core/src/matcher/custom_rule_matcher.zig` | Custom-rule runtime matching |

---

## Features

### Dictionary System

| Feature | Description |
|---------|-------------|
| Base dictionary | About 349k words, double-array trie; can be memory-mapped on Windows |
| User dictionary | Runtime overlay trie, supports TSV or binary NXDICT |
| Domain overlay | Loaded through `NxConfig.user_dict_path` and handled by the same overlay path |
| NXDICT binary | Compact packed trie, about 38 MiB, fast loading, mmap-capable |

### Performance

| Feature | Description |
|---------|-------------|
| Batch tokenization | Uses parallel worker threads only when no plugins are loaded. Loading any plugin, including the HMM CandidateProvider, currently serializes batch work because plugin thread safety is not part of the ABI. Callbacks/results are still emitted in input-array order, while token order within each input is unchanged |
| Long-text segmentation | Splits on sentence boundaries into chunks of at most 512 characters |
| Lattice index | O(1) candidate edge lookup by start character |
| Thread model | Without plugins, the same engine can tokenize concurrently. With plugins, callers must serialize calls unless every loaded plugin documents its own thread safety; the plugin ABI does not guarantee it. Do not call `nx_add_word` or `nx_reload_user_dict` while tokenization is running on that engine |

### Cross-Language Consistency

All bindings call the same core engine. With the same input and dictionary, token text and offsets should match exactly across languages.

### Plugin ABI

`core/include/nexaloid_plugin.h` defines eight hook interfaces. Only CandidateProvider is currently available; the others are reserved.

| Hook kind | ID | Description | Status |
|-----------|----|-------------|--------|
| Candidate Provider | 1 | Inject extra candidate edges into the lattice | Implemented |
| Boundary Scorer | 2 | Adjust boundary weights | Reserved |
| Edge Scorer | 3 | Adjust edge weights | Reserved |
| Token Filter | 4 | Filter tokens | Reserved |
| Token Expander | 5 | Expand tokens | Reserved |
| POS Tagger | 6 | Part-of-speech tagging | Reserved |
| Entity Recognizer | 7 | Entity recognition | Reserved |
| Normalizer | 8 | Text normalization | Reserved |

Plugins are loaded through `nx_load_plugin`. They write candidates into the lattice using character offsets, and the core maps those offsets back to byte offsets before Viterbi decoding.

### HMM Plugin

The optional BMES HMM lattice artifact is located at:

```text
data/hmm/bmes_hmm_wordhub_lattice.nxhmm
data/hmm/bmes_hmm_wordhub_lattice.manifest.json
```

This artifact is produced by the `NexaloidHMM` project and consumed by the HMM CandidateProvider plugin. It is packaged with Python, Node.js, Rust, and native SDK releases, and remains opt-in at the binding layer.

Bindings expose the bundled artifact path:

```python
from nexaloid import hmm_artifact_path, hmm_manifest
print(hmm_artifact_path())
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

HMM plugin configuration example, accepting either an artifact path or JSON:

```json
{"artifact":"data/hmm/bmes_hmm_wordhub_lattice.nxhmm","hmm_score":-14.0}
```

`hmm_score` is an empirical weight used directly as the candidate edge score during Viterbi decoding. It is added with rule scores and dictionary log-probabilities, and controls the merge strength for unknown words. The default value, -14.0, is audited with manually selected risk cases, WordHub cases, and structured-token probes (`tools/hmm_score_audit.py`) to balance recall and segmentation precision.

### Entity BMES Plugin

`tools/entity_bmes_plugin.zig` is a model-backed CandidateProvider for entity nouns. It memory-maps a `.nxbmes` artifact produced by the separate `NexaloidBMES` project and runs an O/B/M/E/S averaged-perceptron decoder with hashed character, character-class, and gazetteer features. It remains opt-in and can propose entities that are absent from the base dictionary.

Source checkouts can build and stage the native plugin after building the core library:

```powershell
python tools/stage_assets.py
```

Load the plugin with either an artifact path or JSON configuration:

```json
{"artifact":"data/entity/entity_bmes_perceptron.nxbmes","score_per_char":60.0,"edge_penalty":10.0,"min_chars":2,"max_chars":64,"flags":4}
```

Python packages expose both bundled paths:

```python
import json
from nexaloid import Tokenizer, entity_artifact_path, entity_plugin_path

tokenizer = Tokenizer()
tokenizer.load_plugin(
    entity_plugin_path(),
    json.dumps({"artifact": str(entity_artifact_path())}),
)
```

Candidate scores are `score_per_char * character_length - edge_penalty`. ASCII entities require ASCII boundaries; emitted tokens use `source=plugin`, and `flags` defaults to `4` so it does not overlap the HMM plugin's `1`/`2` values. The bundled release-safe model is trained from THUOCL (MIT), JD comments (Apache-2.0), and deterministic synthetic examples; its manifest reports dev F1 `0.793487` and test F1 `0.864987`. As with every loaded plugin, batch tokenization is currently serialized.

---

## C ABI

All exported functions use the `nx_` prefix. The main header is `core/include/nexaloid.h`.

| Function | Purpose |
|----------|---------|
| `nx_engine_new` | Create an engine instance |
| `nx_engine_free` | Destroy an engine |
| `nx_tokenize` | Tokenize one input |
| `nx_tokenize_batch` | Batch tokenization with configurable thread count |
| `nx_add_word` | Add a word dynamically at runtime |
| `nx_reload_user_dict` | Reload the user dictionary |
| `nx_set_rule_config` | Set built-in rule enable masks and scores |
| `nx_load_rules_json` | Load custom rules from JSON |
| `nx_clear_rules` | Clear all custom rules |
| `nx_load_plugin` | Load a dynamic plugin |

Detailed declarations:

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

`enabled_mask` uses `1u << NxRuleId`; pass `NX_RULE_ALL_MASK` for defaults. `scores` may be `NULL`, or an array ordered by `NxRuleId`.

Headers: `core/include/nexaloid.h`, `core/include/nexaloid_plugin.h`

---

## Token Output

Every token contains these fields:

| Field | Description |
|-------|-------------|
| `text` | Matched substring |
| `start_byte` / `end_byte` | UTF-8 byte offsets in the original input |
| `start_char` / `end_char` | Unicode codepoint offsets |
| `word_id` | Dictionary word ID; 0 for unknown and rule tokens |
| `pos_id` | POS ID, reserved and unresolved in v0.1 |
| `source` | Origin: `base_dict`, `user_dict`, `rule`, `unknown`, or `plugin`; `domain_dict` is reserved |
| `flags` | Extra metadata; for custom-rule tokens, `flags` is the 1-based index in the JSON rules array |
| `score` | Internal decoder weight; higher is better. Scores from different sources are added directly and are not forced into a single probability scale |

---

## Dictionary Management

### Build the Base Dictionary

```powershell
python tools/dict_builder.py --out data/dict/nexaloid.tsv
```

The command auto-detects an installed `jieba` package; otherwise pass `--jieba-dict` with a `dict.txt` path. `data/dict/demote.tsv` lowers noisy base-word scores before `overlay.tsv` applies manual weighting.

### Compile Binary NXDICT

```powershell
python tools/nxdict_builder.py data/dict/nexaloid.tsv data/dict/nexaloid.nxdict
```

### Validate Overlay

```powershell
python tools/validate_overlay.py data/dict/overlay.tsv
```

### Maintainer Flow: Import NexaloidData

> Normal users do not need this step. It is used to import reviewed candidate entries from the external `NexaloidData` repository.

```powershell
python tools/import_nexaloid_data.py --data-root F:\Code\03_OpenCode\NexaloidData
python tools/validate_overlay.py data/dict/generated/overlay.generated.tsv
```

---

## Development

```powershell
cd core
zig build          # Build the shared library
zig build test     # Run core tests
cd ..

# Python regression tests
$env:PYTHONPATH = "$PWD\bindings\python\src"
python tools\badcase_runner.py
python tools\validate_overlay.py
python tools\benchmark.py

# Windows: Go tests need the native DLL on PATH
$env:PATH = "$PWD\core\zig-out\bin;$env:PATH"
cd bindings\go
go test ./nexaloid
```

## Benchmark

```powershell
$env:PYTHONPATH = "$PWD\bindings\python\src"
python tools\benchmark.py -n 1000
```

---

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

### Using the Native SDK (C / C++ / Zig)

1. Check out the matching release branch: `release/c`, `release/cpp`, or `release/zig`
2. Download the zip for the same version and platform from [GitHub Releases](https://github.com/Nexaloid/Nexaloid/releases)
3. Extract it, then copy the zip's `lib/` directory into the root of your cloned checkout
4. Build and run the examples

Each SDK contains headers, the platform native library, examples, and `data/dict/nexaloid.nxdict`.

### Covered Platforms

| Platform |
|----------|
| linux-x64 |
| windows-x64 |
| darwin-x64 |
| darwin-arm64 |
| linux-arm64 |
| windows-arm64 |
| linux-musl |
| linux-armv7 |
| riscv64 |

Python and npm packages cover only the platforms that their pipelines actually build and test. Rust uses more granular target-specific native crates, such as `nexaloid-sys-linux-x64`, to stay within crates.io package size limits.
