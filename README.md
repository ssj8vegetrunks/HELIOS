# HELIOS — v1.3.0 Alpha 2 Control Interface and Touch

Industrial power management for **CC:Tweaked** and **Extreme Reactors**.

This milestone prepares HELIOS for automatic regulation without enabling any
actuators yet. It also brings monitor touch and network-ID conflict detection
online:

- the active HELIOS page is mirrored to every attached CC:Tweaked monitor;
- mainframe monitors provide touch navigation, device selection, rescan, settings access, and alarm silence;
- remote-terminal monitors provide read-only telemetry navigation, local alarm silence, and speaker testing;
- monitors may be attached or detached while HELIOS is running;
- the same display layer works on both mainframes and remote-terminal roles;
- monitor text scale defaults to `0.5` to fit the terminal layout;
- compact power notation now includes `Qa` and `Qi`.
- remote terminals automatically discover and remember their HELIOS mainframe;
- the mainframe remembers terminal IDs and reactor/turbine/battery/all assignments;
- one-second sanitized snapshots provide telemetry and heartbeats;
- lost links retain the last readings and clearly mark them stale;
- alarms appear and sound on the mainframe and assigned remote terminals;
- mainframe silence applies network-wide, while remote silence is local only;
- alarm settings include enable/disable, thresholds, volume, and a speaker test.
- duplicate CC:Tweaked computer IDs are detected from independent HELIOS sessions;
- every HELIOS screen receives a red conflict banner listing all duplicated IDs;
- conflicting directed telemetry is treated as unsafe until the IDs become unique;
- a persistent Power Control screen exposes the planned automatic/manual and tuning layout;
- `AUTOMATIC` is fixed on, while manual mode, tuning controls, and every actuator remain locked.
- settings and telemetry navigation use stable touch targets that fit the mirrored terminal canvas;
- upgrades remove obsolete HELIOS rollback copies before staging and retain only the immediately replaced version.

The existing telemetry foundation includes:

- one installer for both machine roles;
- persistent `mainframe` or `terminal` configuration;
- terminal assignments for `reactor`, `turbine`, `battery`, or `all`;
- one role-aware launcher;
- automatic startup without silently discarding an existing startup program;
- placeholder status interfaces defining the authority boundary.
- configurable automatic or manual hardware discovery;
- temporary manual maintenance mode with an automatic timeout;
- classification of reactors, turbines, batteries, monitors, modems, and unknown devices;
- a persistent local registry containing reported peripheral names, types, and methods;
- a read-only discovery screen with no device-control commands;
- independent power/steam mode detection for every reactor;
- live fuel, temperature, production, buffer, coolant, and hot-fluid readings when exposed by the installed reactor API;
- fuel and telemetry-loss alarms through attached CC:Tweaked speakers;
- a clickable current-alarm silence button that does not mute future alarms;
- preservation of existing discovery and alarm settings during upgrades.
- strict reactor/turbine separation even when their methods overlap;
- live turbine state, rotor speed, production, buffer, flow, tank, inductor, and vent readings when exposed;
- persistent custom names for discovered devices;
- optional raw peripheral names for troubleshooting;
- FE, RF, Joule, or EU display with editable conversion ratios;
- compact `k`, `M`, `B`, `T`, `Qa`, and `Qi` notation or full-number formatting.
- a universal read-only energy-storage tab;
- generic stored-energy and capacity detection for unfamiliar devices;
- sampled net flow when separate input/output telemetry is unavailable;
- charging, draining, stable, full, and empty state calculation;
- estimated time until full or empty;
- specialized Mekanism Induction Matrix input, output, transfer, cell, and provider telemetry;
- automatic fallback from the specialized Mekanism driver to the generic driver.

## Install in CC:Tweaked

Copy the installer onto the computer, then run it, or use the GitHub `wget run`
command supplied with the release.

```text
wget run https://raw.githubusercontent.com/ssj8vegetrunks/HELIOS/main/install.lua
```

After installation:

```text
helios
helios status
helios scan
helios reactors
helios turbines
helios storage
```

The installed layout is:

```text
/helios.lua
/helios/
  config.lua
  helios.lua
  core/
    config.lua
    display.lua
    network.lua
    power_format.lua
    ui.lua
  mainframe/
    device_registry.lua
    reactor_adapter.lua
    turbine_adapter.lua
    storage_adapter.lua
    main.lua
  terminal/
    main.lua
/startup/99-helios.lua
```

If `/startup` is already a program, the installer asks permission before
converting it into a startup directory. The original is preserved as
`/startup/00-user.lua`.

## Hardware discovery

On a mainframe, HELIOS always scans once at startup. By default it then rescans
only when CC:Tweaked reports a peripheral attachment or detachment. Press `R`
to scan manually, or `S` to open Discovery Settings. Run
`helios scan` for the full report, including the raw network name and types of
every device. The complete registry is stored at `/helios/data/devices.lua`.

Discovery Settings can permanently select `AUTOMATIC` or `MANUAL`. They can
also begin a temporary manual maintenance session. Hardware changes during
manual operation mark the registry as outdated without scanning. Ending
maintenance, reaching its timeout, or restarting HELIOS performs a clean scan;
the saved default is then restored. The default timeout is 30 minutes.

Use the left and right arrow keys to change the maintenance timeout. The old
`T` shortcut was removed because it conflicts with ATM10's inventory trash
overlay. While maintenance is active, the on-screen countdown refreshes once
per second without rescanning attached hardware.

## Reactor monitoring

Press `V` on the mainframe dashboard to open live reactor telemetry. Use the
left and right arrow keys to move between connected reactors. HELIOS reads
telemetry once per second without rescanning the peripheral network.

Fuel alarms require three consecutive low readings. The default advisory
threshold is 20% and the critical threshold is 5%. Clicking
`[ SILENCE ALARM ]` silences only the current condition. A different or more
severe alarm can still sound, and silence resets after the condition clears.

The adapter is deliberately tolerant of several Extreme Reactors API naming
variants. Unsupported measurements display `N/A` rather than stopping HELIOS.

## Turbine monitoring

Press `G` on the mainframe dashboard to open live turbine telemetry. `T` is
intentionally unused because ATM10 binds it to the inventory trash overlay.
Use the left and right arrow keys to move between connected turbines.

The turbine adapter is read-only. Unsupported values display `N/A`, allowing
ATM10 to show whichever measurements its Extreme Reactors build provides.

## Names and power display

Open `S` Settings, then `N` to assign or clear persistent device names. The
main screen and telemetry tabs show custom names when present. `H` toggles raw
peripheral names for troubleshooting; it defaults to hidden.

Open `P` Power Display to select FE, RF, J, or EU; compact or full values; one
or two compact decimal places; and the conversion ratio from the native FE
reading. FE and RF default to 1:1. Because modpacks can alter Joule and EU
conversion, their ratios are editable.

## Universal energy storage

Press `E` on the mainframe dashboard to open energy-storage telemetry. Use the
left and right arrow keys to move between supported storage devices. HELIOS
prefers a specialized adapter, falls back to the generic driver, and otherwise
leaves the peripheral unclaimed.

The generic driver requires recognizable stored-energy and capacity methods.
It samples stored energy once per second to calculate net flow when the device
does not report input and output separately. The Mekanism driver reads the
Induction Matrix through an attached Induction Port and adds accurate input,
output, maximum transfer, installed cell, and provider readings.

Mekanism reports native Joules. HELIOS converts them to its internal FE baseline
using the editable Joule ratio before applying the selected global display unit.

See [`docs/UNIVERSAL-ENERGY-STORAGE.md`](docs/UNIVERSAL-ENERGY-STORAGE.md) for the concise
architecture and first implementation target.

## Monitor output and touch

Attach one or more CC:Tweaked monitors directly or through the mainframe's
wired peripheral network. HELIOS automatically mirrors the currently active
screen to all of them. Touch the labelled buttons on a mainframe monitor to
navigate operating pages, select devices, rescan, open settings/control, or
silence the current alarm.

A monitor driven by a remote terminal remains read-only. Its touch buttons may
change the locally displayed device, test its speaker, or silence its local
speaker, but cannot change mainframe settings or call power hardware.

The display uses text scale `0.5`. A monitor must be physically large enough to
show the computer-sized layout; content outside a smaller monitor is safely
clipped.

## Remote terminals

Install HELIOS as a Remote Terminal and choose `reactor`, `turbine`, `battery`,
or `all`. A modem is required on both computers. The terminal broadcasts a
read-only HELIOS hello, binds to the first HELIOS mainframe that answers, and
stores that mainframe ID. The mainframe remembers the terminal ID and assignment.
Run `helios unpair` on a remote if it must discover a different mainframe.

The terminal never calls power-system peripherals. It receives only normalized
display snapshots. If five seconds pass without a snapshot, the terminal shows
`LINK LOST - DATA STALE` and retains the last known values instead of replacing
them with zeroes.

## Alarms

Open `S` Settings, then `A` Alarm Settings. `X` plays a test sound; `T` remains
unused. The first confirmed rules cover low/critical reactor fuel and reactor,
turbine, or storage telemetry loss. Conditions must persist for three readings.

Silencing at the mainframe stops the current alarm on every terminal. A remote
terminal can press `S` to silence only its local speaker. Warnings remain visible,
new conditions can sound, and silence resets after the condition clears.
Press `X` on either computer's alarm interface to test its locally attached speaker.

## Power control interface

Press `C` or touch `[CONTROL]` on the mainframe dashboard. The screen contains
the future control mode, turbine RPM target, storage demand band, rod/flow step
limits, and adjustment interval. For this alpha, `AUTOMATIC` is selected but
all tuning fields and actuator calls are deliberately locked. This is an
interface and authority test only; HELIOS still cannot move rods, change flow,
toggle a reactor, or engage a turbine.

See [`docs/CONTROL.md`](docs/CONTROL.md) for the concise control boundary and
planned governor order.

## Network ID conflicts

Each running HELIOS computer advertises a unique session identity in addition
to its CC:Tweaked computer ID. If two sessions claim the same computer ID, the
mainframe broadcasts the complete conflict list and every HELIOS terminal and
monitor displays a red warning banner. The warning clears automatically after
the duplicate disappears. Replace or reset the duplicated computer before
trusting directed telemetry.

## Scope boundary

Discovery, remote telemetry, and power hardware remain read-only. The control
interface is present, but reactor/turbine governor logic and actuator calls are
disabled. Graphs and additional specialized storage adapters come later.
