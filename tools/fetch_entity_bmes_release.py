from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import tempfile
import urllib.request
import zipfile
from pathlib import Path


ASSETS = (
    "entity_bmes_perceptron.nxbmes",
    "entity_bmes_perceptron.nxbmes.sha256",
    "entity_bmes_perceptron.manifest.json",
    "MODEL_LICENSE.txt",
)


def validate_bundle(root: Path, expected_sha256: str) -> None:
    expected = expected_sha256.lower()
    if not re.fullmatch(r"[0-9a-f]{64}", expected):
        raise ValueError("expected SHA-256 must be 64 hexadecimal characters")

    artifact = root / ASSETS[0]
    digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
    checksum_parts = (root / ASSETS[1]).read_text(encoding="utf-8").split()
    if not checksum_parts:
        raise ValueError("empty BMES checksum file")
    checksum = checksum_parts[0].lower()
    manifest = json.loads((root / ASSETS[2]).read_text(encoding="utf-8"))
    if not isinstance(manifest, dict):
        raise ValueError("invalid BMES manifest")
    distribution = manifest.get("distribution")
    if not isinstance(distribution, dict):
        raise ValueError("BMES manifest has no distribution metadata")
    license_spdx = distribution.get("license_spdx")
    manifest_sha256 = manifest.get("artifact_sha256")

    if manifest.get("schema") != "nexaloid.bmes_manifest.v1":
        raise ValueError("unsupported BMES manifest schema")
    if manifest.get("artifact_format") != "nxbmes.v1":
        raise ValueError("unsupported BMES artifact format")
    if distribution.get("scope") != "public":
        raise ValueError("BMES artifact is not cleared for public distribution")
    if not isinstance(license_spdx, str) or not license_spdx or license_spdx == "NOASSERTION":
        raise ValueError("BMES artifact has no public SPDX license")
    if not isinstance(manifest_sha256, str):
        raise ValueError("BMES manifest has no artifact SHA-256")
    if {expected, digest, checksum, manifest_sha256.lower()} != {expected}:
        raise ValueError("BMES artifact SHA-256 mismatch")

    notice = (root / ASSETS[3]).read_text(encoding="utf-8").strip()
    if f"SPDX-License-Identifier: {license_spdx}" not in notice:
        raise ValueError("BMES model license notice does not match the manifest")
    if "Distribution: public" not in notice:
        raise ValueError("BMES model license notice is not public")


def download_release(repo: str, version: str, root: Path) -> None:
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise ValueError("invalid GitHub repository")
    tag = version if version.startswith("v") else f"v{version}"
    if not re.fullmatch(r"v[A-Za-z0-9_.-]+", tag):
        raise ValueError("invalid BMES release version")
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    headers = {"User-Agent": "Nexaloid-release"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    base = f"https://github.com/{repo}/releases/download/{tag}"
    for name in ASSETS:
        request = urllib.request.Request(f"{base}/{name}", headers=headers)
        with urllib.request.urlopen(request, timeout=60) as response, (root / name).open("wb") as output:
            shutil.copyfileobj(response, output)


def write_archive(source: Path, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=output.parent, suffix=".zip", delete=False) as tmp:
        temporary = Path(tmp.name)
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for name in ASSETS:
                archive.write(source / name, name)
        os.replace(temporary, output)
    finally:
        temporary.unlink(missing_ok=True)


def self_test() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        payload = b"NXBMES01-test"
        digest = hashlib.sha256(payload).hexdigest()
        (root / ASSETS[0]).write_bytes(payload)
        (root / ASSETS[1]).write_text(f"{digest}  {ASSETS[0]}\n", encoding="utf-8")
        (root / ASSETS[2]).write_text(
            json.dumps(
                {
                    "schema": "nexaloid.bmes_manifest.v1",
                    "artifact_format": "nxbmes.v1",
                    "artifact_sha256": digest,
                    "distribution": {"scope": "public", "license_spdx": "Apache-2.0"},
                }
            ),
            encoding="utf-8",
        )
        (root / ASSETS[3]).write_text(
            "SPDX-License-Identifier: Apache-2.0\nDistribution: public\n",
            encoding="utf-8",
        )
        validate_bundle(root, digest)
        manifest = json.loads((root / ASSETS[2]).read_text(encoding="utf-8"))
        manifest["distribution"]["scope"] = "internal"
        (root / ASSETS[2]).write_text(json.dumps(manifest), encoding="utf-8")
        try:
            validate_bundle(root, digest)
        except ValueError:
            pass
        else:
            raise AssertionError("internal BMES artifact was accepted")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default="Nexaloid/NexaloidBMES")
    parser.add_argument("--version")
    parser.add_argument("--expected-sha256")
    parser.add_argument("--source-dir", type=Path)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        self_test()
        print("entity_bmes_fetch_ok")
        return 0
    if not args.expected_sha256 or not args.out:
        parser.error("--expected-sha256 and --out are required")
    if args.source_dir is None and not args.version:
        parser.error("--version is required unless --source-dir is used")

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        if args.source_dir is None:
            download_release(args.repo, args.version, root)
        else:
            for name in ASSETS:
                shutil.copy2(args.source_dir / name, root / name)
        validate_bundle(root, args.expected_sha256)
        write_archive(root, args.out)
    print(args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
