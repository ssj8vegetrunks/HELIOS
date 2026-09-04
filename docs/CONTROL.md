# HELIOS Control Boundary

## Draconic lifecycle governor

The Draconic Guardian treats its commissioned export as a conservative baseline,
not a permanent maximum. While Assisted MAX is selected it proves higher export
points in five-percent fuel-conversion bands and independently trims field input
toward stable containment. A point is retained only after a thirty-second stable
observation window.

Historical late-cycle settings are never applied to a fresh core. A detected
drop in fuel conversion clears current-cycle proofs, returns both gates to the
commissioned baseline, and requires the new cycle to prove its path forward.
Stored profiles guide later bands but never bypass live safety interlocks.

## Guarded manual authority (1.6 alpha)

- Manual authority requires separate ARM and CONFIRM actions.
- Entering manual authority pauses the reactor and turbine governors; telemetry,
  alarms, ID-conflict protection, and storage-reserve monitoring remain active.
- Reactor controls provide verified on/off commands, uniform all-rod changes, and
  paginated individual-rod insertion changes in selectable 1%, 5%, or 10% steps.
- Rod pages show six fuel columns at a time and therefore scale to reactors with
  100 or more rods without changing monitor size.
- If any trusted storage device falls below the configured 2% reserve, HELIOS
  immediately returns to automatic authority, safely resets steam reactors, and
  starts fresh reactor and turbine calibration.
- Manual authority never survives a HELIOS reboot.

## Automatic governor baseline (v1.4.0-alpha.19)

The Power Control screen now runs a guarded automatic turbine governor.

- In that baseline, mode was fixed to `AUTOMATIC` and manual fields were locked.
- Turbine actuators are enabled only on the mainframe.
- Hardware writes are limited to Extreme Reactors' verified flow-limit and
  inductor controls.
- Every write is read back and verified immediately.
- Each turbine is evaluated independently once per telemetry sample.
- Each turbine learns and persists its own 900- or 1800-RPM operating band.
- Normal direction changes require two matching samples.
- Flow-limit changes are capped at 100 mB/t every two seconds.
- When a managed steam reactor and compatible buffer telemetry are present,
  HELIOS keeps turbine intake open and temporarily targets 90% extra reactor
  output until both reactor and turbine steam buffers reach 85%.
- Once both buffers are primed, HELIOS returns the reactor to its normal 15%
  reserve, verifies sustained steam, and starts the RPM tests. Older peripherals
  without buffer-capacity telemetry retain the full-steam preflight fallback.
- During priming, stable steam and buffer telemetry may advance reactor output
  while slow casing-temperature drift remains diagnostic only.
- Turbines with saved profiles also perform one priming cycle when HELIOS starts
  and after reactor recalibration, then return to their learned flow. Priming is
  not repeatedly triggered during ordinary operation.
- Waiting for the reactor never consumes turbine calibration-failure samples.
- Calibration then verifies full steam with the inductor engaged.
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
- A newly discovered inactive turbine receives one verified automatic startup
  command so a factory-default plant can enter calibration. Missing, conflicting,
  maintenance, or unsupported telemetry still produces `HOLD`.
- Rejected, unsupported, or unverifiable writes produce a global control-fault warning.
- Governor state and recommendations are sent to assigned remote terminals.
- Mainframe monitors may navigate the interface by touch.
- Remote terminals remain read-only.

The mainframe runs a guarded reactor-fleet governor:

- Trusted demand is the sum of requested intake for dispatched turbines, plus
  any limited assisted-idle pulse currently needed to preserve warm reserve.
- Active steam production targets 15% above trusted turbine demand so reactor,
  pipe, reservoir, and turbine buffers stay charged. Full-buffer overflow is
  exhausted by the loop rather than causing HELIOS to cancel that reserve.
- An uncalibrated turbine requests its hard intake limit so the reactor is
  prepared before turbine calibration begins.
- Trusted turbine demand starts an offline steam reactor through verified
  `setActive(true)` control and read-back.
- Newly discovered reactors are commissioned one at a time. Steam reactors
  learn against an independent test target even without turbine demand; power
  reactors record observed FE/t capability.
- Calibrated power reactors recharge against the combined, capacity-weighted
  external storage reserve. They start below the low threshold (or on startup
  when below the high threshold), charge to the high threshold, then remain in
  standby until reserve falls below the low threshold again. Full storage also
  pauses unfinished power-reactor commissioning.
- Steam demand is assigned across calibrated steam reactors by learned capacity.
- A plant dispatcher first decides whether storage requires recharge. It stages
  only enough learned generation capacity for the measured draw, preferring
  steam-assisted idle turbines, then already-warm equipment, before cold
  turbines. Undispatched turbines coast with steam closed and inductors
  disengaged.
- Each calibrated turbine has a persistent **Steam-assisted idle** option.
  Enabled turbines remain as warm reserve: HELIOS sends a limited steam pulse
  only after rotor speed falls below its standby floor; disabled turbines simply
  coast until a large demand selects them for unloaded spooling.
- HELIOS spreads each rod-equivalent setting across all fuel columns as evenly as possible.
- A 25-rod setting of 0.26 equivalent becomes one rod at 98% insertion and 24 at 99%.
- A new or unbalanced bank first moves to zero exposure and cools before learning begins.
- A zero-exposure baseline is ready once its rolling steam output is negligible,
  its hot-fluid buffer is drained, and casing temperature is below 150 C. The
  casing does not need to reach ambient temperature or stop changing completely.
- Steam decisions use a 10-sample rolling average and target 2.5% above turbine demand.
- A stable measurement provides a proportional estimate; two stable measurements allow interpolation toward the target.
- Formula estimates are bounded to 0.25 rod-equivalent per change and corrected by feedback.
- Ordinary regulation waits for steam, hot-fluid-buffer, and casing-temperature
  response. During explicit recalibration, a completed rolling steam window and
  stable hot-fluid response may advance one bounded step even while a massive
  casing continues drifting thermally.
- Learned exposure is saved per reactor only at a stable, unsaturated operating point.
- A rod layout changed outside HELIOS invalidates the old rolling average; automatic mode restores the learned exposure once fresh samples confirm turbine starvation.
- Maintenance mode suppresses this recovery so deliberate manual rod settings remain untouched.
- The reactor page opens a dedicated calibration-status screen. Entering it offers to enable Maintenance Mode so HELIOS cannot move rods while settings are reviewed.
- The calibration screen shows current and saved exposure, current and target steam, governor state, and the last calibration time.
- `DELETE CALIBRATION DATA` removes only the selected steam reactor's saved profile and does not immediately move its rods.
- `RECALIBRATE` clears the active profile, returns HELIOS to automatic control, inserts every rod, and learns again from zero exposure.
- Recalibration advances through a forward-only `BASELINE` -> `TESTING` ->
  `ADJUSTING` sequence. Rod movement and fresh sample windows cannot send an
  active calibration back to `BASELINE`; only a new `RECALIBRATE` command can.
- The calibration page reports phase, governor state, steam-average samples,
  and process-response samples so a genuine hold is visible immediately.
- `SAVE CURRENT REACTOR SETUP` records the selected reactor's actual balanced rod layout and live steam target as its learned profile.
- Closing the screen offers to disable Maintenance Mode when that screen enabled it. Power reactors report that calibration is not required and expose no calibration actions.
- Every `setControlRodLevel` command is verified by reading that physical rod back.
- The 85% hot-fluid level primes turbine calibration; it does not reduce active
  reserve output after the loop is stable.
- Zero active turbine demand gradually inserts all rods to 100%.
- Missing or untrusted turbine demand, maintenance, ID conflict, and unsupported telemetry hold.
- Multiple steam reactors report aggregate readiness while each retains its
  own assigned demand and learned-capacity display.
- Reactor actuator rejection or read-back mismatch raises a global control fault.
- A reactor that cannot meet demand at 0% insertion, or cannot reduce output at 100%, raises a global steam-capacity warning.

## Prepared settings

- Turbine targets: learned 900- or 1800-RPM band
- Turbine deadband: 25 RPM
- Overspeed threshold: 2000 RPM for 3 readings
- Storage demand band: 25% to 85%
- Maximum reactor exposure step: 0.25 rod-equivalent after 3 matching decisions
- Reactor fine-control resolution: 0.01 rod-equivalent
- Steam reserve margin: 15%
- Temporary steam-buffer priming margin: 90%
- Steam rolling average: 10 one-second samples
- Minimum post-command response wait: 15 seconds, extended while plant telemetry is moving
- Maximum casing temperature for a fresh calibration baseline: 150 C
- Maximum turbine flow step: 100 mB/t
- Adjustment interval: 2 seconds
- First calibration target: 900 RPM
- Escalation threshold: climbing past 1000 RPM for 3 readings
- Second calibration target: 1800 RPM
- Full-steam preflight: 5 readings
- Steam-buffer priming threshold: 85%
- Steam loss during spool: abort after 2 readings
- Stable loaded measurement: 8 readings within 2 RPM/tick
- Minimum valid loaded result: 850 RPM
- No total calibration timeout; no-progress stall timeout: 3 minutes

These defaults are persisted during upgrades but cannot be changed from the
interface until user tuning controls and their validation limits are implemented.

## Next implementation order

1. Validate coordinated factory-default startup on the live plant
2. Explicit reactor-to-turbine routing for multiple steam loops
3. Storage-based plant demand coordinator
4. Action history and user-defined tuning controls

The mainframe remains the only component allowed to issue hardware commands.
