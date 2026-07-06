# nexaloid Bindings

All language bindings call the nexaloid C ABI. They must not reimplement tokenizer logic.

Release assets publish C, C++, and Zig as separate native SDK zip files, alongside the combined native SDK. The `release/c`, `release/cpp`, and `release/zig` branches track the latest released entry files for users who prefer pulling a branch.

## C++

```powershell
zig c++ -std=c++17 `
  -Icore/include `
  -Ibindings/cpp/include `
  bindings/cpp/tests/regression.cpp `
  core/zig-out/lib/nexaloid.lib `
  -o .zig-cache/nexaloid_cpp_regression.exe
$env:PATH = "$PWD\core\zig-out\bin;$env:PATH"
.zig-cache\nexaloid_cpp_regression.exe
```

## Rust

```powershell
$env:RUSTFLAGS = "-L native=$PWD\core\zig-out\lib"
$env:PATH = "$PWD\core\zig-out\bin;$env:PATH"
cargo run --manifest-path bindings/rust/nexaloid/Cargo.toml --example regression
```

## Go

```powershell
cd bindings/go
$env:PATH = "$PWD\..\..\core\zig-out\bin;$env:PATH"
go test ./nexaloid
```

## Node.js

```powershell
cd bindings/node
npm run build
npm run test:binding
```
