# Public Alpha site map

## Public entry points

| Path | Purpose | Hardware writes |
|---|---|---|
| `install.lua` | HELIOS Mainframe/Remote installer | Only after role setup and explicit operation |
| `discovery_probe.lua` | Standalone peripheral and method inventory | No |
| `draconic_guardian.lua` | Standalone Draconic Reactor Guardian | Yes, guarded and locally authoritative |
| `module-template/` | Copyable Lua developer starter | No; actuator examples fail closed |

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
|-- gui/
|-- mainframe/       (Mainframe role)
|-- terminal/        (Remote role)
|-- modules/         (Mainframe role; downloaded Module Pack)
`-- tools/
    `-- discovery_probe.lua
```

The standalone Guardian is intentionally separate from HELIOS Core during this
Alpha. Its proven local safety loop must not become dependent on a network link.
