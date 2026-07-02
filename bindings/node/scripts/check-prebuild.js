const fs = require("node:fs");
const path = require("node:path");

const platform = process.platform === "win32" ? "windows" : process.platform === "darwin" ? "darwin" : "linux";
const platformArch = `${platform}-${process.arch}`;
const addon = path.join(__dirname, "..", "prebuilds", platformArch, "nexaloid_node.node");

if (!fs.existsSync(addon)) {
  throw new Error(`@nexaloid/nexaloid does not include a prebuild for ${platformArch}`);
}
