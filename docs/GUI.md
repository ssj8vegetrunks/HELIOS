# HELIOS Graphical Monitor v1

The first graphical interface is a read-only plant overview built on
`helios.ui` contract version 1. It is the default mainframe display in
`v1.6.0-alpha.5`. Remote terminals use the same graphical overview and facility
pages with their configured reactor/turbine/storage/all snapshot assignment.

## Navigation

`HOME`, `REACTORS`, `TURBINES`, and `POWER` remain visible on every graphical
page. `ADVANCED` opens the complete text interface. Keyboard equivalents remain
available: `V` for reactors, `G` for turbines, `E` for power, and `A` for the
Advanced text interface.

On a remote terminal, Advanced remains read-only and preserves local alarm
silence and speaker testing. `B` returns from Advanced to the graphical display.

## Overview

The overview reports `READY`, `STARTING`, `CALIBRATING`, `WARNING`, or `FAULT`,
with the current startup, governor, identity-conflict, or alarm reason. It also
shows equipment counts and minimum trusted storage reserve.

## Facility pages

- Reactors show type, active state, output and fuel bars, cyanite amount in cyan,
  and the relevant steam/energy buffer percentage.
- Turbines show a five-zone RPM gauge with labels centered below the green
  `[900 RPM]` and `[1800 RPM]` bands, plus governor state and power output.
- Power shows storage capacity percentage, stored energy, fill rate, draw rate,
  and charging/draining state.

Left/right keys and the on-screen Previous/Next row select another device in
the current category.

## Authority boundary

The graphical interface contains no manual-control actions. Reactor rods,
reactor/turbine power state, turbine flow, authority changes, calibration
commands, and configuration remain inside the Advanced text interface. The GUI
does not receive hardware handles and cannot call adapters.

## Control Room GUI module v1

`control-room` is the first selectable GUI module. It requires at least `50x31`
characters, corresponding to a large 4x3 monitor at text scale 0.5. HOME presents
combined storage, steam production versus demand, total plant generation, and
net storage flow. Its activity panel lists live governor states and reasons.
Device tabs retain raw telemetry, while ADVANCED opens the established text-only
configuration and manual-control interface.

Custom large-screen rendering is independent from the computer terminal. The
terminal always retains the compact built-in GUI and mouse controls while a
qualifying attached monitor displays Control Room with monitor-touch controls.
Advanced is rendered through the compact mirrored interface. If the custom
renderer fails or the monitor becomes too small, the built-in GUI resumes on
the monitor as well.

The steam instrument scales to the combined learned maximum output of all steam
reactors. Its fill and numeric readout show actual production, while the yellow
marker shows current turbine demand against that capability. HELIOS derives and
persists maximum capability from trusted calibration response; until every steam
reactor has a learned maximum, the readout reports `LEARNING`.
