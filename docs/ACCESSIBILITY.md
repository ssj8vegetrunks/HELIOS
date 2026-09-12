# HELIOS accessibility

HELIOS never relies on colour alone for operational state. Status text remains
explicit, safety states may carry ASCII markers, and graphical progress bars
use both colour and `=`/`.` fill patterns.

## Colour profiles

The installer and Mainframe Settings offer five profiles:

- `standard`
- `deuteranopia`
- `protanopia`
- `tritanopia`
- `high_contrast`

The selected profile is stored as `ui.accessibilityProfile` in
`/helios/config.lua` and is preserved during upgrades. HELIOS applies the
palette to the computer terminal and every mirrored monitor.

Profiles may also be managed from any HELIOS computer:

```lua
helios accessibility list
helios accessibility set deuteranopia
helios accessibility symbols on
```

## Status symbols

Status symbols are enabled by default and can be disabled independently in
Settings. The stable ASCII vocabulary is:

| Symbol | Meaning |
|---|---|
| `[X]` | Critical condition or fault |
| `[!]` | Warning or attention required |
| `[+]` | Healthy, ready, or successful |
| `[i]` | Informational state |
| `[-]` | Inactive, unavailable, or deliberately disabled |
| `[*]` | General state |

Language packs translate the accompanying words, never the symbols. Third-party
GUI modules must preserve explicit text, numeric values, or patterns whenever
they use semantic colours.
