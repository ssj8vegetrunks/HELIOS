# HELIOS Module Pack API

HELIOS Core owns discovery, governors, safety, UI, networking, persistence, and
the update process. Peripheral adapters live in the separately versioned
official Module Pack.

## Installed layout

```text
/helios/
  core/
    module_loader.lua
  modules/
    manifest.json
    extreme_reactors/
      reactor_adapter.lua
      turbine_adapter.lua
    universal_energy/
      storage_adapter.lua
```

The mainframe installer downloads `module-pack/manifest.json`, confirms that
the pack supports the installed Core version, and then downloads only the
files named by that manifest. Remote terminals do not install hardware
modules.

## Manifest contract

The manifest records three independent version layers:

- HELIOS Core compatibility;
- Module Pack version;
- individual module versions.

Every entry in `provides` maps one capability to one relative Lua file. Paths
must remain inside `/helios/modules`; absolute paths and parent traversal are
rejected.

Current capabilities are:

| Capability | Required adapter behavior |
|---|---|
| `reactor_adapter` | Reactor telemetry and guarded reactor actuator methods |
| `turbine_adapter` | Turbine telemetry and guarded turbine actuator methods |
| `storage_adapter` | Universal read-only energy-storage telemetry |

## Adapter boundary

An adapter file must return a Lua table. Core loads the table through
`core/module_loader.lua`; UI and discovery code never call a module directly.

The first extraction intentionally moves the already tested adapters without
changing their behavior. The Extreme Reactors module supplies the reactor and
turbine adapters. Universal Energy Storage currently contains the generic
driver and its Mekanism Induction Matrix specialization; those internal
drivers can be separated later without changing HELIOS Core.

## Failure behavior

HELIOS refuses to start mainframe control when a required adapter is missing,
invalid, duplicated in the manifest, or incompatible with the installed Core.
It does not silently fall back to an unknown hardware implementation.

Run `helios status` to display Core, Module Pack, and individual module
versions for diagnostics.

Run `helios modules update` on a stopped mainframe to download and atomically
replace the installed Module Pack without reinstalling HELIOS Core. A failed
download or replacement restores the previous pack.
