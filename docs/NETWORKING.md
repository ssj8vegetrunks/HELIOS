# HELIOS networking contracts

HELIOS uses separate versioned contracts for different trust boundaries. They
may share a modem, but they must not share message semantics.

## Existing terminal network

`helios.v1` connects a HELIOS Mainframe to read-only Remote terminals. It
provides discovery, assignments, telemetry snapshots, alarms, and duplicate-ID
protection. It remains unchanged during facility-network development.

## Facility network Alpha 1

`helios.facility.v1` is the new Guardian/facility discovery and telemetry
contract. Its first release deliberately has no remote command message.

Supported traffic:

- `hello` — node identity, facility type, software version, capabilities, and
  optional GUI-profile offer;
- `welcome` — Mainframe identity and accepted compatibility policy;
- `heartbeat` — liveness without a full telemetry payload;
- `telemetry` — normalized, serializable facility state;
- `ui_offer` / `ui_request` — optional declarative GUI negotiation;
- `acknowledgement` — accepted, rejected, or duplicate processing result;
- `status` / `error` — human-readable operational state.

Every envelope contains the contract name/version, message kind, source
computer/node/session identity, monotonically increasing sequence number,
timestamp, deterministic message ID, and a safe payload.

## Safety boundary

- Guardians retain local control authority and continue operating offline.
- A Mainframe may observe facility telemetry without acquiring actuator access.
- Unknown contracts, kinds, roles, malformed identities, stale sequences,
  duplicates, forged message IDs, functions, cycles, and oversized/deep payloads
  fail validation.
- Adding commands later requires a separate authorization design, explicit
  capability negotiation, acknowledgement/readback, idempotency, and local
  Guardian refusal rules. It will not be implied by telemetry connectivity.

## Planned handshake

```text
Guardian                         HELIOS Mainframe
   |--- hello ------------------------>|
   |<-- acknowledgement ---------------|
   |<-- welcome -----------------------|
   |--- telemetry / heartbeat -------->|
   |<-- ui_request (when required) ----|
   |--- ui_offer / status ------------>|
```

The current implementation supplies the envelope, validation, sequence, and
acknowledgement primitives. Runtime registration and the Guardian transport
worker are the next integration step.
