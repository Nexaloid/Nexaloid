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
```

The default tokenizer uses the packaged `data/dict/nexaloid.nxdict`. Pass `dict_path` when you need a custom dictionary:

```python
tokenizer = Tokenizer(dict_path="data/dict/nexaloid.tsv")
```

## Jieba-style API

```python
import nexaloid.compat_jieba as jieba

print(jieba.lcut("我爱北京天安门"))
print(list(jieba.cut_for_search("中国科学院计算技术研究所")))
```

## Development

```powershell
cd bindings/python
python -m build
cd ../..
$env:PYTHONPATH = "$PWD\bindings\python\src"
python tools\badcase_runner.py
python tools\regression_checks.py
```
