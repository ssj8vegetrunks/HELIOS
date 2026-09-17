# HELIOS storage

HELIOS keeps control, safety, configuration, calibration, the dependable text interface, and the
English fallback on the computer. Removing a disk can therefore never remove reactor authority or
disable a safety response.

## Archive disk

Attach a writable CC:Tweaked disk and run:

```text
helios archive attach
```

If several disks are mounted, specify the mount shown by CC:Tweaked, such as
`helios archive attach disk2`. HELIOS marks the disk for this computer and places Captain's Log
history under `helios-archive/logs`. Check it with `helios archive status` and release it with
`helios archive detach`. Detaching does not erase existing archives.

Without an archive disk, logging continues with a small local troubleshooting window capped at
48 KiB. The seven-day retention rule still applies on an archive disk.

## Low-space upgrades

The 14 KiB bootstrap downloads only the selected role and feature packages. It first prefers an
ordinary staged upgrade. When the computer cannot hold the old and new role payloads together, it
preserves configuration, calibration, runtime data, and installed language packs while replacing
program files in place. A sufficiently large writable disk may be used as the temporary workspace
automatically, but a disk is not required.

English is installed with Core. Other language packs are downloaded only when requested:

```text
helios language list
helios language install es_es
helios language set es_es
```
