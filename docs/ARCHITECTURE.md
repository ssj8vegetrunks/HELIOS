# HELIOS Architecture

HELIOS architecture and design specification.
# HELIOS Architecture Specification

HELIOS Architecture v0.1

Shared calculation policy
-------------------------

Hardware-independent calculations are provided by `core/calculations.lua` as a
versioned interface. Roles, official modules, and third-party modules should
call this interface instead of carrying private copies of percentage, clamp,
rounding, and normalization formulas. Power conversion and display formatting
remain centralized in `core/power_format.lua`.

Device-specific API translation remains inside each hardware adapter. The
Draconic Guardian deliberately keeps its containment and fail-safe mathematics
self-contained so reactor safety never depends on a Mainframe or network link.

1. What HELIOS is
2. Core philosophy
   - Mainframe = brain
   - Network = nervous system
   - Hardware = senses/muscles
   - Terminals = eyes/fingers

3. Golden rules
   - Mainframe is sole authority
   - UI doesn't touch hardware
   - Drivers don't know about UI
   - State cache is source of truth
   - Fail gracefully

4. Major components
   - Core
   - Hardware drivers
   - State engine
   - Controllers
   - UI
   - Networking
   - Remote terminals

5. Hardware abstraction
   - Capability detection
   - Extreme Reactors driver
   - Mekanism driver
   - Steam sources publish capacity and output behind one interface
   - Current source: directly water-cooled reactor
   - Future source: liquid-salt reactor plus heat exchanger
   - Plant coordinator prepares a managed steam source before turbine calibration
   - Power-mode reactors never satisfy or receive steam-control requests

6. Remote terminals
   - Reactor / Turbine / Battery / All
   - Pair with mainframe
   - Subscribe to telemetry
   - Render locally
   - Local touch may navigate/silence; it never grants plant-control authority

6.1 Network identity safety
   - Every HELIOS process has a per-boot session identity
   - Duplicate CC computer IDs are reported system-wide
   - Conflict warnings list every duplicated ID and clear automatically
   - Directed telemetry from a conflicting ID is not trusted

6.2 Touch authority
   - Mainframe monitors may operate the mainframe UI
   - Remote monitors may operate only their local read-only UI
   - UI input never calls hardware directly

7. Basic data flow

   Hardware
      ↓
   Drivers
      ↓
   State Cache
      ↓
   Controllers
      ↓
   Hardware

   State Cache
      ↓
   UI / Remote Nodes / Future Web
8. Failure philosophy
   - Display failure must not stop plant control
   - Remote terminal failure must not affect the mainframe
   - Lost telemetry is marked stale, never assumed to be zero
   - Missing hardware capabilities should disable only the affected feature
   - Fail safely where possible
   - Control actuators stay disabled until governors and interlocks pass testing

9. Proposed folders
   - core/       Mainframe services and state
   - hardware/   Discovery and hardware drivers
   - control/    Reactor, turbine, grid and safety logic
   - network/    Mainframe and remote terminal communication
   - ui/         Screens, layouts and reusable widgets
   - config/     Persistent HELIOS configuration

10. Development roadmap

docs/
├── ARCHITECTURE.md       ← concise master blueprint
├── HARDWARE.md           ← drivers/capabilities
├── NETWORKING.md         ← remote nodes/protocol
├── CONTROL.md            ← reactor/turbine/grid logic
├── UI.md                 ← dials/screens/widgets
├── SAFETY.md             ← failures/interlocks
├── INSTALLATION.md
└── WEB.md                ← eventual web plugin

11. External module-pack boundary
   - HELIOS Core owns discovery, control, safety, UI, networking and persistence
   - Peripheral adapters are downloaded from the official Module Pack
   - Core, Module Pack and individual modules have independent versions
   - Mainframe startup fails clearly when a required module is absent or incompatible
   - Remote terminals do not install or execute hardware modules
   - See MODULE_API.md for the manifest and loader contract

12. Graphical UI contract boundary
   - Core publishes sanitized, serializable plant snapshots through `helios.ui`
   - Renderers never receive peripheral handles or call hardware adapters
   - Renderers submit documented command envelopes to guarded Core handlers
   - Remote renderers remain read-only and duplicate computer IDs block commands
   - Manual actuator commands require active Manual authority
   - The built-in text UI remains installed as the failure-safe fallback
   - See UI_API.md for contract versioning, commands, and lifecycle rules

13. Modular installation boundary
   - `install.lua` is a bootstrap and contains no runtime payload
   - `packages/manifest.json` explicitly assigns every installed file to Core, one role, or an optional feature
   - Every computer installs shared Core plus exactly one role package
   - Mainframe, Terminal, Guardian, and Profiler implementation files are never cross-installed
   - Hardware adapters, GUIs, Captain's Log, tools, and non-English languages are independent packages
   - Package dependencies are resolved before download and duplicate destinations are rejected
   - Configuration, calibration, runtime data, and installed language packs survive role-package upgrades
   - Installed safety and control never depend on GitHub or removable storage at runtime
