# Public Alpha site map

## Public entry points

| Path | Purpose | Hardware writes |
|---|---|---|
| `install.lua` | HELIOS Mainframe/Remote/Guardian installer | Only after role setup and explicit operation |
| `discovery_probe.lua` | Standalone peripheral and method inventory | No |
| `draconic_guardian.lua` | Standalone Draconic Reactor Guardian | Yes, guarded and locally authoritative |
| `module-template/` | Copyable Lua developer starter | No; actuator examples fail closed |

The installer presents Mainframe and Remote Terminal as HELIOS computer roles.
Read-only Probe and the Draconic Guardian are selected from the separate
`Modules` submenu.

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
|-- draconic/        (Draconic Guardian role)
|-- gui/
|-- mainframe/       (Mainframe role)
|-- terminal/        (Remote role)
|-- modules/         (Mainframe role; downloaded Module Pack)
`-- tools/
    `-- discovery_probe.lua
```

The Guardian safety loop remains locally authoritative and operates without a
network link. A persistent Guardian installation reuses HELIOS Core only for
startup, storage, and the read-only facility-network transport.
