# HELIOS Control Boundary

## v1.4.0-alpha.2

The Power Control screen now runs a guarded automatic turbine governor.

- Mode is fixed to `AUTOMATIC`.
- Manual mode and tuning fields are visible but locked.
- Turbine actuators are enabled only on the mainframe.
- The only hardware write is Extreme Reactors' `setFluidFlowRateMax`.
- Every write is read back and verified immediately.
- Each turbine is evaluated independently once per telemetry sample.
- The target is 1800 RPM with a 25 RPM deadband.
- Normal direction changes require two matching samples.
- Flow-limit changes are capped at 100 mB/t every two seconds.
- Three consecutive samples at or above 2000 RPM confirm overspeed and propose
  a zero flow limit.
- Missing, inactive, conflicting, maintenance, or unsupported telemetry produces `HOLD`.
- Rejected, unsupported, or unverifiable writes produce a global control-fault warning.
- Governor state and recommendations are sent to assigned remote terminals.
- Mainframe monitors may navigate the interface by touch.
- Remote terminals remain read-only.

## Prepared settings

- Turbine target: 1800 RPM
- Turbine deadband: 25 RPM
- Overspeed threshold: 2000 RPM for 3 readings
- Storage demand band: 25% to 85%
- Maximum reactor rod step: 5%
- Maximum turbine flow step: 100 mB/t
- Adjustment interval: 2 seconds

These defaults are persisted during upgrades but cannot be changed from the
interface until the automatic governors and safety interlocks are implemented.

## Next implementation order

1. Validate guarded automatic turbine control against real turbine behavior
2. Reactor steam-demand governor
3. Storage-based plant demand coordinator
4. Action history and user-defined tuning controls

The mainframe remains the only component allowed to issue hardware commands.
