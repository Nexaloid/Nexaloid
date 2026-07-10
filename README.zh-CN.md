# Nexaloid

[English](README.md) | [中文](README.zh-CN.md)

Nexaloid 是一个中文分词运行时。核心用 Zig 实现，提供稳定的 C ABI，并带有 Python、Node.js、C++、Zig、Go 和 Rust 绑定。

面向需要正确性、吞吐和跨语言一致性的场景，例如搜索引擎、RAG 管道、电商商品库和文本分析。

---

## Nexaloid 是什么

- 基于词典的中文分词引擎，使用双数组 trie 和 Viterbi 解码
- 提供保守的 **Search** 模式：只对 Accurate/Viterbi 最优路径做搜索扩展；另有 **RecallSearch** 模式用于对所有候选边进行更激进的召回
- 可解释的分词器：每个 token 都携带来源、偏移和分数
- 可选 CandidateProvider 插件 ABI；无插件时核心可独立运行
- C ABI 与所有语言绑定均保留 UTF‑8 字节偏移和 Unicode 字符偏移

---

## 快速开始

### Python

```python
from nexaloid import Tokenizer

tokenizer = Tokenizer()
for token in tokenizer.tokenize("武汉市长江大桥"):
    print(token.text, token.start_byte, token.end_byte, token.source, token.score)

# jieba 兼容 API
import nexaloid.compat_jieba as jieba
print(jieba.lcut("研究生命起源"))
# ['研究', '生命', '起源']
```

```powershell
$env:PYTHONPATH = "$PWD\bindings\python\src"
python -c "import nexaloid.compat_jieba as jieba; print(jieba.lcut('武汉市长江大桥'))"
```

#### jieba API 兼容

已使用 jieba 的项目可以通过替换导入语句保留常见函数名：

```python
import nexaloid.compat_jieba as jieba
```

当前兼容的模块级 API 包括 `cut`、`lcut`、`cut_for_search`、`lcut_for_search`、`load_userdict`、`add_word`、`del_word` 和 `suggest_freq`。

`cut` 返回字符串迭代器，`lcut` 返回列表。`cut_for_search` 使用保守的 `Search` 模式，会避免如 `武汉市长江大桥` 中 `市长` 这类跨边界候选；需更激进召回时请直接使用原生 `Mode.RECALL_SEARCH`。`load_userdict` 接受 jieba 风格的 `word freq tag` 文本词典。`tag` 与 `use_paddle` 仅为兼容 API 形状而接受，当前会忽略；`HMM=True` 不会被忽略，它会加载内置 BMES HMM 插件来恢复未知词。需要 offset、source、score 或批处理时，请直接使用 `nexaloid.Tokenizer`。

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
cfg.dict_path = "data/dict/nexaloid.tsv";   // 同样支持 .nxdict
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

## 分词模式

| 模式 | 行为 |
|------|------|
| **Accurate** | Viterbi 最短路径解码；默认过滤纯空白 token（可通过 `preserve_whitespace` 关闭过滤） |
| **Search** | 先执行 Accurate 获得最优路径，再对最优路径上的 token 进行汉字 2‑gram / 3‑gram 扩展，避免跨边界语义噪声 |
| **RecallSearch** | 不依赖最优路径，直接对全部 lattice 候选边进行汉字 2‑gram / 3‑gram 扩展，用于最大化召回 |
| **Full** | 为兼容 jieba 的 `cut_all` / 全模式 API 形状而保留；当前版本行为完全等同于 Accurate |

---

## 空白字符

Nexaloid 默认过滤纯空白 token，这通常更适合搜索和 RAG 管道。开启空白保留后，空格、tab、换行、全角空格等会作为独立 token 输出，便于需要还原输入形状的场景：

```python
tokenizer = Tokenizer(preserve_whitespace=True)
print(tokenizer.lcut("中文 English\t混排\n第二行"))
# ['中文', ' ', 'English', '\t', '混排', '\n', '第二行']
```

该开关同时通过 C ABI 的 `NxConfig.preserve_whitespace` 以及各语言绑定的构造参数暴露。

---

## 默认词典与格式

核心引擎同时支持文本格式（`.tsv`）和二进制 packed trie 格式（`.nxdict`）。  
`.nxdict` 体积紧凑（约 38 MiB），加载迅速，Windows 上可 mmap；`.tsv` 需逐行解析插入，启动较慢，主要用于开发和调试。生产环境推荐使用 `.nxdict`。

各语言绑定的默认构造行为：

| 语言 | 默认词典加载方式 |
|------|----------------|
| **Python** | `Tokenizer()` 优先查找包内 `nexaloid.nxdict`，回退到 `.tsv` |
| **Node.js** | `new Tokenizer()` 默认加载 `data/dict/nexaloid.tsv` |
| **Rust** | `Tokenizer::new_default()` 加载内置 `nexaloid.nxdict` |
| **C++** | `Tokenizer(NxConfig{})` 不自动加载词典，需显式设置 `dict_path` |
| **Go** | `New("")` 不自动加载词典，需传入路径或使用 `NewWithOptions` |

---

## 内置规则配置

规则匹配器会为结构化 token 添加候选，例如 URL、email、ISO 时间戳、Windows 路径、IPv6、数字单位、`T+3日` 这样的市场日表达，以及 `GPT-5.5` 这样的混合 ASCII 术语。规则默认启用。

### 可配置的内置规则

| 规则名 | 识别示例 | 默认分数 |
|--------|----------|----------|
| `url` | `https://example.com/path` | 300.0 |
| `email` | `user@example.com` | 300.0 |
| `timestamp` | `2025-03-15T10:30:00` | 300.0 |
| `windows_path` | `C:\Users\name\file.txt` | 300.0 |
| `ipv6` | `::1`, `2001:db8::1` | 300.0 |
| `number_unit` | `100mg`, `5%` | 300.0 |
| `market_day` | `T+3日`, `T-1日` | 300.0 |
| `ascii_term` | `onnxruntime-gpu`, `GPT-5.5` | 3.0 |

分数是解码器内部权重，并非严格概率。Viterbi 解码时会将候选边的 `score` 与路径基础分数直接相加：300.0 的高分用于强保护（避免结构化 token 被切碎），3.0 的低分则容易被高分词典词条覆盖。

### 配置示例

```python
from nexaloid import Tokenizer

tokenizer = Tokenizer(rule_config={
    "ascii_term": False,        # 禁用 ascii_term 规则
    "scores": {
        "url": 120.0,
        "email": 120.0,
    },
})
```

> 规则配置仅控制规则生成的候选；base/user 词典中的词条仍可能覆盖同一片段并保留其来源。例如 `GPT-5.5` 若已在词典中，最终可能呈现 `source=base_dict`，尽管 `ascii_term` 规则也能提出同一跨度。

---

## 自定义规则

自定义规则以 JSON 定义，由 Zig 核心解析，所有语言绑定行为一致。

### 支持的规则类型

| 类型 | 说明 | 示例 |
|------|------|------|
| `prefixed_number` | 前缀 + 数字 | `SH600519` |
| `charset_span` | 限定字符集连续片段 | 纯大写+数字 SKU |
| `ascii_chain` | 限定字符集，且必须包含指定子串 | `onnxruntime-gpu` |
| `number_unit` | 数字 + 单位 | `50mg`, `10%` |
| `literal_sequence` | 按顺序匹配 literal、数字或字符集 | `T+3日` 风格表达式 |
| `contains_span` | 左边界 + 中间字符集片段 + 右边界 | 领域特定包裹格式 |

公共字段：`name`、`kind`、`score`、`enabled`、`boundary`（取值 `none` / `ascii` / `ascii_or_han`）。

### JSON 规则示例

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

### 加载接口

| 函数 | 说明 |
|------|------|
| `load_rules_json(json_str)` | 从 JSON 字符串加载规则 |
| `load_rules(file_path)` | 从 JSON 文件加载规则 |
| `clear_rules()` | 清空所有自定义规则 |

所有绑定（C、Node.js、C++、Zig、Go、Rust）均提供等效函数，并将 JSON 原样传递给核心，确保匹配行为一致。

### 自定义规则 token 的 flags

自定义规则产生的 token，其 `flags` 字段为 **JSON 规则数组中的 1‑based 索引**（第一条规则索引为 1）。该索引仅对自定义规则生效，不包含内置规则。禁用的规则仍占据数组位置，因此索引稳定，便于审计和调试。

### 审计工具

```powershell
python tools/rule_audit.py data/rules/v4_sample_rules.json data/badcases/rules_v4.json
```

---

## 架构

```text
UTF-8 text
  → Scanner（codepoints + byte/char offsets + class）
  → Dictionary Matcher（双数组 trie 遍历 + overlay trie）
  → Rule Matcher（内置/自定义规则）
  → CandidateProvider Plugins（可选 HMM/NER/领域候选）
  → Lattice（所有来自 dict/rule/plugin/unknown 的候选边）
  → Viterbi Decoder（全局最优路径）
  → Token Stream（过滤、偏移保持）
```

核心为单个 Zig 库 `libnexaloid`。所有语言绑定均通过 C ABI 调用，不重新实现分词逻辑。运行时插件目前仅支持 CandidateProvider；其余 hook 类型为 ABI 预留。

### 核心源码文件

| 文件 | 职责 |
|------|------|
| `core/src/matcher/rule_matcher.zig` | 规则匹配 facade，及内置/自定义规则编排 |
| `core/src/matcher/rule_config.zig` | 规则 ID、默认分数、启用掩码 |
| `core/src/matcher/builtin_rules.zig` | 内置结构化规则（URL、email、IPv6 等） |
| `core/src/matcher/custom_rules.zig` | 自定义规则 facade |
| `core/src/matcher/custom_rule_types.zig` | 自定义规则共享结构与限制 |
| `core/src/matcher/custom_rule_parser.zig` | 自定义规则 JSON 解析 |
| `core/src/matcher/custom_rule_matcher.zig` | 自定义规则运行时匹配 |

---

## 功能

### 词典系统

| 特性 | 说明 |
|------|------|
| 基础词典 | 约 34.9 万词，双数组 trie；Windows 上可 mmap |
| 用户词典 | 运行时 overlay trie，支持 TSV 或二进制 NXDICT |
| 领域 overlay | 通过 `NxConfig.user_dict_path` 加载，走同一 overlay 路径 |
| NXDICT 二进制 | 紧凑 packed trie，约 38 MiB，加载快、可 mmap |

### 性能

| 特性 | 说明 |
|------|------|
| 批量分词 | 仅在未加载插件时使用多线程并行。加载任意插件（包括 HMM CandidateProvider）后，当前会串行执行，因为插件 ABI 尚未约定线程安全；回调仍严格按输入数组顺序输出，每条输入内 token 顺序不变 |
| 长文本分段 | 按句子边界切分为不超过 512 字符的片段 |
| lattice 索引 | 按起始字符 O(1) 查找候选边 |
| 线程模型 | 未加载插件时，同一 engine 可并发分词；加载插件后，除非所有插件都明确保证线程安全，否则调用方应自行串行化，因为插件 ABI 不提供该保证。分词期间不要调用 `nx_add_word` 或 `nx_reload_user_dict` |

### 跨语言一致性

所有绑定调用同一核心引擎。在相同输入和词典下，各语言产出的 token 文本和偏移应完全一致。

### 插件 ABI

`core/include/nexaloid_plugin.h` 定义了 8 类 hook 接口，当前仅 CandidateProvider 可用，其余为预留。

| Hook 类型 | ID | 说明 | 状态 |
|-----------|----|------|------|
| Candidate Provider | 1 | 向 lattice 注入额外候选边 | ✅ 已实现 |
| Boundary Scorer | 2 | 调整边界权重 | ❌ 预留 |
| Edge Scorer | 3 | 调整边权重 | ❌ 预留 |
| Token Filter | 4 | 过滤 token | ❌ 预留 |
| Token Expander | 5 | 扩展 token | ❌ 预留 |
| POS Tagger | 6 | 词性标注 | ❌ 预留 |
| Entity Recognizer | 7 | 实体识别 | ❌ 预留 |
| Normalizer | 8 | 文本归一化 | ❌ 预留 |

插件通过 `nx_load_plugin` 加载，以字符偏移形式向 lattice 写入候选，核心会在 Viterbi 解码前映射回字节偏移。

### HMM 插件

可选 BMES HMM lattice artifact 位于：

```text
data/hmm/bmes_hmm_wordhub_lattice.nxhmm
data/hmm/bmes_hmm_wordhub_lattice.manifest.json
```

该 artifact 由 `NexaloidHMM` 项目生成，由 HMM CandidateProvider 插件消费，随 Python、Node.js、Rust 和 native SDK release 打包，绑定层为 opt‑in。

绑定暴露的内置 artifact 路径：

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

HMM 插件配置示例（接受 artifact 路径或 JSON）：

```json
{"artifact":"data/hmm/bmes_hmm_wordhub_lattice.nxhmm","hmm_score":-14.0}
```

`hmm_score` 是经验权重，直接作为候选边分数参与 Viterbi 解码（与规则分数、词典 log-probability 直接相加），用于控制未知词合并强度。默认值 -14.0 经过人工风险用例、WordHub 用例及结构化 token 探针审计（`tools/hmm_score_audit.py`），在召回与切分精度间取得平衡。

### 实体 BMES 插件（开发版）

`tools/entity_bmes_plugin.zig` 是面向实体名词的模型型 CandidateProvider。它通过 mmap 加载独立 `NexaloidBMES` 项目产出的 `.nxbmes` artifact，使用带字符、字符类别和 gazetteer 哈希特征的 O/B/M/E/S 平均感知机解码器，可以提出基础词典中不存在的实体候选，默认仍为显式启用。

```powershell
zig build-lib -dynamic -lc --name nexaloid_plugin_entity_bmes tools/entity_bmes_plugin.zig
```

加载插件时可直接传入 artifact 路径，也可使用 JSON 配置：

```json
{"artifact":"entity_bmes_perceptron.nxbmes","score_per_char":60.0,"edge_penalty":10.0,"min_chars":2,"max_chars":64,"flags":4}
```

候选分数为 `score_per_char * 字符数 - edge_penalty`。ASCII 实体要求 ASCII 边界；输出 token 的 `source=plugin`，`flags` 默认为 `4`，与 HMM 插件使用的 `1`/`2` 不冲突。当前训练 artifact 的上游数据许可尚未满足公开商业发布要求，因此主仓库不会将其打入发行包，使用时需显式提供本地 artifact。未来完成清权的模型会按固定版本和 SHA-256 拉取，并作为独立的 `nexaloid-entity-bmes-<version>.zip` 发行附件发布。与其他插件相同，加载后批量分词当前会串行执行。

---

## C ABI

所有函数均以 `nx_` 前缀导出，头文件位于 `core/include/nexaloid.h`。

| 函数 | 用途 |
|------|------|
| `nx_engine_new` | 创建引擎实例 |
| `nx_engine_free` | 销毁引擎 |
| `nx_tokenize` | 单条文本分词 |
| `nx_tokenize_batch` | 批量分词（可指定线程数） |
| `nx_add_word` | 运行时动态添加词条 |
| `nx_reload_user_dict` | 重新加载用户词典 |
| `nx_set_rule_config` | 设置内置规则启用掩码及分数 |
| `nx_load_rules_json` | 加载自定义规则 JSON |
| `nx_clear_rules` | 清空所有自定义规则 |
| `nx_load_plugin` | 加载动态插件 |

详细函数声明：

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

`enabled_mask` 使用 `1u << NxRuleId`；默认值可传 `NX_RULE_ALL_MASK`。`scores` 可为 `NULL`，或提供按 `NxRuleId` 顺序排列的数组。

头文件：`core/include/nexaloid.h`、`core/include/nexaloid_plugin.h`

---

## Token 输出

每个 token 包含以下字段：

| 字段 | 说明 |
|------|------|
| `text` | 匹配到的子串 |
| `start_byte` / `end_byte` | 原始输入中的 UTF‑8 字节偏移 |
| `start_char` / `end_char` | Unicode 码点偏移 |
| `word_id` | 词典词 ID（unknown / rule token 为 0） |
| `pos_id` | 词性 ID（v0.1 中保留且未解析） |
| `source` | 来源：`base_dict`、`user_dict`、`rule`、`unknown` 或 `plugin`；`domain_dict` 保留 |
| `flags` | 附加元数据；对于自定义规则 token，`flags` 为 JSON 规则数组的 1‑based 索引 |
| `score` | 解码器内部权重，越高越好；不同来源分数直接相加，不强制统一概率量纲 |

---

## 词典管理

### 构建基础词典

```powershell
python tools/dict_builder.py --out data/dict/nexaloid.tsv
```

命令会自动发现已安装的 `jieba` 包；否则可通过 `--jieba-dict` 指定 `dict.txt`。`data/dict/demote.tsv` 会在 `overlay.tsv` 手工加权前降低噪声基础词的分数。

### 编译为二进制 NXDICT

```powershell
python tools/nxdict_builder.py data/dict/nexaloid.tsv data/dict/nexaloid.nxdict
```

### 验证 overlay

```powershell
python tools/validate_overlay.py data/dict/overlay.tsv
```

### 维护者流程：导入 NexaloidData

> 普通用户无需关心此步骤。以下用于从外部 `NexaloidData` 仓库导入已审查的候选词条。

```powershell
python tools/import_nexaloid_data.py --data-root F:\Code\03_OpenCode\NexaloidData
python tools/validate_overlay.py data/dict/generated/overlay.generated.tsv
```

---

## 开发

```powershell
cd core
zig build          # 编译共享库
zig build test     # 运行核心测试
cd ..

# Python 回归测试
$env:PYTHONPATH = "$PWD\bindings\python\src"
python tools\badcase_runner.py
python tools\validate_overlay.py
python tools\benchmark.py

# Windows: Go 测试需将 native DLL 加入 PATH
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

## 语言绑定

| 语言 | 目录 | 状态 |
|------|------|------|
| C | `core/include/` | 稳定 C ABI |
| Python | `bindings/python/` | jieba 兼容 API，支持 batch |
| Node.js | `bindings/node/` | N-API native addon |
| C++ | `bindings/cpp/` | RAII wrapper，header‑only |
| Zig | `bindings/zig/` | 基于 C ABI 的 SDK wrapper |
| Go | `bindings/go/` | cgo binding |
| Rust | `bindings/rust/` | safe wrapper + `-sys` crate |

### 使用 Native SDK（C / C++ / Zig）

1. 切换到对应 release 分支：`release/c`、`release/cpp` 或 `release/zig`
2. 从 [GitHub Releases](https://github.com/Nexaloid/Nexaloid/releases) 下载相同版本、相同平台的 zip 包
3. 解压后，将 zip 内的 `lib/` 目录复制到你 clone 的仓库根目录
4. 按示例编译运行

每个 SDK 包含头文件、平台 native library、示例和 `data/dict/nexaloid.nxdict`。

### 覆盖的平台

| 平台 |
|------|
| linux-x64 |
| windows-x64 |
| darwin-x64 |
| darwin-arm64 |
| linux-arm64 |
| windows-arm64 |
| linux-musl |
| linux-armv7 |
| riscv64 |

Python 和 npm 包仅覆盖其 pipeline 中实际构建并测试的平台。Rust 使用更细粒度的平台专用 native crate（如 `nexaloid-sys-linux-x64`），以符合 crates.io 大小限制。
