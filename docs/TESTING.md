# Public Alpha testing guide

## Modular installation checks

For each role, start from a fresh CC:Tweaked computer and run the bootstrap. Confirm that
`helios status` reports the selected role and that unrelated role directories are absent:

- Mainframe: `/helios/mainframe` and `/helios/modules` exist; `/helios/terminal` and
  `/helios/draconic` do not.
- Remote Terminal: `/helios/terminal` exists; Mainframe hardware modules and Draconic role files do
  not.
- Draconic Guardian: `/helios/draconic/controller.lua` exists; Mainframe and Terminal files do not.
- Draconic Profiler: only the profiler files exist under `/helios/draconic`.

Repeat a Mainframe upgrade from Alpha 26 with little free space. Configuration, calibration,
facility data, custom names, installed languages, and `/helios/data` must survive. Deselecting
Event Viewer, the Control Room GUI, or the discovery probe must leave those optional program files
absent while normal control and the dependable built-in interface continue operating.

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
