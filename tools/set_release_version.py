from __future__ import annotations

import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def normalize(raw: str) -> str:
    version = raw.strip()
    if version.startswith("refs/tags/"):
        version = version.rsplit("/", 1)[1]
    if version.startswith("v"):
        version = version[1:]
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:[-a-zA-Z0-9.]+)?", version):
        raise SystemExit(f"invalid release version: {raw!r}")
    return version


def python_version(version: str) -> str:
    return (
        version.replace("-alpha.", "a")
        .replace("-beta.", "b")
        .replace("-rc.", "rc")
        .replace("-dev.", ".dev")
    )


def replace(path: str, pattern: str, value: str) -> None:
    file = ROOT / path
    text = file.read_text(encoding="utf-8")
    text = re.sub(pattern, value, text)
    file.write_text(text, encoding="utf-8")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: set_release_version.py <version-or-tag>")
    version = normalize(sys.argv[1])
    py_version = python_version(version)

    replace("bindings/python/pyproject.toml", r'version = "[^"]+"', f'version = "{py_version}"')
    for manifest in (ROOT / "bindings/rust").glob("nexaloid-sys-*/*.toml"):
        rel = manifest.relative_to(ROOT).as_posix()
        replace(rel, r'version = "[^"]+"', f'version = "{version}"')
    replace("bindings/rust/nexaloid-sys/Cargo.toml", r'version = "[^"]+"', f'version = "{version}"')
    replace(
        "bindings/rust/nexaloid-sys/Cargo.toml",
        r'nexaloid-sys-([a-z0-9-]+) = \{ version = "[^"]+", path = "../nexaloid-sys-\1" \}',
        rf'nexaloid-sys-\1 = {{ version = "={version}", path = "../nexaloid-sys-\1" }}',
    )
    replace("bindings/rust/nexaloid/Cargo.toml", r'version = "[^"]+"', f'version = "{version}"')
    replace(
        "bindings/rust/nexaloid/Cargo.toml",
        r'nexaloid-sys = \{ version = "[^"]+", path = "../nexaloid-sys" \}',
        f'nexaloid-sys = {{ version = "={version}", path = "../nexaloid-sys" }}',
    )
    replace(
        "core/src/nexaloid_ffi.zig",
        r'const runtime_version = "[^"]+";',
        f'const runtime_version = "{version}";',
    )
    replace("bindings/rust/nexaloid/Cargo.lock", r'version = "[^"]+"', f'version = "{version}"')

    package = ROOT / "bindings/node/package.json"
    data = json.loads(package.read_text(encoding="utf-8"))
    data["version"] = version
    package.write_text(json.dumps(data, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")

    print(f"release version: {version}")
    print(f"python version: {py_version}")


if __name__ == "__main__":
    main()
