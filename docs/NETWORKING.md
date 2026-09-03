# HELIOS networking contracts

HELIOS uses separate versioned contracts for different trust boundaries. They
may share a modem, but they must not share message semantics.

## Existing terminal network

`helios.v1` connects a HELIOS Mainframe to read-only Remote terminals. It
provides discovery, assignments, telemetry snapshots, alarms, and duplicate-ID
protection. It remains unchanged during facility-network development.

## Facility network Alpha 1

`helios.facility.v1` is the Guardian/facility discovery and telemetry contract.
It deliberately has no general remote-control message. Its only command is the
narrowly scoped, operator-triggered emergency SCRAM request.

Supported traffic:

- `hello` — node identity, facility type, software version, capabilities, and
  optional GUI-profile offer;
- `collector_presence` — a small broadcast announcing the active telemetry
  collector, its priority, site, and renewable lease;
- `welcome` — Mainframe identity and accepted compatibility policy;
- `heartbeat` — liveness without a full telemetry payload;
- `telemetry` — normalized, serializable facility state;
- `emergency_command` — authenticated collector-to-Guardian SCRAM request only;
- `ui_offer` / `ui_request` — optional declarative GUI negotiation;
- `acknowledgement` — accepted, rejected, or duplicate processing result;
- `status` / `error` — human-readable operational state.

Every envelope contains the contract name/version, message kind, source
computer/node/session identity, monotonically increasing sequence number,
timestamp, deterministic message ID, and a safe payload.

## Safety boundary

- Guardians retain local control authority and continue operating offline.
- A Mainframe may observe facility telemetry without acquiring ordinary
  actuator access. During a Guardian critical alarm, an operator may explicitly
  request SCRAM; the Guardian executes that request locally and reports status.
- Unknown contracts, kinds, roles, malformed identities, stale sequences,
  duplicates, forged message IDs, functions, cycles, and oversized/deep payloads
  fail validation.
- Adding any command beyond SCRAM requires a separate authorization design, explicit
  capability negotiation, acknowledgement/readback, idempotency, and local
  Guardian refusal rules. It will not be implied by telemetry connectivity.

## Planned handshake

```text
Guardian                         HELIOS Mainframe
   |--- hello ------------------------>|
   |<-- acknowledgement ---------------|
   |<-- welcome -----------------------|
   |--- telemetry / heartbeat -------->|
   |<-- emergency SCRAM (operator) -----|
   |--- status ------------------------>|
   |<-- ui_request (when required) ----|
   |--- ui_offer / status ------------>|
```

The Draconic Guardian now advertises itself at startup, publishes one-second
read-only telemetry, and continues operating locally if HELIOS is absent. The
Mainframe validates and registers Guardian traffic, acknowledges accepted
messages, returns a telemetry-only welcome, and persists facility registration
metadata in `/helios/data/facilities.lua`. Live telemetry remains in memory so
the one-second stream does not churn the computer disk.

`helios facilities` lists registered facility identities. General remote
commands remain deliberately absent from Alpha 1; SCRAM is the sole emergency
exception and does not grant gate-control authority.

## Collector authority and fallback

Continuous facility telemetry is never broadcast. A Guardian broadcasts only
its discovery `hello`, then binds to one collector and unicasts telemetry for
the duration of that collector's lease.

Collector priority is reserved as follows:

1. Overseer (`100`)
2. the elected primary HELIOS Mainframe (`50`)
3. no collector; the Guardian continues local operation

Only a Mainframe for which the existing authority election allows control may
advertise itself as the fallback collector. A valid Overseer presence suppresses
Mainframe facility collection until the Overseer lease expires. The Guardian
then automatically falls back to the elected primary Mainframe. All discovery,
presence, welcome, and telemetry messages must carry the same `siteId`; the
current preserved default is `default`.

## Draconic Profiler link

The optional Draconic Profiler uses a separate, local wireless-modem link. It
does not join `helios.facility.v1`, compete for the Guardian's Mainframe/Overseer
collector lease, or attach to reactor peripherals.

- The Profiler sends a targeted subscription to channel `43120` every three
  seconds, naming both its own computer ID and the configured Guardian ID.
- The named Guardian sends one-second telemetry to channel `43121` while that
  ten-second subscription lease remains live.
- Every telemetry message is addressed to the subscribing Profiler ID and is
  ignored by other Profilers.
- The link has no command message and the Profiler contains no actuator path.
  It can observe, classify, and persist trends, but it cannot alter either gate
  or reactor state.

One Guardian currently serves one paired Profiler. Both computers require a
wireless modem; the Guardian's normal wired facility-network connection may
remain in place at the same time.
