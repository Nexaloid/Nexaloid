from __future__ import annotations

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
    filename = __import__("json").loads(result.stdout)[0]["filename"]
    tarball = ROOT / "bindings/node" / filename
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        subprocess.run([npm, "init", "-y"], cwd=tmp_path, check=True, stdout=subprocess.DEVNULL)
        subprocess.run([npm, "install", str(tarball)], cwd=tmp_path, check=True)
        script = (
            "const fs = require('node:fs');"
            "const path = require('node:path');"
            "const { Tokenizer, entityArtifactPath, entityManifest, entityManifestPath, entityPluginPath, hmmArtifactPath, hmmManifestPath } = require('@nexaloid/nexaloid');"
            "if (!fs.existsSync(hmmArtifactPath)) throw new Error(hmmArtifactPath);"
            "if (!fs.existsSync(hmmManifestPath)) throw new Error(hmmManifestPath);"
            "if (!fs.existsSync(entityArtifactPath)) throw new Error(entityArtifactPath);"
            "if (!fs.existsSync(entityManifestPath)) throw new Error(entityManifestPath);"
            "if (!fs.existsSync(entityPluginPath)) throw new Error(entityPluginPath);"
            "if (!fs.existsSync(path.join(path.dirname(entityArtifactPath), 'APACHE-2.0.txt'))) throw new Error('missing Apache-2.0 text');"
            "if (entityManifest().quality.test.f1 < 0.86) throw new Error('bad entity model');"
            "const t = new Tokenizer();"
            "const words = t.lcut('南京市长江大桥').join('/');"
            "t.close();"
            "if (words !== '南京市/长江大桥') throw new Error(words);"
            "const e = new Tokenizer();"
            "e.loadPlugin(entityPluginPath, JSON.stringify({artifact: entityArtifactPath}));"
            "const entities = e.tokenize('梅花鹿', 0);"
            "e.close();"
            "if (!entities.some((token) => token.text === '梅花鹿' && token.source === 6)) throw new Error(JSON.stringify(entities));"
        )
        subprocess.run([node, "-e", script], cwd=tmp_path, check=True)
    tarball.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
