#!/usr/bin/env python3
"""Rebuild install.lua's embedded FILES table from src/."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "install.lua"
START = "FILES = {\n"
END = "\n}\n\nlocal function installStartup()"


def lua_long_string(text: str) -> str:
    equals = "="
    while f"]{equals}]" in text:
        equals += "="
    return f"[{equals}[\n{text.rstrip()}\n]{equals}]"


def main() -> None:
    installer = INSTALLER.read_text()
    before, remainder = installer.split(START, 1)
    _, after = remainder.split(END, 1)

    entries = []
    for source in sorted((ROOT / "src").rglob("*.lua")):
        relative = source.relative_to(ROOT / "src").as_posix()
        entries.append(f'    ["{relative}"] = {lua_long_string(source.read_text())},')

    # The probe intentionally remains a single downloadable file at the
    # repository root, while the installer also exposes it as `helios probe`.
    probe = ROOT / "discovery_probe.lua"
    entries.append(
        f'    ["tools/discovery_probe.lua"] = {lua_long_string(probe.read_text())},'
    )

    rebuilt = before + START + "\n\n".join(entries) + END + after
    INSTALLER.write_text(rebuilt)
    print(f"Embedded {len(entries)} Lua programs in {INSTALLER.name}")


if __name__ == "__main__":
    main()
