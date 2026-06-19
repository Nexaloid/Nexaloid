# nexaloid Node.js Binding

Node.js wraps the nexaloid C ABI through N-API. Segmentation stays in native core.

## Usage

```js
const nexaloid = require("nexaloid");
const tokenizer = new nexaloid.Tokenizer({ dictPath: "data/dict/nexaloid.tsv" });

tokenizer.lcut("南京市长江大桥");
tokenizer.cutForSearch("中国科学院计算技术研究所");
```

## Build

```powershell
cd bindings/node
npm run build
npm run smoke
```

The binding calls:

- `nx_engine_new`
- `nx_engine_free`
- `nx_tokenize`
- `nx_add_word`
- `nx_reload_user_dict`
