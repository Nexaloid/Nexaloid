# nexaloid-sys

Raw Rust FFI bindings for the Nexaloid C ABI.

Most users should depend on `nexaloid` instead. This crate provides the raw types, links to the native library, and bundles the default `nexaloid.nxdict` dictionary.

Native libraries are provided by target-specific crates such as `nexaloid-sys-linux-x64` and `nexaloid-sys-darwin-arm64`.
Build scripts stage the core library, plugins, dictionary, and HMM data beside
the final executable; the high-level `nexaloid` crate adds the entity model.
Bundled path helpers resolve that portable runtime layout without embedding
Cargo registry or source checkout paths.
Rust executables link the core statically on Unix so the layout remains
portable without downstream linker flags; plugins remain dynamic.
The raw `NxMode` enum includes `Search`, which preserves and expands the Accurate path, and `RecallSearch`, which also adds explicit lattice candidates.
Set `NxConfig.preserve_whitespace = 1` to keep pure whitespace tokens; the default is `0`.

## Token Contract

`NxToken.source` and `NxToken.flags` deliberately remain raw `u16` ABI fields. Known source values are defined by the C `NxSource` contract: 1 `base_dict`, 2 `user_dict`, 3 `domain_dict`, 4 `rule`, 5 `unknown`, and 6 `plugin`. Most applications should use the safe `nexaloid::Source` enum instead.

For rule tokens, a nonzero `flags` value is the custom rule's 1-based JSON array index. Plugin tokens use `flags` for plugin-defined subtypes.

## Usage

```rust
let dict = nexaloid_sys::bundled_dict_path();
let native = nexaloid_sys::bundled_native_dir();
let entity_plugin = nexaloid_sys::bundled_entity_plugin_path();
let hmm_plugin = nexaloid_sys::bundled_hmm_plugin_path();
println!("{}", dict.display());
```

## Development

```powershell
cd core
zig build
cd ..\bindings\rust\nexaloid-sys
cargo package --allow-dirty
```
