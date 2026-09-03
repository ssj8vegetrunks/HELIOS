# HELIOS language packs

HELIOS language packs are data-only Lua tables stored in `/helios/lang/`.
English (`en_us`) is always installed and is the fallback for every missing
translation. Canadian French (`fr_ca`) and Pirate English (`en_pi`) are bundled
as live-test packs. Pirate intentionally uses longer labels to expose cramped
monitor layouts. A damaged, incomplete, or absent selected pack therefore
cannot produce blank labels or disable controls.

## Selecting a language

```text
helios language list
helios language set fr_ca
```

Restart HELIOS after changing the language. The selection is stored as
`ui.language` in `/helios/config.lua` and is preserved during upgrades.

## Pack format

The filename and `id` must use a lowercase language/region identifier such as
`fr_ca.lua` or `de_de.lua`.

```lua
return {
    id = "fr_ca",
    name = "Francais (Canada)",
    strings = {
        ["nav.home"] = "ACCUEIL",
        ["profiler.guardian_status"] = "Gardien {id}  {status}",
    },
}
```

Keys and translations must both be strings. Named placeholders such as
`{id}`, `{status}`, and `{version}` must be retained where they appear in the
English source. Unknown keys and missing entries display their English value.

## Layout contract

Interfaces must request translations by stable key and keep action identifiers
separate from displayed labels. Fixed-width pages may shorten a translated
label with an ellipsis when it cannot fit. Packs should nevertheless keep
button labels concise, especially for pocket computers and small monitors.

The first localization pass covers the shared navigation vocabulary, Guardian
mode/header text, and the complete Draconic Profiler display. Remaining legacy
diagnostic prose will move behind the same service incrementally; it continues
to display in English until a stable key is assigned.
