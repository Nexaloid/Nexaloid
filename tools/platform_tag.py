from __future__ import annotations

import platform
import sys


def platform_tag() -> str:
    os_name = {"win32": "windows", "darwin": "darwin"}.get(sys.platform, "linux")
    machine = platform.machine().lower()
    arch = "x64" if machine in {"amd64", "x86_64"} else "arm64" if machine in {"arm64", "aarch64"} else machine
    return f"{os_name}-{arch}"
