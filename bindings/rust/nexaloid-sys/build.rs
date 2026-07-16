use std::{
    env, fs,
    path::{Path, PathBuf},
};

fn copy_file(src: &Path, dst: &Path) {
    println!("cargo:rerun-if-changed={}", src.display());
    if !src.is_file() {
        panic!("missing runtime asset: {}", src.display());
    }
    fs::create_dir_all(dst.parent().expect("runtime asset parent")).unwrap();
    fs::copy(src, dst).unwrap_or_else(|err| {
        panic!(
            "failed to copy {} to {}: {err}",
            src.display(),
            dst.display()
        )
    });
}

fn profile_dir() -> PathBuf {
    let out_dir = PathBuf::from(env::var_os("OUT_DIR").expect("OUT_DIR"));
    out_dir
        .ancestors()
        .nth(3)
        .expect("Cargo profile directory above OUT_DIR")
        .to_path_buf()
}

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
    let native_dir = env::var(format!(
        "DEP_NEXALOID_PREBUILT_{}_NATIVE_DIR",
        platform.replace('-', "_").to_uppercase()
    ))
    .map(PathBuf::from)
    .unwrap_or_else(|_| manifest_dir.join("native").join(platform));
    let runtime_dir = profile_dir();

    let (core_name, extension) = if target.contains("windows") {
        ("nexaloid.dll", "dll")
    } else if target.contains("apple-darwin") {
        ("libnexaloid.dylib", "dylib")
    } else {
        ("libnexaloid.so", "so")
    };
    for name in [
        core_name.to_string(),
        format!("nexaloid_plugin_entity_bmes.{extension}"),
        format!("nexaloid_plugin_hmm_lattice.{extension}"),
    ] {
        copy_file(&native_dir.join(&name), &runtime_dir.join(name));
    }

    let data_dir = runtime_dir.join("nexaloid-data");
    copy_file(
        &manifest_dir.join("data/dict/nexaloid.nxdict"),
        &data_dir.join("dict/nexaloid.nxdict"),
    );
    for name in [
        "bmes_hmm_wordhub_lattice.nxhmm",
        "bmes_hmm_wordhub_lattice.nxhmm.sha256",
        "bmes_hmm_wordhub_lattice.manifest.json",
    ] {
        copy_file(
            &manifest_dir.join("data/hmm").join(name),
            &data_dir.join("hmm").join(name),
        );
    }

    println!("cargo:rustc-link-search=native={}", native_dir.display());
    if target.contains("apple-darwin") {
        println!("cargo:rustc-link-arg=-Wl,-rpath,@loader_path");
        println!("cargo:rustc-link-arg=-Wl,-rpath,@loader_path/..");
    } else if !target.contains("windows") {
        println!("cargo:rustc-link-arg=-Wl,-rpath,$ORIGIN");
        println!("cargo:rustc-link-arg=-Wl,-rpath,$ORIGIN/..");
    }
}
