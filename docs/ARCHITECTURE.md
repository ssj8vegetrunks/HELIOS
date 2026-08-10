# HELIOS Architecture

HELIOS architecture and design specification.
# HELIOS Architecture Specification

HELIOS Architecture v0.1

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

6. Remote terminals
   - Reactor / Turbine / Battery / All
   - Pair with mainframe
   - Subscribe to telemetry
   - Render locally

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
