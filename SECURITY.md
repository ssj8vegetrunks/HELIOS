# HELIOS Security Policy

## Supported versions

HELIOS is currently public-alpha software. Security and safety fixes are made
only on the current `testing/public-alpha` line. Older snapshots and development
branches are not supported.

## Reporting a vulnerability

Please use GitHub's **Report a vulnerability** option in the repository's
Security tab to submit a private report. Do not open a public issue for a flaw
that could expose a server, execute untrusted code, bypass HELIOS authority or
safety boundaries, or permit forged network commands.

Include:

- the affected HELIOS version and commit;
- Minecraft, modpack, and CC:Tweaked versions;
- the affected computer role and peripheral type;
- reproduction steps and likely impact; and
- a minimal proof of concept when it can be shared safely.

You should receive an acknowledgement within seven days. Please allow time for
a fix and coordinated disclosure before publishing details.

## Operational safety

HELIOS controls simulated power equipment, but a fault can still damage a
Minecraft world. Back up the world and retain an independent shutdown method
when testing live equipment. Ordinary bugs and gameplay safety problems that do
not create a security risk should use the bug-report form instead.
