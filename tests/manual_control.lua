local manual = dofile("src/mainframe/manual_control.lua")

assert(manual.minimumReserve({
    { percent = 80, telemetryOk = true },
    { percent = 1.9, telemetryOk = true },
}) == 1.9, "lowest observable reserve must govern manual safety")

local state = manual.newSafetyState()
local failed, reserve, armed = manual.shouldFailover(state,
    { { percent = 1.9 } }, 2)
assert(failed == false and reserve == 1.9 and armed == false,
    "manual recovery must not fail over when authority starts below reserve")

failed, reserve, armed = manual.shouldFailover(state, { { percent = 2 } }, 2)
assert(failed == false and reserve == 2 and armed == true,
    "reaching two percent must arm the manual safety guard")

failed, reserve, armed = manual.shouldFailover(state, { { percent = 1.9 } }, 2)
assert(failed == true and reserve == 1.9 and armed == true,
    "reserve falling below two percent after arming must cancel manual authority")

state = manual.newSafetyState()
failed, reserve, armed = manual.shouldFailover(state, {
    { percent = 0, telemetryOk = false },
}, 2)
assert(failed == false and reserve == nil and armed == false,
    "untrusted storage telemetry must not fabricate a reserve reading")

local activationCalls = {}
local activated, errors = manual.activateReactors({
    { name = "reactor_a" },
    { name = "reactor_b" },
}, function(reactor, requested)
    activationCalls[#activationCalls + 1] = {
        name = reactor.name,
        requested = requested,
    }
    return true, requested
end)
assert(activated == true and #errors == 0 and #activationCalls == 2,
    "manual entry must verify every reactor activation command")
assert(activationCalls[1].requested == true and
       activationCalls[2].requested == true,
    "manual entry must request active reactors")

activated, errors = manual.activateReactors({ { name = "reactor_a" } },
    function() return false, nil, "offline" end)
assert(activated == false and #errors == 1 and
       string.find(errors[1], "offline", 1, true),
    "manual entry must report rejected reactor activation")

print("manual control tests passed")
