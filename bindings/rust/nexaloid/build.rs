use std::{env, fs, path::PathBuf};

fn profile_dir() -> PathBuf {
    let out_dir = PathBuf::from(env::var_os("OUT_DIR").expect("OUT_DIR"));
    out_dir
        .ancestors()
        .nth(3)
        .expect("Cargo profile directory above OUT_DIR")
        .to_path_buf()
}

fn main() {
    let source = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap()).join("data/entity");
    let destination = profile_dir().join("nexaloid-data/entity");
    for name in [
        "entity_bmes_perceptron.nxbmes",
        "entity_bmes_perceptron.nxbmes.sha256",
        "entity_bmes_perceptron.manifest.json",
        "APACHE-2.0.txt",
        "MODEL_LICENSE.txt",
        "THIRD_PARTY_NOTICES.txt",
    ] {
        let src = source.join(name);
        let dst = destination.join(name);
        println!("cargo:rerun-if-changed={}", src.display());
        if !src.is_file() {
            panic!("missing runtime asset: {}", src.display());
        }
        fs::create_dir_all(dst.parent().expect("runtime asset parent")).unwrap();
        fs::copy(&src, &dst).unwrap_or_else(|err| {
            panic!(
                "failed to copy {} to {}: {err}",
                src.display(),
                dst.display()
            )
        });
    }
}
