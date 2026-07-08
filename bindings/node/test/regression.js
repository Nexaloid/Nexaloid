const fs = require("node:fs");
const { Tokenizer, hmmArtifactPath, hmmManifest, hmmManifestPath } = require("..");

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
assertSearch("ChatGPT-5.5支持中文RAG检索。", ["ChatGPT-5.5", "中文", "RAG", "检索"], ["Ch", "Cha", "ha"]);
tokenizer.loadRulesJson('{"version":1,"rules":[{"name":"stock","kind":"prefixed_number","prefixes":["SH"],"digits":{"min":6,"max":6},"score":80}]}');
if (!tokenizer.lcut("买SH600519").includes("SH600519")) throw new Error("missing custom rule token");
tokenizer.clearRules();
if (!fs.existsSync(hmmArtifactPath)) throw new Error(`missing HMM artifact: ${hmmArtifactPath}`);
if (!fs.existsSync(hmmManifestPath)) throw new Error(`missing HMM manifest: ${hmmManifestPath}`);
if (hmmManifest().quality.lattice_heldout.token_f1 < 0.98) throw new Error("bad HMM manifest quality");

console.log("node regression passed");
tokenizer.close();
