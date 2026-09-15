# HELIOS Captain's Log

HELIOS stores operational history as a small navigable archive rather than a
scrolling terminal. Run `helios logs` and choose a day, an hour, and then an
event. Each event opens as a book whose detail pages are shown one at a time.

The archive lives under `/helios/data/logs/`:

```text
logs/
  2026-09-14/        day
    06/              hour
      event-....lua  event book and its detail pages
```

If calendar dates are unavailable, HELIOS uses the Minecraft day number. Event
messages are stored as language keys plus values, so changing languages also
changes how saved events are presented. Severity and subsystem are stored
separately and can be filtered with:

```text
helios logs warning
helios logs critical guardian
```

Logging is enabled by default. Retention defaults to seven days and is bounded
to 256 events per hour, 20 detail pages per event, and 1,024 characters per
page. Oldest days and excess hourly events are removed automatically. These
defaults can be changed in the `logging` section of `/helios/config.lua`; valid
retention is 1 to 30 days.

The current event sources include Mainframe startup, hardware discovery,
reactor/turbine/Guardian state changes, storage reserve bands, alarms,
maintenance, remote facilities and terminals, network-protection changes, and
verified manual reactor/turbine commands. Repeating one-second telemetry is
not recorded; HELIOS writes only state transitions and operator actions.

The same viewer is available from the Mainframe Settings screen through
`CAPTAIN'S LOG`, so the running control room does not need to be stopped.
