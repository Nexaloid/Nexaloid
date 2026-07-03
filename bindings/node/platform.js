const platform = process.platform === "win32" ? "windows" : process.platform === "darwin" ? "darwin" : "linux";
const arch = process.arch === "x64" ? "x64" : process.arch === "arm64" ? "arm64" : process.arch;

module.exports = `${platform}-${arch}`;
