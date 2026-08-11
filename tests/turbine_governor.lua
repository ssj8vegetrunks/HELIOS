local governor = dofile("src/mainframe/turbine_governor.lua")

local control = {
    actuatorsEnabled = true,
    targetRpm = 1800,
    rpmDeadband = 25,
    overspeedRpm = 2000,
    overspeedSamples = 3,
    maxFlowStep = 100,
    adjustmentInterval = 2,
    commandSamples = 2,
}

local function evaluate(memory, name, rpm, flowSetting, flowLimit, extra)
    local turbine = {
        name = name,
        active = true,
        rotorSpeed = rpm,
        flowRate = flowSetting,
        flowRateMax = flowSetting,
        flowRateLimit = flowLimit,
    }
    for key, value in pairs(extra or {}) do turbine[key] = value end
    return governor.evaluate(memory, turbine, control, {})
end

local function equal(actual, expected, label)
    assert(actual == expected, ("%s: expected %s, got %s"):format(
        label, tostring(expected), tostring(actual)))
end

do
    local memory = governor.new()
    local calls = 0
    local first = evaluate(memory, "automatic", 1700, 1000, 2000)
    local verifying = governor.apply(memory, {
        name = "automatic", governor = first,
    }, control, { now = 9 }, function(_, flow)
        calls = calls + 1
        return true, flow
    end)
    equal(calls, 0, "unconfirmed write count")
    equal(verifying.actuatorState, "VERIFYING", "unconfirmed actuator state")
    local plan = evaluate(memory, "automatic", 1700, 1000, 2000)
    local applied = governor.apply(memory, {
        name = "automatic", governor = plan,
    }, control, { now = 10 }, function(_, flow)
        calls = calls + 1
        return true, flow
    end)
    equal(calls, 1, "automatic write count")
    equal(applied.actuatorState, "APPLIED", "automatic actuator state")
    equal(applied.appliedFlow, 1100, "automatic applied flow")
end

do
    local memory = governor.new()
    local first = evaluate(memory, "rate-limited", 1700, 1000, 2000)
    governor.apply(memory, { name = "rate-limited", governor = first }, control,
        { now = 9 }, function(_, flow) return true, flow end)
    local second = evaluate(memory, "rate-limited", 1700, 1000, 2000)
    governor.apply(memory, { name = "rate-limited", governor = second }, control,
        { now = 10 }, function(_, flow) return true, flow end)
    local third = evaluate(memory, "rate-limited", 1700, 1100, 2000)
    local writes = 0
    local result = governor.apply(memory, { name = "rate-limited", governor = third }, control,
        { now = 11 }, function(_, flow) writes = writes + 1 return true, flow end)
    equal(writes, 0, "rate-limited write count")
    equal(result.actuatorState, "WAITING", "rate-limited state")
end

do
    local memory = governor.new()
    evaluate(memory, "fault", 1700, 1000, 2000)
    local plan = evaluate(memory, "fault", 1700, 1000, 2000)
    local result = governor.apply(memory, { name = "fault", governor = plan }, control,
        { now = 10 }, function() return false, nil, "rejected" end)
    equal(result.actuatorState, "FAULT", "failed actuator state")
    equal(result.actuatorError, "rejected", "failed actuator reason")
end

do
    local memory = governor.new()
    evaluate(memory, "maintenance", 1700, 1000, 2000)
    local plan = evaluate(memory, "maintenance", 1700, 1000, 2000)
    local writes = 0
    local result = governor.apply(memory, { name = "maintenance", governor = plan }, control,
        { now = 10, maintenance = true }, function() writes = writes + 1 return true end)
    equal(writes, 0, "maintenance write count")
    equal(result.actuatorState, "PAUSED", "maintenance actuator state")
end

do
    local memory = governor.new()
    local plan = evaluate(memory, "low", 1700, 1000, 2000)
    equal(plan.state, "BELOW TARGET", "low RPM state")
    equal(plan.action, "INCREASE FLOW", "low RPM action")
    equal(plan.recommendedFlow, 1100, "low RPM flow")
end

do
    local memory = governor.new()
    local plan = evaluate(memory, "stable", 1790, 1000, 2000)
    equal(plan.state, "STABLE", "deadband state")
    equal(plan.recommendedFlow, 1000, "deadband flow")
end

do
    local memory = governor.new()
    local plan = evaluate(memory, "high", 1900, 1000, 2000)
    equal(plan.state, "ABOVE TARGET", "high RPM state")
    equal(plan.action, "DECREASE FLOW", "high RPM action")
    equal(plan.recommendedFlow, 900, "high RPM flow")
end

do
    local memory = governor.new()
    local first = evaluate(memory, "overspeed", 2001, 1000, 2000)
    local second = evaluate(memory, "overspeed", 2002, 1000, 2000)
    local third = evaluate(memory, "overspeed", 2003, 1000, 2000)
    equal(first.state, "VERIFYING OVERSPEED", "overspeed sample one")
    equal(second.state, "VERIFYING OVERSPEED", "overspeed sample two")
    equal(third.state, "OVERSPEED", "overspeed confirmation")
    equal(third.recommendedFlow, 0, "overspeed flow cut")
end

do
    local memory = governor.new()
    evaluate(memory, "interrupted", 2001, 1000, 2000)
    governor.evaluate(memory, {
        name = "interrupted", active = false, rotorSpeed = 0, flowRateMax = 1000,
    }, control, {})
    local nextSample = evaluate(memory, "interrupted", 2001, 1000, 2000)
    equal(nextSample.overspeedCount, 1, "overspeed sequence reset")
end

do
    local memory = governor.new()
    local plan = evaluate(memory, "limited", 1600, 1980, 2000)
    equal(plan.recommendedFlow, 2000, "hard flow limit")
end

do
    local memory = governor.new()
    local plan = governor.evaluate(memory, {
        name = "offline", active = false, rotorSpeed = 0, flowRateMax = 1000,
    }, control, {})
    equal(plan.state, "OFFLINE", "offline state")
    equal(plan.action, "HOLD", "offline action")
end

do
    local memory = governor.new()
    local plan = governor.evaluate(memory, {
        name = "conflict", active = true, rotorSpeed = 1700, flowRateMax = 1000,
    }, control, { mainframeId = 2, idConflicts = { 2 } })
    equal(plan.state, "NO TRUSTED DATA", "conflict state")
    equal(plan.trusted, false, "conflict trust")
end

print("turbine governor tests passed")
