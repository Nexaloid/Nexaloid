from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from platform_tag import platform_tag


ROOT = Path(__file__).resolve().parents[1]


def runtime_names() -> tuple[str, tuple[str, ...]]:
    if sys.platform == "win32":
        return "portability_consumer.exe", (
            "nexaloid.dll",
            "nexaloid_plugin_entity_bmes.dll",
            "nexaloid_plugin_hmm_lattice.dll",
        )
    if sys.platform == "darwin":
        return "portability_consumer", (
            "libnexaloid.dylib",
            "nexaloid_plugin_entity_bmes.dylib",
            "nexaloid_plugin_hmm_lattice.dylib",
        )
    return "portability_consumer", (
        "libnexaloid.so",
        "nexaloid_plugin_entity_bmes.so",
        "nexaloid_plugin_hmm_lattice.so",
    )


def copy_rust_crates(destination: Path) -> None:
    rust_root = ROOT / "bindings" / "rust"
    for source in rust_root.glob("nexaloid*"):
        if source.is_dir():
            shutil.copytree(
                source,
                destination / source.name,
                ignore=shutil.ignore_patterns("target"),
            )


def write_consumer(root: Path, crates: Path) -> None:
    (root / "src").mkdir(parents=True)
    nexaloid = (crates / "nexaloid").as_posix()
    nexaloid_sys = (crates / "nexaloid-sys").as_posix()
    (root / "Cargo.toml").write_text(
        f'''[package]
name = "portability_consumer"
version = "0.0.0"
edition = "2021"

[dependencies]
nexaloid = {{ path = "{nexaloid}" }}
nexaloid-sys = {{ path = "{nexaloid_sys}" }}

[profile.portable]
inherits = "release"
''',
        encoding="utf-8",
    )
    (root / "src" / "main.rs").write_text(
        r'''use nexaloid::{
    bundled_entity_artifact_path, bundled_entity_plugin_path,
    bundled_hmm_artifact_path, bundled_hmm_plugin_path, Mode, Source, Tokenizer,
};

fn main() {
    let executable = std::env::current_exe().unwrap();
    let root = executable.parent().unwrap();
    let paths = [
        nexaloid_sys::bundled_dict_path(),
        bundled_hmm_artifact_path(),
        bundled_entity_artifact_path(),
        bundled_hmm_plugin_path(),
        bundled_entity_plugin_path(),
    ];
    for path in &paths {
        assert!(path.is_file(), "missing runtime asset: {}", path.display());
        assert!(
            path.starts_with(root),
            "asset escaped runtime directory: {}",
            path.display()
        );
    }
    assert_eq!(nexaloid_sys::bundled_native_dir(), root);

    let mut tokenizer = Tokenizer::new_default().unwrap();
    let plugin = bundled_entity_plugin_path();
    let model = bundled_entity_artifact_path()
        .to_string_lossy()
        .replace('\\', "/");
    let config = format!(r#"{{"artifact":"{model}"}}"#);
    tokenizer
        .load_plugin(&plugin.to_string_lossy(), Some(&config))
        .unwrap();
    assert!(tokenizer
        .tokenize("欧盟委员会", Mode::Accurate)
        .unwrap()
        .iter()
        .any(|token| token.text == "欧盟委员会" && token.source == Source::Plugin));
    println!("portable entity plugin load passed");
}
''',
        encoding="utf-8",
    )


def main() -> int:
    cargo = shutil.which("cargo")
    if cargo is None:
        raise RuntimeError("cargo is not on PATH")

    executable_name, native_names = runtime_names()
    platform_native = (
        ROOT / "bindings" / "rust" / f"nexaloid-sys-{platform_tag()}" / "native"
    )
    missing = [name for name in native_names if not (platform_native / name).is_file()]
    if missing:
        raise RuntimeError(
            "stage Rust platform assets first; missing: " + ", ".join(missing)
        )

    with tempfile.TemporaryDirectory(prefix="nexaloid-portability-") as tmp:
        temp = Path(tmp)
        crates = temp / "crates"
        consumer = temp / "consumer"
        deploy = temp / "clean deploy"
        cargo_home = temp / "cargo-home"
        cargo_target = temp / "cargo-target"
        copy_rust_crates(crates)
        write_consumer(consumer, crates)
        cargo_home.mkdir()

        env = os.environ.copy()
        env["CARGO_HOME"] = str(cargo_home)
        env["CARGO_TARGET_DIR"] = str(cargo_target)
        subprocess.run(
            [cargo, "build", "--profile", "portable", "--offline"],
            cwd=consumer,
            env=env,
            check=True,
        )

        release = cargo_target / "portable"
        deploy.mkdir()
        shutil.copy2(release / executable_name, deploy / executable_name)
        for name in native_names:
            shutil.copy2(release / name, deploy / name)
        shutil.copytree(release / "nexaloid-data", deploy / "nexaloid-data")

        shutil.rmtree(crates)
        shutil.rmtree(consumer)
        shutil.rmtree(cargo_home)
        shutil.rmtree(cargo_target)
        runtime_env = os.environ.copy()
        runtime_env["CARGO_HOME"] = str(temp / "deleted-cargo-home")
        runtime_env.pop("LD_LIBRARY_PATH", None)
        runtime_env.pop("DYLD_LIBRARY_PATH", None)
        result = subprocess.run(
            [str(deploy / executable_name)],
            cwd=deploy,
            env=runtime_env,
            check=True,
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        print(result.stdout.strip())

    print("rust portability regression passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
