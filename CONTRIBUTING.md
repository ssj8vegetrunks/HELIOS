# Contributing to HELIOS

Thank you for helping test or improve HELIOS. Reports from real modded
facilities are especially valuable because peripheral behavior can differ
across versions and modpacks.

## Before opening an issue

1. Use the latest `testing/public-alpha` build.
2. Back up the ComputerCraft computer directory or reproduce on a fresh
   computer when possible.
3. Check existing issues for the same behavior.
4. Follow the [public-alpha testing guide](docs/TESTING.md).

Never publish world files, server addresses, passwords, tokens, or private
network information in a report.

## Bug reports

Include the HELIOS version and commit or branch, Minecraft/modpack and
CC:Tweaked versions, computer role and ID, attached peripheral names, exact
steps, expected and actual behavior, and whether a restart reproduces the
problem. Screenshots and Probe output are useful for discovery problems.

Safety-related failures should state whether HELIOS issued a hardware command,
whether the command was verified, and how the equipment was returned to a safe
condition.

## Feature requests

Describe the problem first, then the proposed behavior. Explain how the feature
should fail safely and whether it affects Core, a hardware module, a GUI module,
a language pack, or networking.

## Pull requests

- Keep changes focused and avoid unrelated formatting rewrites.
- Preserve the Mainframe authority and read-only Remote boundaries documented
  in [the architecture](docs/ARCHITECTURE.md).
- Hardware writes must be guarded and verified by read-back.
- UI additions must retain the dependable text fallback.
- User-facing text must use the language-pack system with an English fallback.
- Run the relevant tests and describe any live in-game validation performed.
- Update documentation and generated installer/source-map artifacts when the
  change affects them.

AI-assisted contributions are welcome when disclosed. The contributor remains
responsible for reviewing, testing, and understanding the submitted change.

By participating, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
Contributions submitted for inclusion in the official project are also subject
to the [HELIOS Contributor Agreement](CONTRIBUTOR_AGREEMENT.md).
