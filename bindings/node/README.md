# @nexaloid/nexaloid

Node.js bindings for the Nexaloid Chinese tokenizer.

The npm package bundles the default dictionary and a prebuilt N-API addon for supported platforms.

## Install

```bash
npm install @nexaloid/nexaloid
```

## Usage

```js
const { Mode, Source, Tokenizer } = require("@nexaloid/nexaloid");
const tokenizer = new Tokenizer();

console.log(tokenizer.lcut("南京市长江大桥"));
console.log(tokenizer.cutForSearch("中国科学院计算技术研究所"));
console.log(tokenizer.lcut("中国科学院计算技术研究所", { mode: Mode.RECALL_SEARCH }));

for (const token of tokenizer.tokenize("昨日中概股集体跌超百分之五", Mode.SEARCH)) {
  console.log(token.text, token.sourceName, token.flags);
  if (token.source === Source.RULE && token.flags !== 0) {
    console.log("custom rule index", token.flags);
  }
}
```

The default tokenizer uses the packaged `data/dict/nexaloid.tsv`. Pass `dictPath` when you need a custom dictionary:

```js
const tokenizer = new nexaloid.Tokenizer({ dictPath: "data/dict/nexaloid.tsv" });
```

Whitespace tokens are filtered by default. Use `preserveWhitespace` when exact source shape matters:

```js
const tokenizer = new nexaloid.Tokenizer({ preserveWhitespace: true });
```

## Bundled Plugins

The package exposes both plugin and model paths:

```js
const {
  Tokenizer,
  entityArtifactPath,
  entityPluginPath,
  hmmArtifactPath,
  hmmPluginPath
} = require("@nexaloid/nexaloid");

const hmm = new Tokenizer();
hmm.loadPlugin(hmmPluginPath, hmmArtifactPath);

const entity = new Tokenizer();
entity.loadPlugin(entityPluginPath, JSON.stringify({ artifact: entityArtifactPath }));
```

## Token Contract

`Mode.SEARCH` preserves every non-whitespace token on the Accurate path, including single-character and repeated-position tokens, and adds in-boundary Han 2-gram / 3-gram expansions. `Mode.RECALL_SEARCH` also adds explicit lattice candidates. `cutForSearch()` keeps search-term behavior by filtering one-character terms and deduplicating text.

Each raw token exposes numeric `source`, stable `sourceName`, and `flags`. For `source === Source.RULE`, a nonzero `flags` value is the custom rule's 1-based JSON array index. Plugin tokens use `flags` for plugin-defined subtypes.

## Build

```powershell
cd bindings/node
npm run build
npm run test:binding
```
