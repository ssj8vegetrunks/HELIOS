local manual = dofile("src/mainframe/manual_control.lua")

assert(manual.minimumReserve({
    { percent = 80, telemetryOk = true },
    { percent = 1.9, telemetryOk = true },
}) == 1.9, "lowest observable reserve must govern manual safety")

local failed, reserve = manual.shouldFailover({ { percent = 1.9 } }, 2)
assert(failed == true and reserve == 1.9,
    "reserve below two percent must cancel manual authority")

failed, reserve = manual.shouldFailover({ { percent = 2 } }, 2)
assert(failed == false and reserve == 2,
    "exactly two percent must remain in manual authority")

failed, reserve = manual.shouldFailover({
    { percent = 0, telemetryOk = false },
}, 2)
assert(failed == false and reserve == nil,
    "untrusted storage telemetry must not fabricate a reserve reading")

print("manual control tests passed")
