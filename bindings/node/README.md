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
```

The default tokenizer uses the packaged `data/dict/nexaloid.tsv`. Pass `dictPath` when you need a custom dictionary:

```js
const tokenizer = new nexaloid.Tokenizer({ dictPath: "data/dict/nexaloid.tsv" });
```

## Build

```powershell
cd bindings/node
npm run build
npm run test:binding
```
