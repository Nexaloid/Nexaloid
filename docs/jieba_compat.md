# jieba Compatibility

`nexaloid.compat_jieba` is a migration adapter. It should let existing jieba users change only the import:

```python
import nexaloid.compat_jieba as jieba
```

## v0.1 Target

Required:

- `jieba.cut`
- `jieba.lcut`
- `jieba.cut_for_search`
- `jieba.lcut_for_search`
- `jieba.load_userdict`
- `jieba.add_word`
- `jieba.del_word`
- `jieba.suggest_freq`

## Boundary

Compatibility belongs in the Python adapter, not Core. Core exposes stable offset-preserving tokenization; the adapter maps jieba behavior onto it.

## Compatibility Rules

- `cut` returns an iterator.
- `lcut` returns a list.
- `cut_for_search` expands search tokens and skips one-character tokens.
- `lcut_for_search` returns a list from `cut_for_search`.
- `load_userdict` accepts jieba-style `word freq tag` dictionaries; tags are ignored by Core for now.
- `add_word` adds a user word; its tag argument is accepted and ignored.
- `del_word` filters exact token text from adapter output.
- `suggest_freq` is adapter-local: with `tune=True`, it adds the joined segment with score `20.0`; otherwise it returns the adapter's stored score or `0`.

The packaged dictionary is resolved by `nexaloid.Tokenizer`; installing the `jieba` Python package does not change adapter loading at runtime.

The main `nexaloid.Tokenizer` API may expose richer token metadata; `compat_jieba` hides that metadata to match jieba.
