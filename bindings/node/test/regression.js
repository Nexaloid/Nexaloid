const fs = require("node:fs");
const path = require("node:path");
const {
  Tokenizer,
  Mode,
  Source,
  entityArtifactPath,
  entityManifest,
  entityManifestPath,
  entityPluginPath,
  hmmArtifactPath,
  hmmManifest,
  hmmManifestPath
} = require("..");

const tokenizer = new Tokenizer();

function assertWords(text, expected) {
  const words = tokenizer.lcut(text);
  if (words.join("/") !== expected.join("/")) {
    throw new Error(`${text}: expected ${expected.join("/")}, got ${words.join("/")}`);
  }
}

function assertSearch(text, required, forbidden) {
  const words = tokenizer.tokenize(text, 2).map((token) => token.text);
  for (const word of required) {
    if (!words.includes(word)) throw new Error(`${text}: missing ${word} in ${words.join("/")}`);
  }
  for (const word of forbidden) {
    if (words.includes(word)) throw new Error(`${text}: unexpected ${word} in ${words.join("/")}`);
  }
}

assertWords("南京市长江大桥", ["南京市", "长江大桥"]);
assertWords("我们在日本东京做RAG中文检索实验", ["我们", "在", "日本", "东京", "做", "RAG", "中文", "检索", "实验"]);
assertWords("我爱北京天安门", ["我", "爱", "北京", "天安门"]);
assertWords("长春市长春节前发表讲话", ["长春", "市长", "春节前", "发表", "讲话"]);
assertWords("文档 秒", ["文档", "秒"]);
assertSearch("ChatGPT-5.5支持中文RAG检索。", ["ChatGPT-5.5", "中文", "RAG", "检索"], ["Ch", "Cha", "ha"]);
assertSearch("研究生命起源", ["研究", "生命", "起源"], ["研究生", "究生"]);
if (!tokenizer.lcut("研究生命起源", { mode: Mode.RECALL_SEARCH }).includes("研究生")) throw new Error("recall search missing candidate");
tokenizer.loadRulesJson('{"version":1,"rules":[{"name":"stock","kind":"prefixed_number","prefixes":["SH"],"digits":{"min":6,"max":6},"score":80}]}');
const stock = tokenizer.tokenize("买SH600519", Mode.ACCURATE).find((token) => token.text === "SH600519");
if (!stock || stock.source !== Source.RULE || stock.sourceName !== "rule" || stock.flags !== 1) {
  throw new Error(`bad custom rule token: ${JSON.stringify(stock)}`);
}
tokenizer.clearRules();
if (!fs.existsSync(hmmArtifactPath)) throw new Error(`missing HMM artifact: ${hmmArtifactPath}`);
if (!fs.existsSync(hmmManifestPath)) throw new Error(`missing HMM manifest: ${hmmManifestPath}`);
if (hmmManifest().quality.lattice_heldout.token_f1 < 0.98) throw new Error("bad HMM manifest quality");
if (!fs.existsSync(entityArtifactPath)) throw new Error(`missing entity artifact: ${entityArtifactPath}`);
if (!fs.existsSync(entityManifestPath)) throw new Error(`missing entity manifest: ${entityManifestPath}`);
if (entityManifest().quality.test.f1 < 0.86) throw new Error("bad entity manifest quality");
if (!fs.existsSync(path.join(path.dirname(entityArtifactPath), "APACHE-2.0.txt"))) {
  throw new Error("missing Apache-2.0 license text");
}
if (!fs.existsSync(entityPluginPath)) throw new Error(`missing entity plugin: ${entityPluginPath}`);
const entityTokenizer = new Tokenizer();
entityTokenizer.loadPlugin(entityPluginPath, JSON.stringify({ artifact: entityArtifactPath }));
const entityTokens = entityTokenizer.tokenize("梅花鹿", 0);
if (!entityTokens.some((token) => token.text === "梅花鹿" && token.source === Source.PLUGIN && token.sourceName === "plugin")) {
  throw new Error(`entity plugin inference failed: ${JSON.stringify(entityTokens)}`);
}
entityTokenizer.close();

const preserveTokenizer = new Tokenizer({ preserveWhitespace: true });
if (preserveTokenizer.lcut("文档 秒").join("/") !== "文档/ /秒") throw new Error("preserveWhitespace failed");
preserveTokenizer.close();

console.log("node regression passed");
tokenizer.close();
