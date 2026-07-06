use std::{env, path::PathBuf};

fn main() {
    let dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap()).join("native");
    println!("cargo:native_dir={}", dir.display());
}
