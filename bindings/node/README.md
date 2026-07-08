# @nexaloid/nexaloid

Node.js bindings for the Nexaloid Chinese tokenizer.

The npm package bundles the default dictionary and a prebuilt N-API addon for supported platforms.

## Install

```bash
npm install @nexaloid/nexaloid
```

## Usage

```js
const nexaloid = require("@nexaloid/nexaloid");
const tokenizer = new nexaloid.Tokenizer();

console.log(tokenizer.lcut("南京市长江大桥"));
console.log(tokenizer.cutForSearch("中国科学院计算技术研究所"));
console.log(tokenizer.lcut("中国科学院计算技术研究所", { mode: nexaloid.Mode.RECALL_SEARCH }));
```

The default tokenizer uses the packaged `data/dict/nexaloid.tsv`. Pass `dictPath` when you need a custom dictionary:

```js
const tokenizer = new nexaloid.Tokenizer({ dictPath: "data/dict/nexaloid.tsv" });
```

Whitespace tokens are filtered by default. Use `preserveWhitespace` when exact source shape matters:

```js
const tokenizer = new nexaloid.Tokenizer({ preserveWhitespace: true });
```

`Mode.SEARCH` is conservative and expands the best path only. `Mode.RECALL_SEARCH` keeps the aggressive all-candidate expansion for recall-heavy indexes.

## Build

```powershell
cd bindings/node
npm run build
npm run test:binding
```
