# HELIOS UI Contract v1

The UI contract is the stable boundary between HELIOS plant logic and every
renderer: the built-in text UI, future graphical monitor modules, remote
read-only terminals, and later web clients.

## Non-negotiable boundary

Graphical modules never receive peripheral handles and never call reactor,
turbine, or storage adapters. They receive serializable snapshots and submit
command envelopes to HELIOS Core. Core validates authority and safety before a
registered guarded handler may act.

```text
Adapters -> State/governors -> UI snapshot -> Renderer
Renderer -> Command envelope -> Contract guard -> Core handler -> Adapter
```

The existing text interface remains installed and selectable even when a GUI
module is present. A missing or failed GUI must not interrupt telemetry,
governors, alarms, or manual fallback control.

## Snapshot contract

`core/ui_contract.lua` attaches a `uiContract` descriptor to the existing
HELIOS snapshot. Contract normalization removes functions, peripheral objects,
and cyclic references before data crosses the UI boundary.

The descriptor advertises:

- contract name `helios.ui`;
- integer contract version `1`;
- supported command names and their authority requirements;
- telemetry-only, guarded-dispatch, and text-fallback guarantees.

The current plant fields remain compatible with remote terminals:
`reactors`, `turbines`, `storages`, `alarm`, `control`, `power`, `aliases`, and
identity-conflict state. Later contract versions may add fields but must not
silently change the meaning of an existing field.

## Command envelope

```lua
{
  name = "turbine.adjust_flow",
  target = "BigReactors-Turbine_0",
  arguments = { delta = 100 },
  confirmed = false,
}
```

Contract v1 reserves these commands:

| Command | Required authority |
|---|---|
| `navigate` | Local UI only |
| `alarm.silence` | Local operator |
| `control.set_authority` | Local operator plus confirmation |
| `reactor.set_active` | Manual authority |
| `reactor.adjust_rods` | Manual authority |
| `turbine.set_active` | Manual authority |
| `turbine.adjust_flow` | Manual authority |

Reservation does not enable an actuator. A command can run only when Core has
registered a guarded handler for that exact name. Unknown commands and missing
handlers fail closed.

## Mandatory guards

Before dispatch, Core rejects:

- every command originating from a remote/read-only UI;
- every command while a duplicate computer-ID conflict exists;
- manual actuator commands outside Manual authority;
- confirmation-required commands without explicit confirmation;
- malformed targets or arguments;
- commands without a registered Core handler.

Existing reactor/turbine verification, reserve protection, alarm handling,
governors, and automatic/manual ownership remain authoritative after contract
validation. The contract is an additional gate, never a replacement safety
system.

## Graphical module lifecycle

A future GUI module will:

1. declare a compatible `helios.ui` contract version;
2. receive normalized snapshots from Core;
3. render without blocking the plant loop;
4. submit only documented command envelopes;
5. tolerate missing telemetry as `N/A` or stale;
6. surrender cleanly to the built-in text UI after failure or operator choice.

The first graphical milestone should be a read-only facility overview. Manual
graphical control should be introduced only after that renderer survives normal,
missing-telemetry, alarm, resize, and module-failure testing.
