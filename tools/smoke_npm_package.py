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
            "const { Tokenizer } = require('@nexaloid/nexaloid');"
            "const t = new Tokenizer();"
            "const words = t.lcut('南京市长江大桥').join('/');"
            "t.close();"
            "if (words !== '南京市/长江大桥') throw new Error(words);"
        )
        subprocess.run([node, "-e", script], cwd=tmp_path, check=True)
    tarball.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
