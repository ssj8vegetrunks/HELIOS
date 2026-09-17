# Public Alpha site map

## Public entry points

| Path | Purpose | Hardware writes |
|---|---|---|
| `install.lua` | Small modular bootstrap for all HELIOS computer roles | No |
| `packages/manifest.json` | Explicit Core, role, feature, language, GUI, and tool packages | No |
| `discovery_probe.lua` | Standalone peripheral and method inventory | No |
| `draconic_guardian.lua` | Standalone Draconic Reactor Guardian | Yes, guarded and locally authoritative |
| `module-template/` | Copyable Lua developer starter | No; actuator examples fail closed |

The bootstrap presents Mainframe, Remote Terminal, Draconic Guardian, and
Draconic Profiler as separate roles. The read-only Probe, Event Viewer,
Control Room GUI, and non-English languages are optional packages.

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
|-- packages/
|   `-- manifest.json
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
|-- draconic/        (only on Guardian or Profiler roles)
|-- gui/             (only selected GUI packages)
|-- lang/            (English fallback and installed language packs)
|-- mainframe/       (only on Mainframe role)
|-- terminal/        (only on Remote Terminal role)
|-- modules/         (Mainframe role; downloaded Module Pack)
`-- tools/           (only selected tool packages)
    `-- discovery_probe.lua
```

The Guardian safety loop remains locally authoritative and operates without a
network link. A persistent Guardian installation reuses HELIOS Core only for
startup, storage, and the read-only facility-network transport.
