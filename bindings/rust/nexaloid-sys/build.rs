use std::{env, path::PathBuf};

fn main() {
    let target = env::var("TARGET").unwrap_or_default();
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let arch = if target.contains("aarch64") {
        "arm64"
    } else {
        "x64"
    };
    let dir = if target.contains("windows") {
        manifest_dir.join(format!("native/windows-{arch}"))
    } else if target.contains("apple-darwin") {
        manifest_dir.join(format!("native/darwin-{arch}"))
    } else {
        manifest_dir.join(format!("native/linux-{arch}"))
    };

    if dir.exists() {
        println!("cargo:rustc-link-search=native={}", dir.display());
        if !target.contains("windows") {
            println!("cargo:rustc-link-arg=-Wl,-rpath,{}", dir.display());
        }
    }
}
