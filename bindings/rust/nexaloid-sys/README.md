# nexaloid-sys

Raw Rust FFI bindings for the Nexaloid C ABI.

Most users should depend on `nexaloid` instead. This crate provides the raw types, links to the native library, and bundles the default `nexaloid.nxdict` dictionary.

Native libraries are provided by target-specific crates such as `nexaloid-sys-linux-x64` and `nexaloid-sys-darwin-arm64`.
The raw `NxMode` enum includes `Search` for conservative best-path expansion and `RecallSearch` for aggressive all-candidate expansion.
Set `NxConfig.preserve_whitespace = 1` to keep pure whitespace tokens; the default is `0`.

## Usage

```rust
let dict = nexaloid_sys::bundled_dict_path();
println!("{}", dict.display());
```

## Development

```powershell
cd core
zig build
cd ..\bindings\rust\nexaloid-sys
cargo package --allow-dirty
```
