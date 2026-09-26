#!/usr/bin/env python3
"""Build the HELIOS role/feature package manifest.

The bootstrap installer downloads this manifest and only the packages selected
for one computer. Package membership is deliberately explicit: adding a source
file cannot silently add it to every HELIOS installation.
"""

import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "packages" / "manifest.json"
VERSION = "1.6.0-alpha.47"
DOFILE = re.compile(r'dofile\(\s*["\']/helios/(?P<path>[^"\']+\.lua)["\']\s*\)')


PACKAGES = {
    "core": {
        "kind": "core",
        "name": "HELIOS Core",
        "required": [],
        "files": [
            "src/helios.lua",
            "src/core/accessibility.lua",
            "src/core/calculations.lua",
            "src/core/config.lua",
            "src/core/i18n.lua",
            "src/core/power_format.lua",
            "src/lang/en_us.lua",
        ],
    },
    "mainframe": {
        "kind": "role",
        "name": "Mainframe",
        "required": ["core", "official_hardware"],
        "files": [
            "src/core/boot.lua", "src/core/display.lua", "src/core/facility_protocol.lua",
            "src/core/gui.lua", "src/core/gui_loader.lua", "src/core/mainframe_authority.lua",
            "src/core/module_loader.lua", "src/core/module_manager.lua", "src/core/network.lua",
            "src/core/network_security.lua", "src/core/ui.lua",
            "src/core/ui_contract.lua", "src/mainframe/device_registry.lua", "src/mainframe/main.lua",
            "src/mainframe/manual_control.lua", "src/mainframe/reactor_governor.lua",
            "src/mainframe/turbine_governor.lua",
        ],
    },
    "terminal": {
        "kind": "role",
        "name": "Remote Terminal",
        "required": ["core"],
        "files": [
            "src/core/boot.lua", "src/core/display.lua", "src/core/gui.lua",
            "src/core/gui_loader.lua", "src/core/network.lua", "src/core/network_security.lua",
            "src/core/ui.lua", "src/core/ui_contract.lua",
            "src/terminal/main.lua",
        ],
    },
    "guardian": {
        "kind": "role",
        "name": "Draconic Guardian",
        "required": ["core"],
        "files": [
            "src/core/boot.lua", "src/core/facility_protocol.lua", "src/core/network.lua",
            "src/core/network_security.lua", "draconic_guardian.lua",
        ],
        "destinations": {"draconic_guardian.lua": "draconic/controller.lua"},
    },
    "profiler": {
        "kind": "role",
        "name": "Draconic Profiler",
        "required": ["core"],
        "files": [
            "src/core/network_security.lua", "src/draconic/profiler.lua",
            "src/draconic/profiler_engine.lua",
        ],
    },
    "official_hardware": {
        "kind": "hardware",
        "name": "Official Hardware Modules",
        "required": ["core"],
        "files": [
            "module-pack/manifest.json", "module-pack/extreme_reactors/reactor_adapter.lua",
            "module-pack/extreme_reactors/turbine_adapter.lua",
            "module-pack/universal_energy/storage_adapter.lua",
        ],
        "destinations": {
            "module-pack/manifest.json": "modules/manifest.json",
            "module-pack/extreme_reactors/reactor_adapter.lua": "modules/extreme_reactors/reactor_adapter.lua",
            "module-pack/extreme_reactors/turbine_adapter.lua": "modules/extreme_reactors/turbine_adapter.lua",
            "module-pack/universal_energy/storage_adapter.lua": "modules/universal_energy/storage_adapter.lua",
        },
    },
    "captains_log": {
        "kind": "feature",
        "name": "Event Viewer",
        "required": [],
        "files": ["src/core/event_log.lua", "src/core/log_viewer.lua"],
    },
    "control_room": {
        "kind": "gui",
        "name": "Control Room GUI",
        "required": ["core"],
        "files": ["src/gui/control-room/manifest.lua", "src/gui/control-room/renderer.lua"],
    },
    "discovery_probe": {
        "kind": "tool",
        "name": "Hardware Discovery Probe",
        "required": [],
        "files": ["discovery_probe.lua"],
        "destinations": {"discovery_probe.lua": "tools/discovery_probe.lua"},
    },
}

for language_id in ("de_de", "en_pi", "es_es", "fr_ca"):
    PACKAGES[f"language_{language_id}"] = {
        "kind": "language",
        "name": language_id,
        "required": [],
        "files": [f"src/lang/{language_id}.lua"],
    }


def destination(source: str, overrides: dict[str, str]) -> str:
    if source in overrides:
        return overrides[source]
    return source.removeprefix("src/")


def main() -> None:
    output = {"schema_version": 1, "core_version": VERSION, "packages": {}}
    claimed: dict[tuple[str, str], str] = {}
    for package_id, definition in PACKAGES.items():
        overrides = definition.get("destinations", {})
        files = []
        for source in definition["files"]:
            path = ROOT / source
            if not path.is_file():
                raise SystemExit(f"{package_id}: missing {source}")
            target = destination(source, overrides)
            if target.startswith("/") or ".." in Path(target).parts:
                raise SystemExit(f"{package_id}: unsafe destination {target}")
            # GitHub raw serves the repository's normalized LF blobs even when
            # a Windows checkout uses mixed or CRLF working-tree endings.
            blob_size = len(path.read_bytes().replace(b"\r\n", b"\n").replace(b"\r", b"\n"))
            files.append({"source": source, "path": target, "bytes": blob_size})
            key = (package_id, target)
            if key in claimed:
                raise SystemExit(f"{package_id}: duplicate destination {target}")
            claimed[key] = source
        output["packages"][package_id] = {
            "kind": definition["kind"], "name": definition["name"],
            "required": definition["required"], "files": files,
        }
    for package_id, package in output["packages"].items():
        for dependency in package["required"]:
            if dependency not in output["packages"]:
                raise SystemExit(f"{package_id}: missing required package {dependency}")

    # Verify direct runtime dependencies for each role closure. The common
    # command dispatcher is intentionally role-aware, and Event Viewer is an
    # explicitly optional dependency guarded by existence checks.
    optional_paths = {"config.lua", "core/event_log.lua", "core/log_viewer.lua"}
    for role in ("mainframe", "terminal", "guardian", "profiler"):
        selected, stack = set(), [role]
        while stack:
            package_id = stack.pop()
            if package_id in selected:
                continue
            selected.add(package_id);stack.extend(output["packages"][package_id]["required"])
        installed = {
            item["path"] for package_id in selected
            for item in output["packages"][package_id]["files"]
        }
        for package_id in selected:
            for item in output["packages"][package_id]["files"]:
                if item["path"] == "helios.lua" or not item["source"].endswith(".lua"):
                    continue
                text = (ROOT / item["source"]).read_text(encoding="utf-8")
                for match in DOFILE.finditer(text):
                    dependency = match.group("path")
                    if dependency not in installed and dependency not in optional_paths:
                        raise SystemExit(
                            f"{role}: {item['path']} requires uninstalled {dependency}"
                        )
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(output, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {len(output['packages'])} HELIOS packages to {OUTPUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
