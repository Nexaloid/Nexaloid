use std::{env, path::PathBuf};

fn main() {
    let target = env::var("TARGET").unwrap_or_default();
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let platform = if target.contains("windows") && target.contains("aarch64") {
        "windows-arm64"
    } else if target.contains("windows") {
        "windows-x64"
    } else if target.contains("apple-darwin") {
        if target.contains("aarch64") {
            "darwin-arm64"
        } else {
            "darwin-x64"
        }
    } else if target.contains("riscv64") {
        "riscv64"
    } else if target.contains("arm") && !target.contains("aarch64") {
        "linux-armv7"
    } else if target.contains("aarch64") {
        "linux-arm64"
    } else if target.contains("musl") {
        "linux-musl"
    } else {
        "linux-x64"
    };
    let dir = manifest_dir.join("native").join(platform);

    if dir.exists() {
        println!("cargo:rustc-link-search=native={}", dir.display());
        if !target.contains("windows") {
            println!("cargo:rustc-link-arg=-Wl,-rpath,{}", dir.display());
        }
    }
}
