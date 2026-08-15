# HELIOS Reactor Lab 0.1-test

Test-only branch build for isolating Extreme Reactors steam-reactor calibration
from the rest of HELIOS. It is not part of the normal HELIOS release or PR.

## Included

- Automatic discovery of attached reactors
- Current mirrored/touch mainframe display
- Steam-reactor telemetry
- Verified reactor activation and individual control-rod writes
- Independent target and learned profile for each reactor
- Fresh recalibration and save-current controls
- Rolling-average and response-progress diagnostics
- Change-only local log at `/helios-reactor-lab/reactor-lab.log`
- Installed version in the upper-right corner

## Excluded

- Turbines
- Energy storage
- Remote terminals and networking
- Plant-wide demand coordination
- Construction, moderator, fuel, or size input

## Safety behaviour

The lab always starts in `HOLD — NO WRITES`. Select a steam reactor and press
`START FRESH CALIBRATION` or `ENABLE AUTOMATIC TEST` before it may operate the
reactor. `EMERGENCY HOLD` immediately prevents further actuator writes. Power
reactors remain monitor-only.

Each detected reactor defaults to a 2,000 mB/t target. The target may be changed
in 100 mB/t steps and is saved independently for that reactor.

## Installation

Run the generated `helios-reactor-lab-installer.lua` on a dedicated CC:Tweaked
computer, then run:

```text
reactorlab
```

This installer does not modify `/helios` or the normal HELIOS installation.
