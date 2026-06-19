const path = require("node:path");

const root = path.resolve(__dirname, "../..");
if (process.platform === "win32") {
  process.env.PATH = path.join(root, "core", "zig-out", "bin") + path.delimiter + process.env.PATH;
}

const native = require("./build/Release/nexaloid_node.node");

// JavaScript stays as a convenience shell; segmentation is implemented by the native addon.
class Tokenizer extends native.Tokenizer {
  constructor(options = {}) {
    super(options.dictPath || path.join(root, "data", "dict", "nexaloid.tsv"));
  }

  lcut(text, options = {}) {
    return this.tokenize(text, options.mode || 0).map((token) => token.text);
  }

  cutForSearch(text) {
    const seen = new Set();
    return this.tokenize(text, 2)
      .map((token) => token.text)
      .filter((word) => word.length > 1 && !seen.has(word) && seen.add(word));
  }
}

module.exports = {
  Tokenizer,
  Mode: {
    ACCURATE: 0,
    FULL: 1,
    SEARCH: 2
  }
};
