const path = require("node:path");

const root = path.resolve(__dirname, "../..");
const platformArch = `${process.platform}-${process.arch}`;
const prebuildDir = path.join(__dirname, "prebuilds", platformArch);
if (process.platform === "win32" && require("node:fs").existsSync(prebuildDir)) {
  process.env.PATH = prebuildDir + path.delimiter + process.env.PATH;
} else if (process.platform === "win32") {
  process.env.PATH = path.join(root, "core", "zig-out", "bin") + path.delimiter + process.env.PATH;
}

const prebuild = path.join(prebuildDir, "nexaloid_node.node");
const native = require(require("node:fs").existsSync(prebuild) ? prebuild : "./build/Release/nexaloid_node.node");
const packagedDict = path.join(__dirname, "data", "dict", "nexaloid.tsv");
const repoDict = path.join(root, "data", "dict", "nexaloid.tsv");

// JavaScript stays as a convenience shell; segmentation is implemented by the native addon.
class Tokenizer extends native.Tokenizer {
  constructor(options = {}) {
    super(options.dictPath || (require("node:fs").existsSync(packagedDict) ? packagedDict : repoDict));
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
