# Public Alpha dependency map

```text
install.lua
`-- HELIOS Core
    |-- Mainframe
    |   |-- peripheral discovery
    |   |-- safety/governors
    |   |-- official Module Pack
    |   |   |-- Extreme Reactors adapters
    |   |   `-- Universal Energy Storage adapter
    |   |-- local displays + helios.v1 terminal snapshots
    |   `-- helios.facility.v1 Guardian registration + telemetry
    `-- Remote
        `-- read-only network snapshots + local display

discovery_probe.lua
`-- CC:Tweaked peripheral API only (standalone, read-only)

draconic_guardian.lua
|-- CC:Tweaked
|-- Advanced Peripherals / Draconic Evolution peripheral integration
|-- local reactor, injector and two Flux Gate peripherals
|-- optional Advanced Monitor
`-- optional HELIOS Core networking modules (read-only facility link)

module-template/
`-- developer source only; not installed or loaded automatically
```

## Boundary rules

- Mainframe owns plant-wide scheduling and HELIOS hardware adapters.
- Remote terminals never load hardware adapters and never own actuators.
- The Probe observes names, types, and methods; it never calls setters.
- The Draconic Guardian owns its reactor safety locally. Network loss must not
  weaken or stop its safety loop.
- A module file is loaded only when explicitly declared by a compatible Module
  Pack manifest.
- The public template is telemetry-only until its developer deliberately adds
  guarded commands, verification, and failure behavior.

For inferred file-to-file dependencies and bundled line numbers, see
[`DEPENDENCY_TREE.md`](DEPENDENCY_TREE.md) and [`SOURCE_MAP.md`](SOURCE_MAP.md).
