from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    npm = shutil.which("npm")
    node = shutil.which("node")
    if npm is None or node is None:
        raise RuntimeError("npm and node must be on PATH")
    result = subprocess.run(
        [npm, "pack", "--json"],
        cwd=ROOT / "bindings/node",
        check=True,
        capture_output=True,
        text=True,
    )
    package = __import__("json").loads(result.stdout)[0]
    filename = package["filename"]
    if os.environ.get("NEXALOID_REQUIRE_ALL_PREBUILDS") == "1":
        files = {item["path"].replace("\\", "/") for item in package["files"]}
        expected = {
            f"prebuilds/{platform}/nexaloid_plugin_{stem}.{extension}"
            for platform, extension in (
                ("linux-x64", "so"),
                ("linux-arm64", "so"),
                ("windows-x64", "dll"),
                ("darwin-x64", "dylib"),
                ("darwin-arm64", "dylib"),
            )
            for stem in ("entity_bmes", "hmm_lattice")
        }
        missing = sorted(expected - files)
        if missing:
            raise RuntimeError(f"missing npm prebuilds: {', '.join(missing)}")
    tarball = ROOT / "bindings/node" / filename
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        subprocess.run([npm, "init", "-y"], cwd=tmp_path, check=True, stdout=subprocess.DEVNULL)
        subprocess.run([npm, "install", str(tarball)], cwd=tmp_path, check=True)
        script = (
            "const fs = require('node:fs');"
            "const path = require('node:path');"
            "const { Tokenizer, entityArtifactPath, entityManifest, entityManifestPath, entityPluginPath, hmmArtifactPath, hmmManifestPath, hmmPluginPath } = require('@nexaloid/nexaloid');"
            "if (!fs.existsSync(hmmArtifactPath)) throw new Error(hmmArtifactPath);"
            "if (!fs.existsSync(hmmManifestPath)) throw new Error(hmmManifestPath);"
            "if (!fs.existsSync(hmmPluginPath)) throw new Error(hmmPluginPath);"
            "if (!fs.existsSync(entityArtifactPath)) throw new Error(entityArtifactPath);"
            "if (!fs.existsSync(entityManifestPath)) throw new Error(entityManifestPath);"
            "if (!fs.existsSync(entityPluginPath)) throw new Error(entityPluginPath);"
            "if (!fs.existsSync(path.join(path.dirname(entityArtifactPath), 'APACHE-2.0.txt'))) throw new Error('missing Apache-2.0 text');"
            "if (entityManifest().quality.test.f1 < 0.86) throw new Error('bad entity model');"
            "const t = new Tokenizer();"
            "const words = t.lcut('南京市长江大桥').join('/');"
            "t.close();"
            "if (words !== '南京市/长江大桥') throw new Error(words);"
            "const h = new Tokenizer();"
            "h.loadPlugin(hmmPluginPath, hmmArtifactPath);"
            "const hmmWords = h.lcut('并参与杭算项目').join('/');"
            "h.close();"
            "if (hmmWords !== '并/参与/杭算/项目') throw new Error(hmmWords);"
            "const e = new Tokenizer();"
            "e.loadPlugin(entityPluginPath, JSON.stringify({artifact: entityArtifactPath}));"
            "const entities = e.tokenize('欧盟委员会', 0);"
            "e.close();"
            "if (!entities.some((token) => token.text === '欧盟委员会' && token.source === 6)) throw new Error(JSON.stringify(entities));"
        )
        subprocess.run([node, "-e", script], cwd=tmp_path, check=True)
    tarball.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
