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

## Usage

```rust
use nexaloid::{Mode, Tokenizer};

fn main() -> Result<(), nexaloid::Error> {
    let tokenizer = Tokenizer::new_default()?;
    let tokens = tokenizer.tokenize("南京市长江大桥", Mode::Accurate)?;

    for token in tokens {
        println!("{} {}..{}", token.text, token.start_byte, token.end_byte);
    }

    Ok(())
}
```

## Development

```powershell
cd core
zig build
cd ..\bindings\rust\nexaloid
cargo test
```
