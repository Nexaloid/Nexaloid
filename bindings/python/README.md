# nexaloid Python

Python bindings for the Nexaloid Chinese tokenizer.

The wheel bundles the native library and the default dictionary, so normal use does not need a separate dictionary file.

## Install

```bash
pip install nexaloid
```

## Usage

```python
from nexaloid import Mode, Tokenizer

tokenizer = Tokenizer()

print([token.text for token in tokenizer.tokenize("南京市长江大桥")])
print([token.text for token in tokenizer.tokenize("中国科学院计算技术研究所", Mode.SEARCH)])
print([token.text for token in tokenizer.tokenize("中国科学院计算技术研究所", Mode.RECALL_SEARCH)])

for token in tokenizer.tokenize("昨日中概股集体跌超百分之五", Mode.SEARCH):
    print(token.text, token.source, token.flags)
```

The default tokenizer uses the packaged `data/dict/nexaloid.nxdict`. Pass `dict_path` when you need a custom dictionary:

```python
tokenizer = Tokenizer(dict_path="data/dict/nexaloid.tsv")
```

Domain dictionaries use a restricted identifier rather than a path. `domain`
must match `[A-Za-z0-9_-]{1,64}` and the resolved dictionary must remain below
`NEXALOID_DOMAIN_DICT_DIR`.

Whitespace tokens are filtered by default. Enable jieba-like whitespace retention when needed:

```python
tokenizer = Tokenizer(preserve_whitespace=True)
print(tokenizer.lcut("中文 English\t混排\n第二行"))
```

## Jieba-style API

```python
import nexaloid.compat_jieba as jieba

print(jieba.lcut("我爱北京天安门"))
print(jieba.lcut("小明硕士毕业", HMM=True))
print(list(jieba.cut_for_search("中国科学院计算技术研究所")))
```

`HMM=True` loads the bundled BMES HMM plugin and artifact to recover unknown words such as short names and domain terms.

## Token Contract

`Mode.SEARCH` preserves every non-whitespace token on the Accurate path, including single-character and repeated-position tokens, and adds in-boundary Han 2-gram / 3-gram expansions. `Mode.RECALL_SEARCH` also adds explicit lattice candidates. `cut_for_search()` keeps search-term behavior by filtering one-character terms and deduplicating text.

Each token exposes the stable source name in `source` and source-specific metadata in `flags`. For `source == "rule"`, a nonzero `flags` value is the custom rule's 1-based JSON array index. Plugin tokens use `flags` for plugin-defined subtypes.

## Threading and lifecycle

A `Tokenizer` serializes all native calls on that instance, including
tokenization, mutation, plugin loading, and `close()`. `close()` is idempotent,
waits for the current call to return, and later operations raise
`NexaloidError`. Use separate instances when application-level parallelism is
required.

## Development

```powershell
cd bindings/python
python -m build
cd ../..
$env:PYTHONPATH = "$PWD\bindings\python\src"
python tools\badcase_runner.py
python tools\regression_checks.py
```
