local governor = dofile("src/mainframe/reactor_governor.lua")

local control = {
    actuatorsEnabled = true,
    reactorAdjustmentInterval = 5,
    reactorCommandSamples = 3,
    reactorSteamDeadband = 0.01,
    reactorSteamDeadbandMin = 10,
    reactorSteamReserveMargin = 0.025,
    reactorSteamPrimeMargin = 0.90,
    reactorSteamAverageSamples = 4,
    reactorHotFluidHigh = 85,
    reactorHotFluidLow = 15,
    maxRodEquivalentStep = 0.25,
    reactorLearningSamples = 3,
    reactorLearningSteamDelta = 10,
    reactorLearningSteamTolerance = 0.05,
    reactorLearningTemperatureDelta = 0.1,
    reactorLearningBufferDelta = 0.1,
    reactorMinimumResponseTime = 5,
    reactorSettleTimeout = 30,
    reactorCooldownWindow = 10,
    reactorCooldownStallTimeout = 180,
    reactorCooldownSteamDelta = 2,
    reactorCooldownTemperatureDelta = 0.05,
    reactorCalibrationMaxTemperature = 150,
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
    local feedbackControl = {}
    for key, value in pairs(control) do feedbackControl[key] = value end
    feedbackControl.reactorSteamReserveMargin = 0.15
    feedbackControl.reactorProfiles = {
        reactor_0 = {
            exposure = 0.29,
            steam = 2300,
            targetSteam = 2300,
            updatedAt = 1,
        },
    }
    local memory = governor.new()
    local source = reactor(4660, 0.58, { hotFluidPercent = 20 })
    local first = turbine(2000, { name = "turbine_0", inputPercent = 100 })
    local second = turbine(2000, { name = "turbine_1", inputPercent = 100 })
    local plan
    for now = 1, 8 do
        governor.evaluateAll(memory, { source }, { first, second },
            feedbackControl, { now = now })
        plan = source.governor
    end
    equal(plan.targetSteam, 4600,
        "a second turbine updates the fifteen-percent nominal target")
    equal(plan.state, "BUFFER RECOVERY",
        "low reactor buffer overrides full downstream turbine buffers")
    equal(plan.action, "INCREASE EXPOSURE",
        "buffer loss requests additional reactor output")
    equal(plan.hotFluidPercent, 20,
        "reactor hot-fluid buffer drives recovery")
    equal(plan.recommendedRodExposure, 0.83,
        "buffer recovery remains bounded to one configured rod step")

    source.governor = plan
    local applied
    governor.apply(memory, source, feedbackControl, { now = 10 }, {
        setControlRodExposure = function(_, exposure)
            applied = exposure
            return true, exposure
        end,
    })
    equal(applied, 0.83,
        "confirmed buffer recovery reaches the rod actuator")
    equal(source.governor.bufferExposureFloor, 0.83,
        "successful recovery remembers its downstream-loss allowance")

    source = reactor(6000, 0.83, { hotFluidPercent = 90 })
    first.inputPercent, second.inputPercent = 90, 90
    for now = 20, 30 do
        governor.evaluateAll(memory, { source }, { first, second },
            feedbackControl, { now = now })
        plan = source.governor
    end
    equal(plan.state, "BUFFER RESERVE",
        "full buffers do not immediately erase learned network allowance")
    equal(plan.action, "HOLD",
        "buffer reserve prevents a new drain-and-refill oscillation")
    equal(plan.recommendedRodExposure, 0.83,
        "learned buffer exposure floor is retained")
    equal(feedbackControl.reactorProfiles.reactor_0.exposure, 0.83,
        "recovered reactor buffer promotes exposure to reactor default")
    equal(feedbackControl.reactorProfiles.reactor_0.bufferDemand, 4000,
        "saved buffer default is tied to aggregate turbine demand")
    equal(feedbackControl.reactorProfiles.reactor_0.bufferSteam, 6000,
        "saved buffer default records measured reactor output")
    assert(governor.consumeProfileChanges(memory),
        "buffer-calibrated reactor default is marked for persistence")

    second.active = false
    governor.evaluateAll(memory, { source }, { first, second },
        feedbackControl, { now = 31 })
    equal(source.governor.bufferExposureFloor, nil,
        "removing turbine demand clears the old buffer exposure floor")
    equal(source.governor.action, "REDUCE EXPOSURE",
        "reactor may reduce output after turbine demand falls")
    second.active = true

    first.inputPercent, second.inputPercent = 100, 100
    memory = governor.new()
    source = reactor(5000, 0.58, { hotFluidPercent = 20 })
    for now = 1, 8 do
        source.hotFluidPercent = 20 + now
        governor.evaluateAll(memory, { source }, { first, second },
            feedbackControl, { now = now })
        plan = source.governor
    end
    equal(plan.state, "BUFFER FILLING",
        "rising reactor buffer is allowed to fill")
    equal(plan.action, "HOLD",
        "reactor does not reduce output while a turbine buffer is filling")

    governor.evaluateAll(memory, { source }, {
        turbine(2000, { name = "turbine_0" }),
        turbine(2000, { name = "turbine_1" }),
    }, feedbackControl, { now = 20 })
    equal(source.governor.turbineBufferFeedback, false,
        "missing buffer telemetry cannot authorize reactor writes")
end

do
    local uncalibrated = turbine(500, { flowRateLimit = 2000 })
    local demand = governor.steamDemand({ uncalibrated }, control)
    equal(demand, 2000, "uncalibrated turbine requests its hard intake limit")
end

do
    -- Alpha.22 could only use buffer feedback after a reactor profile had
    -- already been saved. A naturally pulsing first calibration therefore sat
    -- at RESPONDING forever with 10/10 averages and 0/8 stable samples.
    local rangeControl = {}
    for key, value in pairs(control) do rangeControl[key] = value end
    rangeControl.reactorSteamReserveMargin = 0.15
    rangeControl.reactorProfiles = {}
    local memory = governor.new()
    governor.beginRecalibration(memory, rangeControl, "reactor_0")
    memory.reactors.reactor_0.calibrationPhase = "ADJUSTING"
    memory.reactors.reactor_0.lastAppliedAt = 0

    local source = reactor(4470, 0.58, {
        casingTemperature = 144,
        hotFluidPercent = 0,
    })
    local first = turbine(2000, { name = "turbine_0", inputPercent = 0 })
    local second = turbine(2000, { name = "turbine_1", inputPercent = 0 })
    local pulses = { 4470, 9588, 5100, 9000, 4700, 9300, 5200, 8800,
        4600, 9400, 5000, 9100 }
    local plan
    for index, production in ipairs(pulses) do
        source.steamProduction = production
        governor.evaluateAll(memory, { source }, { first, second },
            rangeControl, { now = 20 + index })
        plan = source.governor
    end
    equal(plan.state, "BUFFER RECOVERY",
        "first calibration escapes a naturally pulsing output range")
    equal(plan.action, "INCREASE EXPOSURE",
        "empty first-run reactor buffer requests another bounded step")
    equal(plan.recommendedRodExposure, 0.83,
        "first-run buffer recovery remains bounded")
    equal(rangeControl.reactorProfiles.reactor_0, nil,
        "profile is not saved before downstream recovery is proven")

    source.governor = plan
    local applied
    governor.apply(memory, source, rangeControl, { now = 40 }, {
        setControlRodExposure = function(_, exposure)
            applied = exposure
            return true, exposure
        end,
    })
    equal(applied, 0.83,
        "first-run buffer recovery reaches the reactor actuator")

    source = reactor(6000, 0.83, {
        casingTemperature = 144,
        hotFluidPercent = 0,
    })
    local recoveryPulses = { 5400, 7200, 5600, 7000, 5500, 7100 }
    local completed = false
    for index, production in ipairs(recoveryPulses) do
        source.steamProduction = production
        source.hotFluidPercent = index
        first.inputPercent = 100
        second.inputPercent = 100
        governor.evaluateAll(memory, { source }, { first, second },
            rangeControl, { now = 50 + index })
        plan = source.governor
        completed = completed or plan.calibrationCompleted == true
    end
    equal(completed, true,
        "rising reactor buffer completes first pulsing calibration")
    equal(plan.calibrationPhase, nil,
        "buffer-proven first calibration clears its transient phase")
    assert(rangeControl.reactorProfiles.reactor_0,
        "buffer-proven first calibration saves a reactor profile")
    equal(rangeControl.reactorProfiles.reactor_0.exposure, 0.83,
        "buffer-proven exposure becomes the reactor default")
    equal(rangeControl.reactorProfiles.reactor_0.bufferDemand, 4000,
        "first-run buffer default records aggregate turbine demand")
    assert(rangeControl.reactorProfiles.reactor_0.steamHigh >
        rangeControl.reactorProfiles.reactor_0.steamLow,
        "first calibration persists a production range")
end

do
    local memory = governor.new()
    local power = reactor(0, 0, { mode = "power", steamProduction = nil })
    local plan = governor.evaluate(memory, power, control, {}, 2000, 1)
    equal(plan.state, "QUEUED", "uncalibrated power reactor enters commissioning")
    equal(plan.managed, true, "power reactor management flag")

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
    local primeControl = {}
    for key, value in pairs(control) do primeControl[key] = value end
    primeControl.reactorSteamReserveMargin = 0.15
    primeControl.reactorSteamPrimeMargin = 0.90
    primeControl.reactorProfiles = {
        prime_source = {
            exposure = 0.29,
            steam = 2300,
            targetSteam = 2300,
            updatedAt = 1,
        },
    }
    local memory = governor.new()
    local unit = reactor(2300, 0.29, { name = "prime_source" })
    local plan
    for now = 1, 8 do
        unit.casingTemperature = 600 + now
        plan = governor.evaluate(memory, unit, primeControl, {
            now = now,
            steamPrimeRequested = true,
        }, 2000, 1)
    end
    equal(plan.targetSteam, 3800,
        "buffer priming temporarily targets ninety-percent surplus")
    equal(plan.action, "INCREASE EXPOSURE",
        "reactor opens further while priming despite casing-temperature drift")

    memory = governor.new()
    unit = reactor(3800, 0.48, { name = "prime_source" })
    for now = 20, 27 do
        plan = governor.evaluate(memory, unit, primeControl, {
            now = now,
            steamPrimeRequested = true,
        }, 2000, 1)
    end
    equal(plan.state, "PRIMING STEAM",
        "elevated output is held until both buffers report ready")
    equal(primeControl.reactorProfiles.prime_source.targetSteam, 2300,
        "temporary prime does not overwrite the learned reactor profile")

    memory = governor.new()
    unit = reactor(2300, 0.29, { name = "prime_source" })
    for now = 30, 37 do
        plan = governor.evaluate(memory, unit, primeControl, {
            now = now,
            steamPrimeRequested = false,
        }, 2000, 1)
    end
    equal(plan.targetSteam, 2300,
        "completed prime returns to the fifteen-percent reserve target")
    equal(plan.state, "LEARNED",
        "normal reactor profile resumes after buffer priming")
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
    equal(source.bufferPercent, 40, "steam source exposes its hot-fluid buffer")
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
    settle(memory, reactor(2050, 1.25), 2000, 20, control.reactorSteamAverageSamples)
    assert((control.reactorProfiles.reactor_0.learnedMaximumSteam or 0) >= 2050,
        "trusted calibration must persist learned maximum steam capability")
    assert(governor.consumeProfileChanges(memory), "profile change was not reported")
end

do
    local memory = governor.new()
    local unit = reactor(2050, 0.26, {
        name = "dry_buffer",
        hotFluidPercent = 0,
    })
    local stable = settle(memory, unit, 2000, 0, 8)
    equal(stable.state, "LEARNED",
        "stable turbine-matched output learns with an empty buffer")
    assert(control.reactorProfiles.dry_buffer,
        "empty hot-fluid buffer must not block automatic profile saving")
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
    local rangeControl = {}
    for key, value in pairs(control) do rangeControl[key] = value end
    rangeControl.reactorProfiles = {}
    local memory = governor.new()
    local unit = reactor(1800, 0.26, { name = "range_reactor" })
    -- This non-flat sequence moves its rolling average by more than the old
    -- fixed 10 mB/t threshold on every pass, while remaining inside one
    -- repeatable production band around the target.
    local sequence = { 1800, 2300, 1900, 2200, 1850, 2250, 1950, 2150 }
    local plan
    for index, production in ipairs(sequence) do
        unit.steamProduction = production
        plan = governor.evaluate(memory, unit, rangeControl,
            { now = index }, 2000, 1)
    end
    equal(plan.state, "LEARNED",
        "bounded output movement is learned as a stable operating range")
    equal(plan.settleTimedOut, false,
        "range-aware calibration completes before its timeout")
    assert(plan.steamStabilityTolerance >
        rangeControl.reactorLearningSteamDelta,
        "observed range expands the rolling-average tolerance")
    assert(rangeControl.reactorProfiles.range_reactor.steamHigh >
        rangeControl.reactorProfiles.range_reactor.steamLow,
        "learned profile records the observed low and high output")
end

do
    local timeoutControl = {}
    for key, value in pairs(control) do timeoutControl[key] = value end
    timeoutControl.reactorProfiles = {}
    timeoutControl.reactorSettleTimeout = 30
    local memory = governor.new()
    local unit = reactor(1000, 1, { name = "settle_timeout" })
    local plan
    for now = 0, 31 do
        unit.steamProduction = 1000 + now * 300
        plan = governor.evaluate(memory, unit, timeoutControl,
            { now = now }, 2000, 1)
    end
    equal(plan.settleTimedOut, true,
        "bounded settle timeout prevents an infinite responding state")
    assert(plan.state ~= "RESPONDING",
        "settle timeout releases the governor to a bounded correction")
    assert(math.abs(plan.rodExposureChange) <=
        timeoutControl.maxRodEquivalentStep,
        "timeout fallback cannot exceed the normal safe rod step")
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
    local hysteresisControl = {}
    for key, value in pairs(control) do hysteresisControl[key] = value end
    hysteresisControl.reactorProfiles = {
        reactor_0 = {
            exposure = 1.81,
            steam = 11500,
            targetSteam = 11500,
            updatedAt = 1,
        },
    }
    local requested = 11500 / (1 + hysteresisControl.reactorSteamReserveMargin)
    local memory = governor.new()
    local plan = settle(memory, reactor(11765, 1.81), requested, 0, 12)
    equal(plan.state, "LEARNED",
        "small learned-output error settles instead of reversing rod commands")
    equal(plan.action, "HOLD",
        "command hysteresis prevents an endless fine-adjustment loop")
    equal(plan.recommendedRodExposure, 1.81,
        "minor steam surplus retains the learned rod exposure")
    assert(plan.steamCommandDeadband > plan.steamDeadband,
        "physical command threshold is wider than telemetry deadband")

    memory = governor.new()
    plan = settle(memory, reactor(12000, 1.81), requested, 0, 12)
    equal(plan.action, "REDUCE EXPOSURE",
        "meaningful steam surplus still requests a correction")
end

do
    local memory = governor.new()
    local reserveControl = {}
    for key, value in pairs(control) do reserveControl[key] = value end
    reserveControl.reactorSteamReserveMargin = 0.15
    reserveControl.reactorProfiles = {}
    local buffered
    for now = 0, 8 do
        buffered = governor.evaluate(memory,
            reactor(2300, 2, { hotFluidPercent = 90 }), reserveControl,
            { now = now }, 2000, 1)
    end
    equal(buffered.state, "LEARNED", "stable full buffer is a valid operating point")
    equal(buffered.targetSteam, 2300, "fifteen-percent steam reserve target")
    equal(buffered.recommendedRodExposure, 2,
        "full buffer does not cancel active steam reserve")

    memory = governor.new()
    local idle = governor.evaluate(memory, reactor(0, 2), control, {}, 0, 0)
    equal(idle.recommendedRodExposure, 0, "zero demand closes all rods")
end

do
    local memory = governor.new()
    control.reactorProfiles.reactor_0 = nil
    local cooling = settle(memory, reactor(3000, 0, {
        casingTemperature = 800,
    }), 2000, 0, control.reactorSteamAverageSamples)
    equal(cooling.state, "COOLING", "full-insertion cooldown starts safely")
    cooling = governor.evaluate(memory, reactor(2995, 0, {
        casingTemperature = 799.9,
    }), control, { now = 13 }, 2000, 1)
    equal(cooling.state, "COOLING", "falling residual heat remains cooldown")
    cooling = governor.evaluate(memory, reactor(2990, 0, {
        casingTemperature = 799.8,
    }), control, { now = 303 }, 2000, 1)
    equal(cooling.state, "COOLING", "large reactor may cool indefinitely")
    memory.reactors.reactor_0.productionSamples = { 2990, 2990, 2990, 2990 }
    for now = 484, 487 do
        governor.evaluate(memory, reactor(2990, 0, {
            casingTemperature = 799.8,
        }), control, { now = now }, 2000, 1)
    end
    local stalled = governor.evaluate(memory, reactor(2990, 0, {
        casingTemperature = 799.8,
    }), control, { now = 668 }, 2000, 1)
    equal(stalled.state, "STEAM SURPLUS", "stalled cooldown warns")
end

do
    local memory = governor.new()
    governor.beginRecalibration(memory, control, "reactor_0")
    local exposed = reactor(2028, 0.29, {
        casingTemperature = 120,
        hotFluidPercent = 0,
    })
    local applied
    for now = 1, control.reactorCommandSamples do
        local plan = governor.evaluate(memory, exposed, control,
            { now = now }, 2000, 1)
        exposed.governor = plan
        governor.apply(memory, exposed, control, { now = now }, {
            setControlRodExposure = function(_, exposure)
                applied = exposure
                return true, exposure
            end,
        })
        if now < control.reactorCommandSamples then
            equal(applied, nil,
                "recalibration waits for its guarded command samples")
            equal(plan.actuatorState, "VERIFYING",
                "recalibration exposes its actuator verification delay")
        end
    end
    equal(applied, 0,
        "third recalibration command sample inserts every control rod")
end

do
    local memory = governor.new()
    governor.beginRecalibration(memory, control, "reactor_0")
    local unit = reactor(1, 0, {
        casingTemperature = 73,
        hotFluidPercent = 0,
    })
    local plan = settle(memory, unit, 2000, 0,
        control.reactorSteamAverageSamples + 2)
    equal(plan.state, "RECALIBRATING",
        "negligible residual steam releases the calibration baseline")
    equal(plan.action, "INCREASE EXPOSURE",
        "cool baseline begins exposure learning")
    equal(plan.recommendedRodExposure, 0.25,
        "fresh calibration begins with one bounded step")

    -- The completed baseline must survive the confirmation window and the rod
    -- write. Alpha.12 returned to BASELINE as soon as it observed 0.25 eq.
    for now = 20, 21 do
        plan = governor.evaluate(memory, unit, control, { now = now }, 2000, 1)
    end
    equal(plan.calibrationPhase, "TESTING",
        "completed baseline remains in the testing phase")
    equal(plan.recommendedRodExposure, 0.25,
        "first test exposure persists through actuator confirmation")
    unit.governor = plan
    local applied
    governor.apply(memory, unit, control, { now = 30 }, {
        setControlRodExposure = function(_, exposure)
            applied = exposure
            return true, exposure
        end,
    })
    equal(applied, 0.25, "first recalibration test reaches the actuator")

    local testing = reactor(1970, 0.25, {
        casingTemperature = 90,
        hotFluidPercent = 5,
    })
    plan = governor.evaluate(memory, testing, control, { now = 31 }, 2000, 1)
    equal(plan.calibrationPhase, "ADJUSTING",
        "positive exposure advances calibration beyond baseline")
    assert(plan.recommendedRodExposure ~= 0,
        "positive calibration test must never return to zero baseline")

    plan = settle(memory, testing, 2000, 40,
        control.reactorSteamAverageSamples + control.reactorLearningSamples + 2)
    equal(plan.action, "INCREASE EXPOSURE",
        "low first test advances toward the target")
    equal(plan.recommendedRodExposure, 0.26,
        "calibration advances from 0.25 to the measured 0.26 setting")
    equal(plan.calibrationPhase, "ADJUSTING",
        "adjustment remains forward of the completed baseline")

    testing.governor = plan
    governor.apply(memory, testing, control, { now = 60 }, {
        setControlRodExposure = function(_, exposure)
            applied = exposure
            return true, exposure
        end,
    })
    equal(applied, 0.26, "fine calibration adjustment reaches the actuator")
    local learnedUnit = reactor(2050, 0.26, {
        casingTemperature = 90,
        hotFluidPercent = 40,
    })
    local learned, completed = nil, false
    for now = 70, 70 + control.reactorSteamAverageSamples +
            control.reactorLearningSamples + 1 do
        learned = governor.evaluate(memory, learnedUnit, control,
            { now = now }, 2000, 1)
        completed = completed or learned.calibrationCompleted == true
    end
    equal(learned.state, "LEARNED",
        "forward calibration finishes at the measured operating point")
    equal(completed, true,
        "completed recalibration requests post-learning buffer priming")
    equal(learned.calibrationPhase, nil,
        "completed calibration clears its transient phase")
    equal(control.reactorProfiles.reactor_0.exposure, 0.26,
        "completed calibration saves the measured exposure")

    -- A large reactor casing can keep warming after steam output has already
    -- settled at turbine demand. Temperature drift must not hold a proven test
    -- step forever; steam and hot-fluid response are the control signals.
    memory = governor.new()
    governor.beginRecalibration(memory, control, "reactor_0")
    memory.reactors.reactor_0.calibrationPhase = "ADJUSTING"
    memory.reactors.reactor_0.lastAppliedAt = 0
    local drifting
    for now = 20, 20 + control.reactorSteamAverageSamples +
            control.reactorLearningSamples + 2 do
        drifting = governor.evaluate(memory, reactor(2000, 0.25, {
            casingTemperature = 100 + now,
            hotFluidPercent = 5,
        }), control, { now = now }, 2000, 1)
    end
    equal(drifting.action, "INCREASE EXPOSURE",
        "stable steam advances while the large casing temperature drifts")
    equal(drifting.recommendedRodExposure, 0.26,
        "two-thousand mB/t test advances to the reserve setting")
    equal(drifting.calibrationPhase, "ADJUSTING",
        "thermal drift cannot reset or stall forward calibration")

    -- The same large casing continues drifting after a second turbine changes
    -- normal demand. Once steam and the hot-fluid process settle, HELIOS must
    -- take the next bounded rod step instead of holding the old profile.
    memory = governor.new()
    control.reactorProfiles.reactor_0 = {
        exposure = 0.29,
        steam = 2300,
        targetSteam = 2300,
        updatedAt = 10,
    }
    for now = 20, 20 + control.reactorSteamAverageSamples +
            control.reactorLearningSamples + 2 do
        drifting = governor.evaluate(memory, reactor(3820, 0.48, {
            casingTemperature = 100 + now,
            hotFluidPercent = 0,
        }), control, { now = now }, 4000, 2)
    end
    equal(drifting.state, "STEAM LOW",
        "stable steam deficit advances despite large-casing thermal drift")
    equal(drifting.action, "INCREASE EXPOSURE",
        "higher turbine demand receives another bounded rod step")
    assert(drifting.recommendedRodExposure > 0.48,
        "normal regulation must move beyond the old one-turbine setting")

    memory = governor.new()
    governor.beginRecalibration(memory, control, "reactor_0")
    local hot = settle(memory, reactor(1, 0, {
        casingTemperature = 200,
        hotFluidPercent = 0,
    }), 2000, 0, control.reactorSteamAverageSamples + 2)
    equal(hot.state, "COOLING",
        "unsafe casing temperature still holds calibration")
    equal(hot.action, "HOLD",
        "temperature safety threshold does not expose fuel")
end

do
    local memory = governor.new()
    local reactors = { reactor(1800, 1), reactor(1800, 1) }
    reactors[2].name = "reactor_1"
    local fleetControl = {}
    for key, value in pairs(control) do fleetControl[key] = value end
    fleetControl.reactorProfiles = {
        reactor_0 = { exposure = 1, steam = 1800, targetSteam = 1800,
            learnedMaximumSteam = 2500 },
        reactor_1 = { exposure = 1, steam = 1800, targetSteam = 1800,
            learnedMaximumSteam = 5000 },
    }
    governor.evaluateAll(memory, reactors, { turbine(4000) }, fleetControl, {})
    equal(reactors[1].governor.trusted, true, "first fleet reactor is managed")
    equal(reactors[2].governor.trusted, true, "second fleet reactor is managed")
    equal(reactors[1].governor.requestedSteam +
        reactors[2].governor.requestedSteam, 4000,
        "fleet dispatch distributes complete turbine demand")
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

do
    local fleetControl = {}
    for key, value in pairs(control) do fleetControl[key] = value end
    fleetControl.reactorProfiles = {}
    fleetControl.powerReactorProfiles = {}
    fleetControl.powerReactorCalibrationSamples = 3
    local memory = governor.new()
    local first = reactor(0, 0, {
        name = "power_0", mode = "power", steamProduction = nil,
        energyProduction = 1000,
    })
    local second = reactor(0, 0, {
        name = "power_1", mode = "power", steamProduction = nil,
        energyProduction = 2000,
    })
    governor.evaluateAll(memory, { first, second }, {}, fleetControl,
        { now = 1, powerReserve = 50, powerDemand = 0 })
    equal(first.governor.state, "CALIBRATING",
        "first new power reactor starts sequential commissioning")
    equal(second.governor.state, "QUEUED",
        "second new power reactor waits in the commissioning queue")
    local completed = false
    for now = 2, 5 do
        governor.evaluateAll(memory, { first, second }, {}, fleetControl,
            { now = now, powerReserve = 50, powerDemand = 0 })
        completed = completed or first.governor.state == "CALIBRATION COMPLETE"
    end
    equal(completed, true,
        "power commissioning records a stable maximum")
    equal(fleetControl.powerReactorProfiles.power_0.maximumPower, 1000,
        "power profile saves observed generation capability")
    equal(second.governor.state, "CALIBRATING",
        "commissioning advances to the next queued reactor")
    equal(second.governor.commissioningIndex, 2,
        "commissioning progress reports the fleet index")

    local fullMemory = governor.new()
    local fullControl = {}
    for key, value in pairs(fleetControl) do fullControl[key] = value end
    fullControl.powerReactorProfiles = {}
    local full = reactor(0, 0, {
        name = "power_full", mode = "power", steamProduction = nil,
        energyProduction = 0, active = false,
    })
    governor.evaluateAll(fullMemory, { full }, {}, fullControl,
        { now = 1, powerReserve = 100, powerDemand = 0 })
    equal(full.governor.state, "WAITING FOR STORAGE CAPACITY",
        "full storage safely pauses power-reactor commissioning")
    equal(full.governor.recommendedActive, false,
        "full storage does not start a commissioning reactor")

    local dispatchMemory = governor.new()
    local dispatchControl = {}
    for key, value in pairs(fleetControl) do dispatchControl[key] = value end
    dispatchControl.powerReactorProfiles = {
        power_0 = { maximumPower = 1000 },
        power_1 = { maximumPower = 1000 },
    }
    governor.evaluateAll(dispatchMemory, { first, second }, {}, dispatchControl,
        { now = 1, powerReserve = 20, powerDemand = 1500 })
    equal(first.governor.recommendedActive, true,
        "low reserve dispatches the first calibrated power reactor")
    equal(second.governor.recommendedActive, true,
        "demand beyond one reactor dispatches the second reactor")
    governor.evaluateAll(dispatchMemory, { first, second }, {}, dispatchControl,
        { now = 2, powerReserve = 100, powerDemand = 1500 })
    equal(first.governor.recommendedActive, false,
        "full storage returns power reactors to standby")
    equal(second.governor.recommendedActive, false,
        "full storage removes excess fleet generation")
end

do
    local fleetControl = {}
    for key, value in pairs(control) do fleetControl[key] = value end
    fleetControl.reactorProfiles = {}
    fleetControl.powerReactorProfiles = {}
    local memory = governor.new()
    local first = reactor(0, 0, { name = "steam_0" })
    local second = reactor(0, 0, { name = "steam_1" })
    governor.evaluateAll(memory, { first, second }, {}, fleetControl,
        { now = 1, powerReserve = 50, powerDemand = 0 })
    equal(first.governor.state, "AVERAGING",
        "steam commissioning begins without turbine demand")
    equal(first.governor.requestedSteam,
        fleetControl.reactorCommissioningSteamTarget or 1000,
        "commissioning supplies an independent steam learning target")
    equal(second.governor.state, "QUEUED",
        "additional steam reactors wait for clean sequential measurements")
end

print("reactor governor tests passed")
