from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import tarfile
import zipfile
from datetime import datetime, timezone
from typing import BinaryIO
from pathlib import Path


ARTIFACT_SUFFIXES = (".crate", ".tgz", ".whl", ".zip")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def stream_hashes(stream: BinaryIO) -> tuple[str, str]:
    sha1_digest = hashlib.sha1(usedforsecurity=False)
    sha256_digest = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        sha1_digest.update(chunk)
        sha256_digest.update(chunk)
    return sha1_digest.hexdigest(), sha256_digest.hexdigest()


def archive_members(path: Path) -> list[tuple[str, str, str]]:
    members: list[tuple[str, str, str]] = []
    if path.suffix.lower() in {".zip", ".whl"}:
        with zipfile.ZipFile(path) as archive:
            for info in sorted(archive.infolist(), key=lambda item: item.filename):
                if info.is_dir():
                    continue
                with archive.open(info) as stream:
                    sha1_digest, sha256_digest = stream_hashes(stream)
                members.append((info.filename, sha1_digest, sha256_digest))
        return members

    with tarfile.open(path, mode="r:*") as archive:
        for info in sorted(archive.getmembers(), key=lambda item: item.name):
            if not info.isfile():
                continue
            stream = archive.extractfile(info)
            if stream is None:
                raise ValueError(f"failed to read {info.name!r} from {path}")
            with stream:
                sha1_digest, sha256_digest = stream_hashes(stream)
            members.append((info.name, sha1_digest, sha256_digest))
    return members


def spdx_id(index: int, name: str) -> str:
    normalized = re.sub(r"[^A-Za-z0-9.-]", "-", name)
    return f"SPDXRef-Package-{index}-{normalized}"


def generate(input_dir: Path, output_dir: Path, version: str, source_uri: str) -> tuple[Path, Path]:
    output_dir = output_dir.resolve()
    artifacts = sorted(
        path
        for path in input_dir.resolve().rglob("*")
        if path.is_file()
        and path.suffix.lower() in ARTIFACT_SUFFIXES
        and output_dir not in path.parents
    )
    if not artifacts:
        raise ValueError(f"no release artifacts found under {input_dir}")

    records = [(path, sha256(path)) for path in artifacts]
    output_dir.mkdir(parents=True, exist_ok=True)
    sums_path = output_dir / "SHA256SUMS"
    with sums_path.open("w", encoding="utf-8", newline="\n") as stream:
        stream.write(
            "".join(f"{digest}  {path.relative_to(input_dir.resolve()).as_posix()}\n" for path, digest in records)
        )

    epoch = os.environ.get("SOURCE_DATE_EPOCH")
    created = (
        datetime.fromtimestamp(int(epoch), timezone.utc)
        if epoch is not None
        else datetime.now(timezone.utc)
    ).strftime("%Y-%m-%dT%H:%M:%SZ")
    packages = []
    files = []
    relationships = []
    namespace_material = [source_uri, version]
    for index, (path, digest) in enumerate(records, 1):
        relative = path.relative_to(input_dir.resolve()).as_posix()
        package_id = spdx_id(index, relative)
        members = archive_members(path)
        namespace_material.extend((relative, digest))
        verification_input = "".join(sorted(member_sha1 for _, member_sha1, _ in members))
        packages.append(
            {
                "SPDXID": package_id,
                "name": relative,
                "versionInfo": version,
                "downloadLocation": "NOASSERTION",
                "filesAnalyzed": True,
                "checksums": [{"algorithm": "SHA256", "checksumValue": digest}],
                "packageVerificationCode": {
                    "packageVerificationCodeValue": hashlib.sha1(
                        verification_input.encode("ascii"), usedforsecurity=False
                    ).hexdigest()
                },
                "licenseConcluded": "NOASSERTION",
                "licenseDeclared": "NOASSERTION",
                "copyrightText": "NOASSERTION",
                "supplier": "Organization: Nexaloid",
            }
        )
        relationships.append(
            {
                "spdxElementId": "SPDXRef-DOCUMENT",
                "relationshipType": "DESCRIBES",
                "relatedSpdxElement": package_id,
            }
        )

        for member_index, (member_name, _, member_sha256) in enumerate(members, 1):
            file_id = f"SPDXRef-File-{index}-{member_index}"
            files.append(
                {
                    "SPDXID": file_id,
                    "fileName": f"./{relative}!/{member_name}",
                    "checksums": [{"algorithm": "SHA256", "checksumValue": member_sha256}],
                    "licenseConcluded": "NOASSERTION",
                    "copyrightText": "NOASSERTION",
                }
            )
            relationships.append(
                {
                    "spdxElementId": package_id,
                    "relationshipType": "CONTAINS",
                    "relatedSpdxElement": file_id,
                }
            )

    namespace_seed = hashlib.sha256("\0".join(namespace_material).encode()).hexdigest()
    document = {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"Nexaloid release {version}",
        "documentNamespace": f"{source_uri.rstrip('/')}/sbom/{namespace_seed}",
        "creationInfo": {
            "created": created,
            "creators": ["Tool: Nexaloid-generate-release-evidence"],
            "licenseListVersion": "3.26",
        },
        "packages": packages,
        "files": files,
        "relationships": relationships,
    }
    sbom_path = output_dir / "nexaloid-release.spdx.json"
    with sbom_path.open("w", encoding="utf-8", newline="\n") as stream:
        stream.write(json.dumps(document, ensure_ascii=False, indent=2) + "\n")
    return sums_path, sbom_path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("input_dir", type=Path)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--source-uri", default="https://github.com/Nexaloid/Nexaloid")
    args = parser.parse_args()
    sums, sbom = generate(args.input_dir, args.output_dir, args.version, args.source_uri)
    print(sums)
    print(sbom)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
