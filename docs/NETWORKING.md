# HELIOS networking contracts

HELIOS uses separate versioned contracts for different trust boundaries. They
may share a modem, but they must not share message semantics.

## Existing terminal network

`helios.v1` connects a HELIOS Mainframe to read-only Remote terminals. It
provides discovery, assignments, telemetry snapshots, alarms, and duplicate-ID
protection.

## Optional multiplayer isolation

Core Alpha 21 adds opt-in shared-key isolation across `helios.v1`,
`helios.facility.v1`, and the local Profiler link. Protection is disabled by
default so trusted single-player and peaceful-server installations retain their
existing zero-configuration behaviour.

When enabled, every HELIOS computer in one installation must use the same
8-128 character key. The key produces a short, non-secret network code used to
identify matching installations; the key itself is not transmitted. Packets
also carry a keyed integrity tag, protocol binding, timestamp, and nonce.
Packets from open networks, different keys, different HELIOS protocols, expired
messages, and packets changed in transit are rejected before application logic.

Configure this through **Settings > Networking** on a Mainframe or with:

```text
helios network status
helios network generate
helios network enable
helios network key
helios network disable
```

The installer offers protection when it detects a modem on a fresh install and
preserves the existing choice during upgrades. Generated pairing keys must be
copied to every Mainframe, Remote terminal, Guardian, and Profiler in the same
HELIOS network.

This application-level isolation prevents accidental and casual cross-network
pairing. CC:Tweaked provides no portable cryptographic API, so server-side claim,
computer, and peripheral permissions remain the security boundary against a
determined hostile player with packet-sniffing or filesystem access.

## Facility network Alpha 1

`helios.facility.v1` is the Guardian/facility discovery, telemetry, and guarded
dispatch contract. Normal output requests are renewable `MIN`, `MED`, or `MAX`
leases. The Guardian establishes containment, ramps locally, and enters a
self-sustaining idle rather than shutting down when demand or its lease ends.

Supported traffic:

- `hello` — node identity, facility type, software version, capabilities, and
  optional GUI-profile offer;
- `collector_presence` — a small broadcast announcing the active telemetry
  collector, its priority, site, and renewable lease;
- `welcome` — Mainframe identity and accepted compatibility policy;
- `heartbeat` — liveness without a full telemetry payload;
- `telemetry` — normalized, serializable facility state;
- `control_command` — authenticated revisioned generation or standby mailbox request;
- `emergency_command` — authenticated collector-to-Guardian SCRAM request only;
- `ui_offer` / `ui_request` — optional declarative GUI negotiation;
- `acknowledgement` — accepted, rejected, or duplicate processing result;
- `status` / `error` — human-readable operational state.

Every envelope contains the contract name/version, message kind, source
computer/node/session identity, monotonically increasing sequence number,
timestamp, deterministic message ID, and a safe payload.

## Safety boundary

- Guardians retain local control authority and continue operating offline.
- The elected Mainframe may request a bounded generation target, but never
  receives direct gate or reactor actuator access. The Guardian independently
  validates mode, commissioning state, containment, temperature, fuel,
  and its locally proven ceiling before applying output.
- During a Guardian critical alarm, an operator may explicitly request SCRAM;
  the Guardian executes that request locally and reports status.
- Unknown contracts, kinds, roles, malformed identities, stale sequences,
  duplicates, forged message IDs, functions, cycles, and oversized/deep payloads
  fail validation.
- Dispatch is available only when the Guardian explicitly advertises
  `remote_dispatch`; telemetry connectivity alone never grants control.

## Planned handshake

```text
Guardian                         HELIOS Mainframe
   |--- hello ------------------------>|
   |<-- acknowledgement ---------------|
   |<-- welcome -----------------------|
   |--- telemetry / heartbeat -------->|
   |<-- revisioned generation/standby -|
   |--- status / telemetry ------------>|
   |<-- emergency SCRAM (operator) -----|
   |--- status ------------------------>|
   |<-- ui_request (when required) ----|
   |--- ui_offer / status ------------>|
```

The Draconic Guardian advertises itself at startup, publishes one-second
telemetry, and continues operating safely if HELIOS is absent. The
Mainframe validates and registers Guardian traffic, negotiates guarded
dispatch, and persists facility registration
metadata in `/helios/data/facilities.lua`. Live telemetry remains in memory so
the one-second stream does not churn the computer disk.

`helios facilities` lists registered facility identities. Ordinary dispatch is
a durable mailbox: the Mainframe emits a new monotonically revisioned request
only when desired state changes, the Guardian applies or rejects it once, and
reports the handled revision in both status and telemetry. An unread request is
retried with bounded backoff instead of being resent every control cycle. Loss
of contact does not erase an accepted request; the Guardian continues locally
safe autonomous control until newer mail arrives. SCRAM remains a separate,
immediate emergency path.

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
