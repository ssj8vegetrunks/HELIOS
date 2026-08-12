local governor = dofile("src/mainframe/reactor_governor.lua")

local control = {
    actuatorsEnabled = true,
    reactorAdjustmentInterval = 5,
    reactorCommandSamples = 3,
    reactorSteamDeadband = 0.01,
    reactorSteamDeadbandMin = 10,
    reactorSteamReserveMargin = 0.025,
    reactorSteamAverageSamples = 4,
    reactorHotFluidHigh = 85,
    reactorHotFluidLow = 15,
    maxRodEquivalentStep = 0.25,
    reactorLearningSamples = 3,
    reactorLearningSteamDelta = 10,
    reactorLearningTemperatureDelta = 0.1,
    reactorLearningBufferDelta = 0.1,
    reactorMinimumResponseTime = 5,
    reactorCooldownWindow = 10,
    reactorCooldownStallTimeout = 180,
    reactorCooldownSteamDelta = 2,
    reactorCooldownTemperatureDelta = 0.05,
    reactorProfiles = {},
}

local function equal(actual, expected, label)
    assert(actual == expected, ("%s: expected %s, got %s"):format(
        label, tostring(expected), tostring(actual)))
end

local function levelsFor(count, exposure)
    local levels = {}
    local points = math.floor(exposure * 100 + 0.5)
    local each, remainder = math.floor(points / count), points % count
    for index = 0, count - 1 do
        levels[index] = 100 - each - (index < remainder and 1 or 0)
    end
    return levels
end

local function sequentialLevels(count, exposure)
    local levels, full, fraction = {}, math.floor(exposure), exposure % 1
    for index = 0, count - 1 do
        if index < full then levels[index] = 0
        elseif index == full and fraction > 0.0001 then
            levels[index] = math.floor(100 - fraction * 100 + 0.5)
        else levels[index] = 100 end
    end
    return levels
end

local function reactor(production, exposure, extra)
    local count = 25
    local value = {
        name = "reactor_0",
        active = true,
        mode = "steam",
        steamProduction = production,
        controlRods = count,
        controlRodLevels = levelsFor(count, exposure),
        hotFluidPercent = 40,
        casingTemperature = 600,
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

local function settle(memory, unit, target, first, samples)
    local result
    for offset = 0, (samples or 8) - 1 do
        result = governor.evaluate(memory, unit, control,
            { now = (first or 0) + offset }, target, 1)
    end
    return result
end

do
    local demand, count = governor.steamDemand({ turbine(2000), turbine(1500) })
    equal(demand, 3500, "aggregate demand")
    equal(count, 2, "active turbine count")
end

do
    local uncalibrated = turbine(500, { flowRateLimit = 2000 })
    local demand = governor.steamDemand({ uncalibrated }, control)
    equal(demand, 2000, "uncalibrated turbine requests its hard intake limit")
end

do
    local memory = governor.new()
    local power = reactor(0, 0, { mode = "power", steamProduction = nil })
    local plan = governor.evaluate(memory, power, control, {}, 2000, 1)
    equal(plan.state, "MONITOR ONLY", "power reactor steam exclusion")
    equal(plan.managed, false, "power reactor management flag")

    local offline = reactor(0, 0, { active = false })
    plan = governor.evaluate(memory, offline, control, {}, 2000, 1)
    equal(plan.state, "STARTING", "offline steam reactor startup")
    equal(plan.recommendedActive, true, "steam reactor activation request")
    offline.governor = plan
    local calls = 0
    governor.apply(memory, offline, control, { now = 10 }, {
        setActive = function(_, active)
            calls = calls + 1
            return true, active
        end,
    })
    equal(calls, 1, "verified steam reactor startup write")
    equal(plan.actuatorState, "APPLIED", "steam reactor startup state")
end

do
    local power = reactor(0, 0, { name = "power_0", mode = "power" })
    local steam = reactor(2050, 0.26, { name = "steam_0" })
    steam.governor = {
        trusted = true,
        averageSteamProduction = 2050,
        averageSteamSamples = control.reactorSteamAverageSamples,
    }
    local source = governor.steamSourceStatus({ power, steam }, 2000, control)
    equal(source.managed, true, "steam source detected beside power reactor")
    equal(source.ready, true, "power reactor does not block ready steam source")
end

do
    local memory = governor.new()
    local low = settle(memory, reactor(1200, 1), 2000)
    equal(low.action, "INCREASE EXPOSURE", "low steam direction")
    assert(low.recommendedRodExposure > 1, "low steam should expose more fuel")
    assert(low.recommendedRodExposure <= 1.25, "exposure step must be bounded")

    memory = governor.new()
    local high = settle(memory, reactor(2600, 2), 2000)
    equal(high.action, "REDUCE EXPOSURE", "high steam direction")
    assert(high.recommendedRodExposure < 2, "high steam should expose less fuel")
    assert(high.recommendedRodExposure >= 1.75, "reduction step must be bounded")

    memory = governor.new()
    local stable = settle(memory, reactor(2050, 1.25), 2000, 0, 8)
    equal(stable.state, "LEARNED", "stable operating point")
    assert(control.reactorProfiles.reactor_0, "stable profile was not saved")
    assert(governor.consumeProfileChanges(memory), "profile change was not reported")
end

do
    local memory = governor.new()
    memory.reactors.reactor_0 = {
        points = { { exposure = 1, steam = 1000 } },
    }
    local plan = settle(memory, reactor(1500, 1.25), 2000)
    equal(plan.recommendedRodExposure, 1.5,
        "two-point interpolation estimates target exposure")
    equal(plan.action, "INCREASE EXPOSURE", "interpolation direction")
end

do
    local memory = governor.new()
    local concentrated = sequentialLevels(25, 8.5)
    local plan = governor.evaluate(memory, reactor(7376, 8.5, {
        controlRodLevels = concentrated,
        hotFluidPercent = 90,
    }), control, { now = 0 }, 2000, 1)
    equal(plan.state, "BASELINING", "concentrated bank starts safe baseline")
    equal(plan.action, "REDUCE EXPOSURE", "baseline insertion action")
    equal(plan.recommendedRodExposure, 0, "baseline fully inserts every rod")
end

do
    local memory = governor.new()
    local low = settle(memory, reactor(1970, 0.25), 2000, 0, 8)
    equal(low.recommendedRodExposure, 0.26,
        "one percent of one rod supplies the reserve margin")
    equal(low.action, "INCREASE EXPOSURE", "1970 mB/t is below reserve target")

    memory = governor.new()
    local exact = settle(memory, reactor(2050, 0.26), 2000, 0, 8)
    equal(exact.state, "LEARNED", "live 25-rod operating point is learned")
    equal(exact.requestedSteam, 2000, "raw turbine demand is retained")
    equal(exact.targetSteam, 2050, "two-and-a-half percent reserve target")
end

do
    local memory = governor.new()
    local learned = settle(memory, reactor(2050, 0.26), 2000, 0, 8)
    equal(learned.state, "LEARNED", "recovery test learns live operating point")

    local overridden = reactor(1900, 0, { casingTemperature = 590 })
    local plan
    for sample = 1, control.reactorSteamAverageSamples + 2 do
        overridden.steamProduction = 1900 - sample * 10
        overridden.casingTemperature = 590 - sample
        plan = governor.evaluate(memory, overridden, control,
            { now = 20 + sample }, 2000, 1)
    end
    equal(plan.state, "RECOVERING",
        "manual full insertion restores learned exposure while cooling")
    equal(plan.action, "INCREASE EXPOSURE",
        "manual full insertion recovery direction")
    equal(plan.recommendedRodExposure, 0.25,
        "learned exposure recovery remains bounded")
    equal(plan.averageSteamSamples, control.reactorSteamAverageSamples,
        "external rod change collects a fresh rolling average")

    overridden.governor = plan
    local applied
    governor.apply(memory, overridden, control, { now = 40 }, {
        setControlRodExposure = function(_, exposure)
            applied = exposure
            return true, exposure
        end,
    })
    equal(applied, 0.25,
        "confirmed recovery command reaches the rod actuator")
    equal(plan.actuatorState, "APPLIED",
        "manual full insertion recovery is applied")
end

do
    local memory = governor.new()
    local unit = reactor(1900, 0.26)
    local sequence = { 1900, 2200, 1900, 2200, 1900, 2200, 1900, 2200 }
    local plan
    for index, production in ipairs(sequence) do
        unit.steamProduction = production
        plan = governor.evaluate(memory, unit, control, { now = index }, 2000, 1)
    end
    equal(plan.averageSteamProduction, 2050,
        "rolling average smooths cyclic rod output")
    equal(plan.state, "LEARNED", "cyclic samples learn from their average")
end

do
    local memory = governor.new()
    local changing = reactor(7376, 2.5, { hotFluidPercent = 20 })
    governor.evaluate(memory, changing, control, { now = 0 }, 2000, 1)
    changing.steamProduction = 2000
    changing.hotFluidPercent = 90
    changing.casingTemperature = 590
    local plan = governor.evaluate(memory, changing, control, { now = 1 }, 2000, 1)
    equal(plan.state, "AVERAGING", "buffer-fill slump is not learned")
    equal(plan.action, "HOLD", "moving reactor receives no stacked command")
end

do
    local memory = governor.new()
    local buffered = settle(memory,
        reactor(2000, 2, { hotFluidPercent = 90 }), 2000)
    equal(buffered.state, "BUFFER HIGH", "stable high buffer state")
    equal(buffered.recommendedRodExposure, 1.75,
        "high buffer reduces one quarter equivalent")

    memory = governor.new()
    local idle = governor.evaluate(memory, reactor(0, 2), control, {}, 0, 0)
    equal(idle.recommendedRodExposure, 0, "zero demand closes all rods")
end

do
    local memory = governor.new()
    local cooling = governor.evaluate(memory, reactor(3000, 0, {
        casingTemperature = 800,
    }), control, { now = 0 }, 2000, 1)
    equal(cooling.state, "COOLING", "full-insertion cooldown starts safely")
    cooling = governor.evaluate(memory, reactor(2995, 0, {
        casingTemperature = 799.9,
    }), control, { now = 10 }, 2000, 1)
    equal(cooling.state, "COOLING", "falling residual heat remains cooldown")
    cooling = governor.evaluate(memory, reactor(2990, 0, {
        casingTemperature = 799.8,
    }), control, { now = 300 }, 2000, 1)
    equal(cooling.state, "COOLING", "large reactor may cool indefinitely")
    local stalled = governor.evaluate(memory, reactor(2990, 0, {
        casingTemperature = 799.8,
    }), control, { now = 481 }, 2000, 1)
    equal(stalled.state, "STEAM SURPLUS", "stalled cooldown warns")
end

do
    local memory = governor.new()
    local reactors = { reactor(1800, 1), reactor(1800, 1) }
    reactors[2].name = "reactor_1"
    governor.evaluateAll(memory, reactors, { turbine(4000) }, control, {})
    equal(reactors[1].governor.trusted, false, "ambiguous first reactor")
    equal(reactors[2].governor.trusted, false, "ambiguous second reactor")
end

do
    local memory = governor.new()
    local bad = governor.evaluate(memory, reactor(1000, 1), control,
        { mainframeId = 7, idConflicts = { 7 } }, 2000, 1)
    equal(bad.trusted, false, "ID conflict trust")
    equal(governor.steamDemand({ turbine(2000,
        { governor = { trusted = false } }) }), nil, "untrusted demand")
end

do
    local memory, calls = governor.new(), 0
    local unit = reactor(1000, 1)
    local plan = settle(memory, unit, 2000, 0, 9)
    unit.governor = plan
    governor.apply(memory, unit, control, { now = 10 }, {
        setControlRodExposure = function(_, exposure)
            calls = calls + 1
            return true, exposure
        end,
    })
    equal(calls, 1, "confirmed exposure write")
    equal(plan.actuatorState, "APPLIED", "rod actuator state")

    plan = settle(memory, reactor(1000, 1.25), 2000, 20, 7)
    unit.governor = plan
    governor.apply(memory, unit, control, { now = 30, maintenance = true }, {
        setControlRodExposure = function() calls = calls + 1 return true, 1.5 end,
    })
    equal(plan.actuatorState, "PAUSED", "maintenance pause")
    equal(calls, 1, "maintenance write count")
end

do
    local memory = governor.new()
    control.reactorProfiles.reactor_0 = {
        exposure = 0.26,
        steam = 2050,
        targetSteam = 2050,
        updatedAt = 10,
    }
    governor.beginRecalibration(memory, control, "reactor_0")
    equal(control.reactorProfiles.reactor_0, nil,
        "recalibration removes the active learned profile")
    local plan = governor.evaluate(memory, reactor(2050, 0.26), control,
        { now = 20 }, 2000, 1)
    equal(plan.state, "RECALIBRATING", "recalibration closes rods first")
    equal(plan.recommendedRodExposure, 0,
        "recalibration establishes a zero-exposure baseline")

    local unit = reactor(2050, 0.26)
    unit.governor = {
        averageSteamProduction = 2050,
        targetSteam = 2050,
    }
    local ok = governor.saveCurrentCalibration(memory, control, unit, { now = 30 })
    equal(ok, true, "current reactor setup can be saved")
    equal(control.reactorProfiles.reactor_0.exposure, 0.26,
        "saved current setup retains balanced rod exposure")
    equal(control.reactorProfiles.reactor_0.updatedAt, 30,
        "saved current setup records calibration time")

    governor.deleteCalibration(memory, control, "reactor_0")
    equal(control.reactorProfiles.reactor_0, nil,
        "delete calibration removes saved reactor data")

    local power = reactor(0, 0, { mode = "power", steamProduction = nil })
    local saved, reason = governor.saveCurrentCalibration(memory, control, power, {})
    equal(saved, false, "power reactor calibration is rejected")
    equal(reason, "Only steam reactors can be calibrated",
        "power reactor calibration rejection explains why")
end

print("reactor governor tests passed")
