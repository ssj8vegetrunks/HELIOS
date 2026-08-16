# HELIOS - v1.4.0 Alpha 19 Live Reactor Calibration Progress

Industrial power management for **CC:Tweaked** and **Extreme Reactors**.

This milestone adds guarded reactor steam regulation to the automatic turbine
governor. HELIOS now matches one steam reactor to the trusted intake
requested by its active turbines, reducing fuel waste without starving them.
The existing touch interface and network-ID protection remain online:

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
- `AUTOMATIC` is fixed on, while manual mode and tuning controls remain locked.
- every turbine learns and persists its own 900- or 1800-RPM operating band;
- governor states, proposed changes, and actuator results appear on mainframe and remote turbine screens;
- the governor holds on missing, conflicting, inactive, or unsupported telemetry;
- normal changes require two matching readings, are limited to 100 mB/t every two seconds, and are verified by read-back;
- calibration proves full steam and tests the 900-RPM band first;
- turbines that overpower 900 RPM are unloaded again and tested at 1800 RPM;
- 1800-RPM turbines trim steam in bounded steps and save both their learned band
  and flow limit;
- a turbine that cannot sustain 1800 RPM may settle back to a valid 900-RPM
  profile without a fixed total timeout;
- the inductor only changes at deliberate calibration transitions, eliminating
  repeated clutch cycling;
- invalid steam supply, rotor collapse below both bands, or a genuine no-progress
  stall aborts calibration and raises a warning without saving a profile;
- three consecutive readings confirm overspeed before an immediate zero-flow command;
- confirmed turbine overspeed becomes a system-wide critical alarm;
- rejected or unverifiable actuator commands become system-wide control-fault warnings;
- the dashboard reports live automatic, calibration, maintenance, and fault state instead of the obsolete observe-only banner;
- one steam reactor follows the summed configured intake of all active turbines;
- managed turbine calibration waits for its steam reactor to start and supply
  the full intake instead of failing while reactor output is still rising;
- an offline steam reactor is started through verified activation control when
  active turbine demand exists;
- power-mode reactors remain telemetry-only and never enter steam alarms or control;
- reactor exposure is spread as evenly as possible across every fuel column;
- one-percent insertion differences provide 0.01 rod-equivalent fine control;
- steam control uses a rolling average and a 2.5% reserve above turbine demand;
- a new or unbalanced rod bank is first fully inserted to establish a known-safe baseline;
- calibration begins once residual steam is negligible, the hot-fluid buffer is
  drained, and casing temperature is below 150 C; it does not wait for a massive
  casing to reach ambient temperature or become perfectly motionless;
- recalibration records explicit baseline, testing, and adjusting phases so a
  positive test exposure cannot restart the zero-exposure baseline loop;
- once a recalibration test has a full rolling steam window and stable fluid
  response, slow casing-temperature drift cannot hold that bounded step forever;
- formula-assisted learning estimates the needed exposure, then bounded feedback corrects it;
- ordinary reactor commands still wait for full plant response; recalibration
  may ignore casing drift only after steam and hot-fluid response have settled;
- stable learned exposure is saved per reactor and every individual rod command is verified;
- external rod changes clear stale steam samples and automatically restore the learned exposure when turbine supply falls short;
- high hot-fluid buffer pressure and zero turbine demand insert rods to reduce fuel use;
- missing turbine demand, duplicate IDs, maintenance, unsupported rod telemetry, and ambiguous multiple-reactor routing hold reactor output unchanged;
- settings and telemetry navigation use stable touch targets that fit the mirrored terminal canvas;
- every mainframe and remote screen shows that computer's locally installed
  HELIOS version in the upper-right corner;
- reactor calibration shows its explicit phase plus rolling-steam and
  process-response sample progress instead of ambiguous fallback labels;
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
    reactor_governor.lua
    turbine_adapter.lua
    turbine_governor.lua
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

## Reactor monitoring and steam control

Press `V` on the mainframe dashboard to open live reactor telemetry. Use the
left and right arrow keys to move between connected reactors. HELIOS reads
telemetry once per second without rescanning the peripheral network.

Fuel alarms require three consecutive low readings. The default advisory
threshold is 20% and the critical threshold is 5%. Clicking
`[ SILENCE ALARM ]` silences only the current condition. A different or more
severe alarm can still sound, and silence resets after the condition clears.

For one steam reactor, HELIOS totals the configured intake requested by
all active turbines and regulates exposed rod-equivalents until reactor steam
production matches that demand plus a 15% reserve. Total exposure is spread
across every fuel column as evenly as integer insertion levels allow. For
example, 0.26 equivalent on 25 rods becomes one rod at 98% insertion and 24 at
99%. A rolling steam average filters the reactor's fuel-column cycle before
stable measurements feed the proportional/interpolated learner. Live feedback
still corrects for temperature, fuel, moderator layout, and other nonlinear
effects. Each individual rod write is read back and verified.

For an uncalibrated turbine, the reactor target is based on the turbine's hard
intake limit. HELIOS starts an offline steam reactor and keeps the turbine
intake open while temporarily targeting 90% extra reactor output. Once both
steam buffers reach the 85% safety threshold, the reactor returns to its normal
15% reserve and turbine calibration begins at full flow.
Peripherals without readable buffer capacity retain the full-steam preflight
fallback. A power-mode reactor is never considered a steam source.

The reactor governor holds during maintenance, ID conflict, missing or
untrusted turbine telemetry, unsupported rod control, or when more than one
steam reactor is active. Multiple reactor loops need explicit routing before
HELIOS will control them.

The adapter is deliberately tolerant of several Extreme Reactors API naming
variants. Unsupported measurements display `N/A` rather than stopping HELIOS.

## Turbine monitoring

Press `G` on the mainframe dashboard to open live turbine telemetry. `T` is
intentionally unused because ATM10 binds it to the inventory trash overlay.
Use the left and right arrow keys to move between connected turbines.

The turbine adapter distinguishes actual steam consumed,
the configured intake limit, and the turbine's hard intake limit. Unsupported
values display `N/A`. In automatic mode, the mainframe uses Extreme Reactors'
official `setFluidFlowRateMax` method and verifies the resulting setting after
every command. Remote terminals remain read-only.

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

## Automatic plant governors

Press `C` or touch `[CONTROL]` on the mainframe dashboard. The screen shows each
turbine's live governor state, target RPM, current flow-limit setting, proposed
setting, and action. Use Previous/Next to inspect turbines independently.

An uncalibrated turbine first proves that its full advertised steam rate is
available. HELIOS spools it unloaded to 900 RPM and tests that band under load.
Only a turbine that continues climbing past 1000 RPM proceeds to the 1800-RPM
test. At 1800 RPM HELIOS trims excess steam, or lets an unsustainable high-band
test settle back toward 900 while maintaining full steam. It saves the valid band
and learned flow limit. Steam loss, rotor collapse below both bands, or a genuine
no-progress stall raises `CALIBRATION FAILED` and saves nothing. Three confirmed
overspeed readings engage the inductor, cut steam, and raise a global alarm.
Missing or untrusted telemetry always produces HOLD.

`AUTOMATIC` remains selected and tuning controls remain locked. HELIOS may
change a turbine's configured flow limit and inductor state, plus the individual
control-rod insertion and active state of one steam reactor. It still cannot
control a power-mode reactor, start or stop a turbine, change venting, eject
fuel, or eject waste.

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

Remote terminals remain read-only. The mainframe may control only turbine flow
limits, turbine inductors, and the verified active state and individual rods of
one steam reactor. Multi-reactor routing, storage coordination, graphs, and
additional specialized storage adapters come later.
