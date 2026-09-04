#!/usr/bin/env python3
"""Validate the official HELIOS Module Pack manifest and referenced files."""

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PACK = ROOT / "module-pack"
MANIFEST = PACK / "manifest.json"
REQUIRED_CAPABILITIES = {"reactor_adapter", "turbine_adapter", "storage_adapter"}


def main() -> None:
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    assert manifest.get("schema_version") == 1, "Unsupported module manifest schema"
    assert isinstance(manifest.get("pack"), dict), "Missing pack metadata"
    assert manifest["pack"].get("version"), "Missing Module Pack version"
    assert manifest.get("compatible_core_versions"), "Missing compatible Core versions"

    capabilities = set()
    module_ids = set()
    for module in manifest.get("modules", []):
        module_id = module.get("id")
        assert module_id and module_id not in module_ids, f"Invalid or duplicate module id: {module_id}"
        module_ids.add(module_id)
        assert module.get("version"), f"Missing version for module {module_id}"
        for provider in module.get("provides", []):
            capability = provider.get("capability")
            path = provider.get("path")
            assert capability and capability not in capabilities, f"Duplicate capability: {capability}"
            assert path and not path.startswith("/") and ".." not in Path(path).parts, f"Unsafe path: {path}"
            assert (PACK / path).is_file(), f"Missing module file: {path}"
            capabilities.add(capability)

    missing = REQUIRED_CAPABILITIES - capabilities
    assert not missing, f"Missing required capabilities: {', '.join(sorted(missing))}"
    print(f"Validated Module Pack {manifest['pack']['version']}: "
          f"{len(module_ids)} modules, {len(capabilities)} capabilities")


if __name__ == "__main__":
    main()
