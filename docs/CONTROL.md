# HELIOS Control Boundary

## v1.4.0-alpha.1

The Power Control screen now runs an observing turbine governor.

- Mode is fixed to `AUTOMATIC`.
- Manual mode and tuning fields are visible but locked.
- `actuatorsEnabled` is fixed to `false`.
- No reactor or turbine write method is called.
- Each turbine is evaluated independently once per telemetry sample.
- The target is 1800 RPM with a 25 RPM deadband.
- Proposed flow-limit changes are capped at 100 mB/t per evaluation.
- Three consecutive samples at or above 2000 RPM confirm overspeed and propose
  a zero flow limit.
- Missing, inactive, conflicting, or unsupported telemetry produces `HOLD`.
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

1. Validate observing turbine decisions against real turbine behavior
2. Add the write adapter and guarded turbine-actuator test
3. Reactor steam-demand governor
4. Storage-based plant demand coordinator
5. Action log and controlled actuator enablement

The mainframe remains the only component allowed to issue hardware commands.
