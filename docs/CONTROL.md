# HELIOS Control Boundary

## Current alpha

The Power Control screen is an interface and configuration scaffold only.

- Mode is fixed to `AUTOMATIC`.
- Manual mode and tuning fields are visible but locked.
- `actuatorsEnabled` is fixed to `false`.
- No reactor or turbine write method is called.
- Mainframe monitors may navigate the interface by touch.
- Remote terminals remain read-only.

## Prepared settings

- Turbine target: 1800 RPM
- Storage demand band: 25% to 85%
- Maximum reactor rod step: 5%
- Maximum turbine flow step: 100 mB/t
- Adjustment interval: 2 seconds

These defaults are persisted during upgrades but cannot be changed from the
interface until the automatic governors and safety interlocks are implemented.

## Next implementation order

1. Turbine governor and overspeed interlock
2. Reactor steam-demand governor
3. Storage-based plant demand coordinator
4. Action log and safe telemetry-loss hold
5. Controlled actuator enablement for testing

The mainframe remains the only component allowed to issue hardware commands.
