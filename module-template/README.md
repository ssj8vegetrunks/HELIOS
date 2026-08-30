# HELIOS module template

This directory is a copyable starting point for peripheral support. The example
is intentionally read-only and fails closed. It is not loaded by HELIOS merely
because it exists in the repository.

## Developer workflow

1. Run the standalone Probe against the target hardware.
2. Copy `example_adapter.lua` into a uniquely named module directory.
3. Replace the example peripheral type and normalize telemetry in `read`.
4. Add a matching `provides` entry to a Module Pack manifest.
5. Test missing peripherals, failed calls, malformed values, and reconnects.
6. Add actuator methods only after documenting safety limits and readback.

Use a new capability name for genuinely new hardware behavior. Reuse an
existing capability only when the returned fields and command semantics match
the documented contract.

## Safety rule

Telemetry code may degrade to `nil` plus an error. Control code must never guess.
An actuator should validate the request, make the smallest safe change, read the
hardware back, and return failure when verification is unavailable.

See [`docs/MODULE_API.md`](../docs/MODULE_API.md) for the live loader contract.
`manifest.example.json` is illustrative; do not publish it without replacing
all example IDs, paths, versions, and compatibility declarations.
