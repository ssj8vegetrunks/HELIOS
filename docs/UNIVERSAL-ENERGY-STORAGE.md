# HELIOS — Universal Energy Storage Architecture

## Goal

HELIOS should monitor unfamiliar energy-storage devices at a basic level, then
automatically use a richer device-specific adapter when one is available.

The model is similar to a basic display driver: the generic driver provides a
working minimum, while a specialized driver unlocks everything the device can
report.

## Adapter priority

For each discovered peripheral, HELIOS checks in this order:

1. **Specific adapter** — a known device such as a Mekanism Induction Matrix.
2. **Generic storage adapter** — a device exposing recognizable stored-energy
   and capacity methods.
3. **Unknown** — insufficient evidence to identify it safely.

HELIOS must never classify a device as storage from its name alone. A generic
match requires usable energy methods. Reactor and turbine internal buffers stay
on their own telemetry screens and are not listed as separate batteries.

## Generic storage adapter

The generic adapter should provide whatever the peripheral exposes:

- Stored energy
- Maximum capacity
- Charge percentage
- Net change over time
- Charging, draining, full, empty, or stable state
- Estimated time until full or empty
- Telemetry status

If the device does not expose input and output rates separately, HELIOS samples
stored energy once per second and calculates the net change:

```text
net change = current stored energy - previous stored energy
```

Separate input and output remain `N/A` unless the device reports them directly.

## Specialized adapters

A specialized adapter may add accurate device-specific information, including:

- Separate input and output rates
- Transfer limits
- Cell, provider, or multiblock statistics
- Device operating state
- Mod-specific warnings or limits

The first specialized adapter will target the Mekanism Induction Matrix. Future
adapters can support Powah, Ender IO, Thermal, Integrated Dynamics, or other
storage systems without changing the storage screen.

If a specialized adapter fails after a mod update, HELIOS should attempt the
generic adapter before marking the device unavailable.

## Standard storage record

Every adapter returns the same basic structure. Unavailable values are `nil`.

```lua
{
    id = "inductionPort_1",
    name = "Main Battery",
    adapter = "mekanism_induction",
    stored = 3.7e12,
    capacity = 6.4e12,
    input = 305600,
    output = 180200,
    net = 125400,
    percent = 57.8,
    state = "CHARGING",
    etaSeconds = 22680,
    nativeUnit = "FE",
    telemetryOk = true,
    details = {}
}
```

The dashboard, aliases, compact-number formatting, alarms, and future remote
terminals consume this standard record. They do not need to know which mod or
adapter supplied it.

## Display behavior

The storage tab uses the existing global power-display preferences:

```text
Main Battery                         57.8%
Stored:   3.7T / 6.4T FE
Input:    305.6k FE/t
Output:   180.2k FE/t
Net:      +125.4k FE/t
State:    CHARGING
Full in:  6h 18m
```

Custom names remain primary. Raw peripheral names appear only when **Show
peripheral names** is enabled.

## Safety rules

- Storage monitoring is read-only in this milestone.
- One failed adapter must not stop other devices from updating.
- Missing fields display `N/A`; they are not treated as zero.
- Method calls are protected so a broken or changed peripheral API cannot crash
  HELIOS.
- Classification prefers certainty over guessing.
- Full-precision values are retained internally even when the display is
  compact.

## First implementation — v0.3.2-alpha.1

The first storage milestone implements:

1. The universal storage record and adapter manager.
2. Generic stored-energy and capacity detection.
3. Net-flow sampling and state calculation.
4. A specialized Mekanism Induction Matrix adapter.
5. A read-only storage telemetry tab.
6. Fallback from the Mekanism adapter to the generic adapter.

Alarm thresholds and automatic power control remain deferred until the
telemetry has been tested against real devices.
