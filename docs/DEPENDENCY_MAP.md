# Public Alpha modular dependency map

```text
install.lua (small bootstrap; no runtime payload)
`-- packages/manifest.json
    |-- core
    |   |-- role: mainframe
    |   |   `-- official_hardware
    |   |-- role: terminal
    |   |-- role: guardian
    |   `-- role: profiler
    |-- optional GUI: control_room
    |-- optional feature: captains_log
    |-- optional tool: discovery_probe
    `-- optional languages: de_de / en_pi / es_es / fr_ca
```

Every computer receives `core` and exactly one role. Package membership is explicit in
`packages/manifest.json`; adding a source file does not automatically put it into an installation.
Core exposes the versioned `core/calculations.lua` interface for reusable numerical formulas and
`core/power_format.lua` for energy conversion and display formatting.

## Boundary rules

- Mainframe owns plant-wide scheduling and installs official hardware adapters.
- Remote Terminals install no hardware adapters and never own actuators.
- The Draconic Guardian contains its complete local safety loop but no Mainframe implementation.
- The Profiler contains only its read-only profiling role and shared dependencies.
- Captain's Log, non-English languages, the Control Room GUI, and the discovery probe install only
  when selected.
- The bootstrap verifies manifest version, paths, dependency closure, duplicate destinations, and
  downloaded file sizes before installation.
- Installed control and safety never require GitHub or a removable disk to remain available.
- Hardware adapters call Core's shared formulas but retain their device-specific API translation.
- Guardian containment mathematics remains local and self-contained as a safety boundary.

For generated package membership, file dependencies, and blast radius, see
[`SOURCE_MAP.md`](SOURCE_MAP.md) and [`DEPENDENCY_TREE.md`](DEPENDENCY_TREE.md).
