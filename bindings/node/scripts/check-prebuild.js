const fs = require("node:fs");
const path = require("node:path");

const platformArch = require("../platform");
const addon = path.join(__dirname, "..", "prebuilds", platformArch, "nexaloid_node.node");

if (!fs.existsSync(addon)) {
  throw new Error(`@nexaloid/nexaloid does not include a prebuild for ${platformArch}`);
}
