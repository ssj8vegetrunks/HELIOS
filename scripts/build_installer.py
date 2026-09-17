#!/usr/bin/env python3
"""Compatibility entrypoint for the modular HELIOS packaging build."""

import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    subprocess.run([sys.executable, str(ROOT / "scripts" / "build_packages.py")], check=True)
    installer = ROOT / "install.lua"
    print(f"Modular bootstrap: {installer.stat().st_size} bytes ({installer.name})")


if __name__ == "__main__":
    main()
