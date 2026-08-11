local governor = dofile("src/mainframe/reactor_governor.lua")

local control = {
    actuatorsEnabled = true,
    maxRodStep = 5,
    reactorAdjustmentInterval = 5,
    reactorCommandSamples = 3,
    reactorSteamDeadband = 0.03,
    reactorSteamDeadbandMin = 25,
    reactorHotFluidHigh = 85,
}

local function equal(actual, expected, label)
    assert(actual == expected, ("%s: expected %s, got %s"):format(
        label, tostring(expected), tostring(actual)))
end

local function reactor(production, rods, extra)
    local value = {
        name = "reactor_0",
        active = true,
        mode = "steam",
        steamProduction = production,
        controlRodLevel = rods,
        hotFluidPercent = 20,
    }
    for key, item in pairs(extra or {}) do value[key] = item end
    return value
end

local function turbine(flow, extra)
    local value = {
        name = "turbine_0",
        active = true,
        flowRateMax = flow,
        governor = { trusted = true },
    }
    for key, item in pairs(extra or {}) do value[key] = item end
    return value
end

do
    local demand, count = governor.steamDemand({ turbine(2000), turbine(1500) })
    equal(demand, 3500, "aggregate demand")
    equal(count, 2, "active turbine count")
end

do
    local memory = governor.new()
    local low = governor.evaluate(memory, reactor(1200, 50), control, {}, 2000, 1)
    equal(low.action, "WITHDRAW RODS", "low steam direction")
    assert(low.recommendedRodLevel < 50, "low steam should reduce insertion")

    local high = governor.evaluate(memory, reactor(2600, 50), control, {}, 2000, 1)
    equal(high.action, "INSERT RODS", "high steam direction")
    assert(high.recommendedRodLevel > 50, "high steam should increase insertion")

    local stable = governor.evaluate(memory, reactor(2010, 50), control, {}, 2000, 1)
    equal(stable.action, "HOLD", "steam deadband")

    local deficit = governor.evaluate(memory, reactor(1200, 0), control, {}, 2000, 1)
    equal(deficit.state, "STEAM DEFICIT", "maximum-output warning")
    equal(deficit.action, "HOLD", "maximum-output action")
end

do
    local memory = governor.new()
    local buffered = governor.evaluate(memory,
        reactor(2000, 50, { hotFluidPercent = 90 }), control, {}, 2000, 1)
    equal(buffered.state, "BUFFER HIGH", "high buffer state")
    equal(buffered.recommendedRodLevel, 55, "high buffer rod step")

    local idle = governor.evaluate(memory, reactor(0, 98), control, {}, 0, 0)
    equal(idle.recommendedRodLevel, 100, "zero demand shutdown")

    local uneven = governor.evaluate(memory, reactor(2000, 50, {
        controlRodMinimum = 40,
        controlRodMaximum = 60,
    }), control, {}, 2000, 1)
    equal(uneven.state, "RODS NOT UNIFORM", "uneven rod hold")
    equal(uneven.trusted, false, "uneven rod trust")
end

do
    local memory = governor.new()
    local reactors = { reactor(1800, 50), reactor(1800, 50) }
    reactors[2].name = "reactor_1"
    governor.evaluateAll(memory, reactors, { turbine(4000) }, control, {})
    equal(reactors[1].governor.trusted, false, "ambiguous first reactor")
    equal(reactors[2].governor.trusted, false, "ambiguous second reactor")
    equal(reactors[1].governor.state, "NO TRUSTED DEMAND", "routing hold")
end

do
    local memory = governor.new()
    local bad = governor.evaluate(memory, reactor(1000, 50), control,
        { mainframeId = 7, idConflicts = { 7 } }, 2000, 1)
    equal(bad.trusted, false, "ID conflict trust")
    equal(bad.action, "HOLD", "ID conflict action")

    local demand = governor.steamDemand({ turbine(2000,
        { governor = { trusted = false } }) })
    equal(demand, nil, "untrusted demand")
    demand = governor.steamDemand({})
    equal(demand, nil, "missing turbine demand")
end

do
    local memory = governor.new()
    local calls = 0
    local unit = reactor(1000, 50)
    local plan
    for now = 1, 3 do
        plan = governor.evaluate(memory, unit, control, {}, 2000, 1)
    end
    unit.governor = plan
    governor.apply(memory, unit, control, { now = 10 }, {
        setAllControlRodLevels = function(_, level)
            calls = calls + 1
            return true, level
        end,
    })
    equal(calls, 1, "confirmed rod write")
    equal(plan.actuatorState, "APPLIED", "rod actuator state")

    plan = governor.evaluate(memory, reactor(1000, 50), control, {}, 2000, 1)
    unit.governor = plan
    governor.apply(memory, unit, control, { now = 11, maintenance = true }, {
        setAllControlRodLevels = function() calls = calls + 1 return true, 45 end,
    })
    equal(plan.actuatorState, "PAUSED", "maintenance pause")
    equal(calls, 1, "maintenance write count")
end

print("reactor governor tests passed")
