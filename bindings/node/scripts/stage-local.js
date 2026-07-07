const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "../../..");
const out = path.join(__dirname, "..", "build", "Release");
const names = process.platform === "win32"
  ? ["nexaloid.dll"]
  : process.platform === "darwin"
    ? ["libnexaloid.dylib"]
    : ["libnexaloid.so"];

for (const name of names) {
  const src = find(path.join(root, "core", "zig-out"), name);
  if (!src) throw new Error(`${name} not found under core/zig-out; run zig build in core first`);
  fs.copyFileSync(src, path.join(out, name));
}

function find(dir, name) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isFile() && entry.name === name) return full;
    if (entry.isDirectory()) {
      const hit = find(full, name);
      if (hit) return hit;
    }
  }
  return null;
}
