# nexaloid Rust

Safe Rust wrapper for the Nexaloid Chinese tokenizer.

The `nexaloid` crate depends on `nexaloid-sys`, which bundles the default dictionary and selects the matching native platform crate automatically.

## Install

```toml
[dependencies]
nexaloid = "0.1"
```

Supported prebuilt targets currently include:

```text
linux-x64
linux-musl
linux-arm64
linux-armv7
riscv64
windows-x64
windows-arm64
darwin-x64
darwin-arm64
```

Each platform crate also bundles the entity and HMM plugins. Use
`bundled_entity_plugin_path()` and `bundled_hmm_plugin_path()` instead of
hard-coding platform-specific filenames. Their model paths are exposed by
`bundled_entity_artifact_path()` and `bundled_hmm_artifact_path()`.

`cargo build` stages a portable runtime beside the final executable:

```text
target/<profile>/
  nexaloid.dll | libnexaloid.so | libnexaloid.dylib
  nexaloid_plugin_entity_bmes.*
  nexaloid_plugin_hmm_lattice.*
  nexaloid-data/{dict,hmm,entity}/...
```

Distribute the executable with these sibling files and the complete
`nexaloid-data/` directory. Runtime path helpers resolve only this portable
layout and never depend on Cargo registry or source checkout paths.
On Unix, the Rust executable links the core statically; plugins remain dynamic.

`Tokenizer` initialization verifies that the `nexaloid`, `nexaloid-sys`, and
native runtime versions match exactly. `runtime_version()` exposes the loaded
native version for diagnostics. Plugin ABI and model-format mismatches fail
when `load_plugin` initializes that plugin.

## Usage

```rust
use nexaloid::{Mode, Source, Tokenizer};

fn main() -> Result<(), nexaloid::Error> {
    let tokenizer = Tokenizer::new_default()?;
    let tokens = tokenizer.tokenize("南京市长江大桥", Mode::Accurate)?;
    let search = tokenizer.tokenize("南京市长江大桥", Mode::Search)?;
    let recall = tokenizer.tokenize("南京市长江大桥", Mode::RecallSearch)?;

    for token in tokens {
        println!("{} {}..{} {} flags={}", token.text, token.start_byte, token.end_byte, token.source.as_str(), token.flags);
        if token.source == Source::Rule {
            println!("custom rule index: {:?}", token.custom_rule_index());
        }
    }

    Ok(())
}
```

## Token Contract

`Mode::Search` preserves every non-whitespace token on the Accurate path, including single-character and repeated-position tokens, and adds in-boundary Han 2-gram / 3-gram expansions. `Mode::RecallSearch` also emits explicit lattice candidates.

`Token::source` uses the public `Source` enum. `Source::as_str()` returns its stable name and `Source::raw()` preserves the ABI value, including `Source::Unrecognized`. `Token::custom_rule_index()` returns the custom rule's 1-based JSON array index when `source` is `Source::Rule` and `flags` is nonzero.

Whitespace tokens are filtered by default; use `Tokenizer::new_default_with_whitespace(true)` or set `NxConfig.preserve_whitespace = 1`.

## Development

```powershell
cd core
zig build
cd ..
python tools/stage_assets.py --rust-only
cd bindings\rust\nexaloid
cargo test
```
