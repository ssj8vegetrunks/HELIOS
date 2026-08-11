local governor = dofile("src/mainframe/turbine_governor.lua")

local control = {
    targetRpm = 1800,
    rpmDeadband = 25,
    overspeedRpm = 2000,
    overspeedSamples = 3,
    maxFlowStep = 100,
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
