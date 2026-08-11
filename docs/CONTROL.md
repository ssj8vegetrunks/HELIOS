# HELIOS Control Boundary

## v1.4.0-alpha.4

The Power Control screen now runs a guarded automatic turbine governor.

- Mode is fixed to `AUTOMATIC`.
- Manual mode and tuning fields are visible but locked.
- Turbine actuators are enabled only on the mainframe.
- Hardware writes are limited to Extreme Reactors' verified flow-limit and
  inductor controls.
- Every write is read back and verified immediately.
- Each turbine is evaluated independently once per telemetry sample.
- Each turbine learns and persists its own 900- or 1800-RPM operating band.
- Normal direction changes require two matching samples.
- Flow-limit changes are capped at 100 mB/t every two seconds.
- Calibration first verifies full steam with the inductor engaged.
- It then spools unloaded to 1800 RPM, engages the inductor once, measures the
  stable loaded RPM, and saves the nearest valid 900/1800-RPM band.
- Once engaged, the inductor stays latched; normal RPM sag never restarts spool-up.
- Steam loss, rotor collapse, a loaded result below 850 RPM, or timeout aborts
  calibration, saves no profile, and raises a global warning.
- Three consecutive samples at or above 2000 RPM confirm overspeed and propose
  a zero flow limit with the inductor engaged.
- Missing, inactive, conflicting, maintenance, or unsupported telemetry produces `HOLD`.
- Rejected, unsupported, or unverifiable writes produce a global control-fault warning.
- Governor state and recommendations are sent to assigned remote terminals.
- Mainframe monitors may navigate the interface by touch.
- Remote terminals remain read-only.

## Prepared settings

- Turbine targets: learned 900- or 1800-RPM band
- Turbine deadband: 25 RPM
- Overspeed threshold: 2000 RPM for 3 readings
- Storage demand band: 25% to 85%
- Maximum reactor rod step: 5%
- Maximum turbine flow step: 100 mB/t
- Adjustment interval: 2 seconds
- Calibration spool target: 1800 RPM
- Full-steam preflight: 5 readings
- Steam loss during spool: abort after 2 readings
- Stable loaded measurement: 8 readings within 2 RPM/tick
- Minimum valid loaded result: 850 RPM
- Calibration timeout: 10 minutes

These defaults are persisted during upgrades but cannot be changed from the
interface until the automatic governors and safety interlocks are implemented.

## Next implementation order

1. Validate automatic turbine spool-up and steady-state behavior
2. Reactor steam-demand governor
3. Storage-based plant demand coordinator
4. Action history and user-defined tuning controls

The mainframe remains the only component allowed to issue hardware commands.
