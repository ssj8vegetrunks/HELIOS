# Public Alpha site map

## Public entry points

| Path | Purpose | Hardware writes |
|---|---|---|
| `install.lua` | HELIOS Mainframe/Remote/Guardian installer, with hidden debug utilities | Only after role setup and explicit operation |
| `discovery_probe.lua` | Standalone peripheral and method inventory | No |
| `draconic_guardian.lua` | Standalone Draconic Reactor Guardian | Yes, guarded and locally authoritative |
| `module-template/` | Copyable Lua developer starter | No; actuator examples fail closed |

The installer presents Mainframe and Remote Terminal as HELIOS computer roles.
The read-only Probe and Draconic Guardian are selected from the separate
`Modules` submenu. The read-only Draconic Profiler remains available only
through the hidden maintainer/debug path.

## Repository layout

```text
HELIOS/
|-- README.md
|-- install.lua
|-- discovery_probe.lua
|-- draconic_guardian.lua
|-- docs/
|   |-- README.md
|   |-- TESTING.md
|   |-- SITE_MAP.md
|   |-- DEPENDENCY_MAP.md
|   |-- LANGUAGE_PACKS.md
|   `-- detailed design/API references
|-- module-template/
|   |-- README.md
|   |-- manifest.example.json
|   `-- example_adapter.lua
|-- module-pack/
|   |-- manifest.json
|   |-- extreme_reactors/
|   `-- universal_energy/
|-- src/
|   |-- core/
|   |-- draconic/
|   |-- mainframe/
|   |-- terminal/
|   |-- gui/
|   |-- lang/
|   `-- helios.lua
|-- scripts/
`-- tests/
```

## Installed layout

```text
/helios/
|-- helios.lua
|-- core/
|-- data/            (persistent local state and facility registry)
|-- draconic/        (Draconic Guardian and Profiler roles)
|-- gui/
|-- lang/            (English fallback and installed language packs)
|-- mainframe/       (Mainframe role)
|-- terminal/        (Remote role)
|-- modules/         (Mainframe role; downloaded Module Pack)
`-- tools/
    `-- discovery_probe.lua
```

The Guardian safety loop remains locally authoritative and operates without a
network link. A persistent Guardian installation reuses HELIOS Core only for
startup, storage, and the read-only facility-network transport.

The Profiler records one-second warm-reactor telemetry and builds persistent
250 kRF/t output-bracket histories under
`/helios/data/draconic-profiler/`. It is paired to one Guardian computer ID and
has no reactor or flow-gate access.
