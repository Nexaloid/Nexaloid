# nexaloid Bindings

All language bindings call the nexaloid C ABI. They must not reimplement tokenizer logic.

Modes are shared across bindings: `Accurate`, `Full`, `Search`, and `RecallSearch`.
`Search` preserves the best Viterbi path and adds only in-boundary expansions; `RecallSearch` also adds explicit lattice candidates for recall-heavy indexes. Raw token output keeps single characters and repeated positions, while `cut_for_search` helpers filter and deduplicate search terms.
Whitespace tokens are filtered by default. Enable the binding's `preserveWhitespace` / `preserve_whitespace` option, or set `NxConfig.preserve_whitespace = 1`, when exact source-shape retention is required.

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
