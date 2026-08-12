# HELIOS Control Boundary

## v1.4.0-alpha.8

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
- It spools unloaded to 900 RPM and tests that band under full load first.
- A confirmed climb past 1000 RPM releases the load once more and proceeds to
  the 1800-RPM test.
- Excess speed at 1800 RPM is corrected with bounded steam reductions; the
  learned flow limit is saved with the turbine profile.
- If 1800 RPM is unsustainable, HELIOS keeps full steam while the rotor falls and
  accepts a stable 900-RPM fallback. A rotor that settles between bands is
  deliberately trimmed toward 900 RPM.
- Steam loss, rotor collapse below both bands, or a genuine no-progress stall
  aborts calibration, saves no profile, and raises a global warning.
- Three consecutive samples at or above 2000 RPM confirm overspeed and propose
  a zero flow limit with the inductor engaged.
- Missing, inactive, conflicting, maintenance, or unsupported telemetry produces `HOLD`.
- Rejected, unsupported, or unverifiable writes produce a global control-fault warning.
- Governor state and recommendations are sent to assigned remote terminals.
- Mainframe monitors may navigate the interface by touch.
- Remote terminals remain read-only.

The mainframe also runs a guarded steam-demand governor for one active,
actively cooled reactor:

- Trusted demand is the sum of configured intake limits for all active turbines.
- HELIOS converts all rods to exposed rod-equivalents and uses full rods plus one fractional trim rod.
- A new or non-sequential bank first moves to zero exposure and cools before learning begins.
- A stable measurement provides a proportional estimate; two stable measurements allow interpolation toward the target.
- Formula estimates are bounded to 0.25 rod-equivalent per change and corrected by feedback.
- Steam, hot-fluid-buffer, and casing-temperature motion pauses further changes and invalidates learning samples.
- Learned exposure is saved per reactor only at a stable, unsaturated operating point.
- Every `setControlRodLevel` command is verified by reading that physical rod back.
- An 85% hot-fluid buffer forces rod insertion to reduce backed-up production.
- Zero active turbine demand gradually inserts all rods to 100%.
- Missing or untrusted turbine demand, maintenance, ID conflict, unsupported telemetry, and inactive reactors hold.
- More than one active steam reactor holds until explicit reactor-to-turbine routing is implemented.
- Reactor actuator rejection or read-back mismatch raises a global control fault.
- A reactor that cannot meet demand at 0% insertion, or cannot reduce output at 100%, raises a global steam-capacity warning.

## Prepared settings

- Turbine targets: learned 900- or 1800-RPM band
- Turbine deadband: 25 RPM
- Overspeed threshold: 2000 RPM for 3 readings
- Storage demand band: 25% to 85%
- Maximum reactor exposure step: 0.25 rod-equivalent after 3 matching decisions
- Minimum post-command response wait: 15 seconds, extended while plant telemetry is moving
- Maximum turbine flow step: 100 mB/t
- Adjustment interval: 2 seconds
- First calibration target: 900 RPM
- Escalation threshold: climbing past 1000 RPM for 3 readings
- Second calibration target: 1800 RPM
- Full-steam preflight: 5 readings
- Steam loss during spool: abort after 2 readings
- Stable loaded measurement: 8 readings within 2 RPM/tick
- Minimum valid loaded result: 850 RPM
- No total calibration timeout; no-progress stall timeout: 3 minutes

These defaults are persisted during upgrades but cannot be changed from the
interface until user tuning controls and their validation limits are implemented.

## Next implementation order

1. Validate rod-equivalent learning and fuel use on the live plant
2. Explicit reactor-to-turbine routing for multiple steam loops
3. Storage-based plant demand coordinator
4. Action history and user-defined tuning controls

The mainframe remains the only component allowed to issue hardware commands.
