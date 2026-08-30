# Public Alpha testing guide

## Before testing

1. Back up the ComputerCraft computer directory or test on a fresh computer.
2. Record the CC:Tweaked computer ID and attached peripheral names.
3. Keep an independent manual shutdown available for powered equipment.
4. Test the Probe before proposing support for unknown hardware.

## Suggested test order

1. Run `discovery_probe.lua` and save its complete output.
2. Install HELIOS as a Mainframe or Remote.
3. Confirm restart/resume behavior before connecting live demand.
4. Confirm telemetry remains current while navigating every screen.
5. Test ordinary controls, then disconnect/reconnect modems and peripherals.
6. Test safety behavior only under controlled conditions.

The standalone Draconic Guardian has a validated live baseline. Public Alpha
testing should look for reproducibility and integration issues; avoid changing
its control constants or wiring assumptions during an unrelated test.

## Defect report

Include:

- HELIOS/Core version and Git branch or commit;
- Mainframe, Remote, Probe, Guardian, or module-template context;
- Minecraft/modpack and CC:Tweaked versions;
- computer ID and `peripheral.getNames()` results;
- exact steps, expected result, actual result, and exact error;
- whether restart reproduces it;
- screenshots plus Probe output when hardware discovery is involved.

Never publish world files, server addresses, passwords, tokens, or private
network information with a report.
