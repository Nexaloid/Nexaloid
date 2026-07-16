const path = require("node:path");
const fs = require("node:fs");

const root = path.resolve(__dirname, "../..");
const platformArch = require("./platform");
const prebuildDir = path.join(__dirname, "prebuilds", platformArch);
const localBuild = path.join(__dirname, "build/Release/nexaloid_node.node");
if (process.platform === "win32" && fs.existsSync(localBuild)) {
  process.env.PATH = path.join(root, "core", "zig-out", "bin") + path.delimiter + process.env.PATH;
} else if (process.platform === "win32" && fs.existsSync(prebuildDir)) {
  process.env.PATH = prebuildDir + path.delimiter + process.env.PATH;
} else if (process.platform === "win32") {
  process.env.PATH = path.join(root, "core", "zig-out", "bin") + path.delimiter + process.env.PATH;
}

const prebuild = path.join(prebuildDir, "nexaloid_node.node");
const native = require(fs.existsSync(localBuild) ? localBuild : fs.existsSync(prebuild) ? prebuild : localBuild);
const packagedDict = path.join(__dirname, "data", "dict", "nexaloid.tsv");
const repoDict = path.join(root, "data", "dict", "nexaloid.tsv");
const hmmArtifactName = "bmes_hmm_wordhub_lattice.nxhmm";
const hmmManifestName = "bmes_hmm_wordhub_lattice.manifest.json";
const packagedHmmArtifact = path.join(__dirname, "data", "hmm", hmmArtifactName);
const repoHmmArtifact = path.join(root, "data", "hmm", hmmArtifactName);
const packagedHmmManifest = path.join(__dirname, "data", "hmm", hmmManifestName);
const repoHmmManifest = path.join(root, "data", "hmm", hmmManifestName);
const hmmArtifactPath = fs.existsSync(repoHmmArtifact) ? repoHmmArtifact : packagedHmmArtifact;
const hmmManifestPath = fs.existsSync(repoHmmManifest) ? repoHmmManifest : packagedHmmManifest;
const hmmPluginName = process.platform === "win32"
  ? "nexaloid_plugin_hmm_lattice.dll"
  : process.platform === "darwin"
    ? "nexaloid_plugin_hmm_lattice.dylib"
    : "nexaloid_plugin_hmm_lattice.so";
const packagedHmmPlugin = path.join(prebuildDir, hmmPluginName);
const repoHmmPlugin = ["bin", "lib"]
  .map((dir) => path.join(root, "core", "zig-out", dir, hmmPluginName))
  .find((candidate) => fs.existsSync(candidate));
const hmmPluginPath = repoHmmPlugin || packagedHmmPlugin;
const entityArtifactName = "entity_bmes_perceptron.nxbmes";
const entityManifestName = "entity_bmes_perceptron.manifest.json";
const packagedEntityArtifact = path.join(__dirname, "data", "entity", entityArtifactName);
const repoEntityArtifact = path.join(root, "data", "entity", entityArtifactName);
const packagedEntityManifest = path.join(__dirname, "data", "entity", entityManifestName);
const repoEntityManifest = path.join(root, "data", "entity", entityManifestName);
const entityArtifactPath = fs.existsSync(repoEntityArtifact) ? repoEntityArtifact : packagedEntityArtifact;
const entityManifestPath = fs.existsSync(repoEntityManifest) ? repoEntityManifest : packagedEntityManifest;
const entityPluginName = process.platform === "win32"
  ? "nexaloid_plugin_entity_bmes.dll"
  : process.platform === "darwin"
    ? "nexaloid_plugin_entity_bmes.dylib"
    : "nexaloid_plugin_entity_bmes.so";
const packagedEntityPlugin = path.join(prebuildDir, entityPluginName);
const repoEntityPlugin = ["bin", "lib"]
  .map((dir) => path.join(root, "core", "zig-out", dir, entityPluginName))
  .find((candidate) => fs.existsSync(candidate));
const entityPluginPath = repoEntityPlugin || packagedEntityPlugin;
const Source = Object.freeze({
  BASE_DICT: 1,
  USER_DICT: 2,
  DOMAIN_DICT: 3,
  RULE: 4,
  UNKNOWN: 5,
  PLUGIN: 6
});

// JavaScript stays as a convenience shell; segmentation is implemented by the native addon.
class Tokenizer extends native.Tokenizer {
  constructor(options = {}) {
    super(options.dictPath || (fs.existsSync(repoDict) ? repoDict : packagedDict), options.preserveWhitespace === true);
  }

  lcut(text, options = {}) {
    return super.lcut(text, options.mode || 0);
  }

  cutForSearch(text) {
    const seen = new Set();
    return super.lcut(text, 2)
      .filter((word) => word.length > 1 && !seen.has(word) && seen.add(word));
  }

  loadPlugins(dir, config) {
    const ext = process.platform === "win32" ? ".dll" : process.platform === "darwin" ? ".dylib" : ".so";
    for (const name of fs.readdirSync(dir).sort()) {
      if (name.startsWith("nexaloid_plugin") && name.endsWith(ext)) {
        this.loadPlugin(path.join(dir, name), config);
      }
    }
  }

  loadRules(file) {
    this.loadRulesJson(fs.readFileSync(file, "utf8"));
  }
}

module.exports = {
  Tokenizer,
  hmmArtifactPath,
  hmmManifestPath,
  hmmManifest: () => JSON.parse(fs.readFileSync(hmmManifestPath, "utf8")),
  hmmPluginPath,
  entityArtifactPath,
  entityManifestPath,
  entityManifest: () => JSON.parse(fs.readFileSync(entityManifestPath, "utf8")),
  entityPluginPath,
  Source,
  Mode: {
    ACCURATE: 0,
    FULL: 1,
    SEARCH: 2,
    RECALL_SEARCH: 3
  }
};
