# nexaloid Bindings

All language bindings call the nexaloid C ABI. They must not reimplement tokenizer logic.

## C++

```powershell
zig c++ -std=c++17 `
  -Icore/include `
  -Ibindings/cpp/include `
  bindings/cpp/examples/smoke.cpp `
  core/zig-out/lib/nexaloid.lib `
  -o .zig-cache/nexaloid_cpp_smoke.exe
$env:PATH = "$PWD\core\zig-out\bin;$env:PATH"
.zig-cache\nexaloid_cpp_smoke.exe
```

## Rust

```powershell
$env:RUSTFLAGS = "-L F:\Code\03_OpenCode\Nexaloid\core\zig-out\lib"
$env:PATH = "F:\Code\03_OpenCode\Nexaloid\core\zig-out\bin;$env:PATH"
cargo run --manifest-path bindings/rust/nexaloid/Cargo.toml --example smoke
```

## Go

```powershell
$env:PATH = "F:\Code\03_OpenCode\Nexaloid\core\zig-out\bin;$env:PATH"
cd bindings/go
go test ./nexaloid
```

## Node.js

```powershell
cd bindings/node
npm run build
npm run smoke
```
