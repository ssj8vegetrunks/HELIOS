# HELIOS language packs

HELIOS language packs are data-only Lua tables stored in `/helios/lang/`.
English (`en_us`) is always installed and is the fallback for every missing
translation. Canadian French (`fr_ca`) and experimental Japanese (`ja_jp`) are visible
installer choices. Pirate English (`en_pi`) is a hidden installer easter egg selected
with `P`; it intentionally uses longer labels to expose cramped
monitor layouts. A damaged, incomplete, or absent selected pack therefore
cannot produce blank labels or disable controls.

## Selecting a language

The installer asks for language before showing any installation category or
configuration screen. That choice controls the rest of the installer and is
written directly to the new HELIOS configuration. On an upgrade, the existing
language is marked as the current choice but the operator may change it.

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
