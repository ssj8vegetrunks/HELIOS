local governor = dofile("src/mainframe/turbine_governor.lua")

local control = {
    actuatorsEnabled = true,
    rpmDeadband = 25,
    overspeedRpm = 2000,
    overspeedMargin = 200,
    overspeedSamples = 3,
    maxFlowStep = 100,
    adjustmentInterval = 2,
    commandSamples = 2,
    lowBandRpm = 900,
    highBandRpm = 1800,
    calibrationSpoolRpm = 1800,
    coldStartRpm = 100,
    calibrationSettleDelta = 2,
    calibrationSettleSamples = 8,
    calibrationMinimumRpm = 850,
    calibrationSteamRatio = 0.98,
    calibrationSteamSamples = 5,
    calibrationFailureSamples = 10,
    calibrationSpoolFailureSamples = 2,
    calibrationTimeout = 600,
    turbineProfiles = {},
}

local function equal(actual, expected, label)
    assert(actual == expected, ("%s: expected %s, got %s"):format(
        label, tostring(expected), tostring(actual)))
end

local function turbine(name, rpm, flowSetting, extra)
    local value = {
        name = name,
        active = true,
        rotorSpeed = rpm,
        flowRate = flowSetting,
        flowRateMax = flowSetting,
        flowRateLimit = 2000,
        inductorEngaged = true,
    }
    for key, item in pairs(extra or {}) do value[key] = item end
    return value
end

local function evaluate(memory, name, rpm, flowSetting, extra, now)
    return governor.evaluate(memory, turbine(name, rpm, flowSetting, extra), control,
        { now = now or 1 })
end

local function setProfile(name, target, learned)
    control.turbineProfiles[name] = {
        targetRpm = target,
        learnedRpm = learned or target,
        calibrated = true,
    }
end

local function reachLearning(memory, name)
    for sample = 1, 5 do
        evaluate(memory, name, 0, 2000,
            { inductorEngaged = true, flowRate = 2000 }, sample)
    end
    evaluate(memory, name, 1800, 2000,
        { inductorEngaged = false, flowRate = 2000 }, 6)
    evaluate(memory, name, 1500, 2000,
        { inductorEngaged = true, flowRate = 2000 }, 7)
end

do
    local memory = governor.new()
    setProfile("automatic", 1800)
    local calls = 0
    local first = evaluate(memory, "automatic", 1700, 1000)
    local verifying = governor.apply(memory, { name = "automatic", governor = first },
        control, { now = 9 }, {
            setFlowLimit = function(_, flow) calls = calls + 1 return true, flow end,
        })
    equal(calls, 0, "unconfirmed write count")
    equal(verifying.actuatorState, "VERIFYING", "unconfirmed actuator state")
    local plan = evaluate(memory, "automatic", 1700, 1000)
    local applied = governor.apply(memory, { name = "automatic", governor = plan },
        control, { now = 10 }, {
            setFlowLimit = function(_, flow) calls = calls + 1 return true, flow end,
        })
    equal(calls, 1, "automatic write count")
    equal(applied.appliedFlow, 1100, "automatic applied flow")
end

do
    local memory = governor.new()
    setProfile("bands", 900, 900.76)
    local low = evaluate(memory, "bands", 800, 1000)
    equal(low.action, "INCREASE FLOW", "900-band low action")
    equal(low.targetRpm, 900, "saved low target")
    local stable = evaluate(memory, "bands", 900, 1100)
    equal(stable.state, "SETTLING", "900-band settling state")
    stable = evaluate(memory, "bands", 900, 1100)
    equal(stable.state, "STABLE", "900-band stable state")
    local high = evaluate(memory, "bands", 1000, 1100)
    equal(high.action, "DECREASE FLOW", "900-band high action")
    equal(high.recommendedInductor, true, "operating inductor latch")
end

do
    local memory = governor.new()
    control.turbineProfiles["calibration"] = nil
    local first = evaluate(memory, "calibration", 0, 2000,
        { inductorEngaged = true }, 1)
    equal(first.state, "CALIBRATION PREFLIGHT", "cold-start state")
    equal(first.action, "VERIFY STEAM", "cold-start steam check")
    local release
    for sample = 2, 5 do
        release = evaluate(memory, "calibration", 0, 2000,
            { inductorEngaged = true, flowRate = 2000 }, sample)
    end
    equal(release.action, "DISENGAGE INDUCTOR", "verified clutch action")
    equal(release.recommendedInductor, false, "verified clutch plan")

    evaluate(memory, "calibration", 1000, 2000,
        { inductorEngaged = false, flowRate = 2000 }, 6)
    local engage = evaluate(memory, "calibration", 1800, 2000,
        { inductorEngaged = false, flowRate = 2000 }, 7)
    equal(engage.state, "CALIBRATION SPOOL", "high-band spool state")
    equal(engage.action, "ENGAGE INDUCTOR", "high-band engage action")
    equal(engage.recommendedInductor, true, "high-band engage plan")

    evaluate(memory, "calibration", 1500, 2000,
        { inductorEngaged = true, flowRate = 2000 }, 8)
    for sample = 1, 9 do
        evaluate(memory, "calibration", 900.76, 2000,
            { inductorEngaged = true, flowRate = 2000 }, 8 + sample)
    end
    local learned = control.turbineProfiles["calibration"]
    assert(learned, "calibration profile was not saved")
    equal(learned.targetRpm, 900, "learned operating band")
    assert(math.abs(learned.learnedRpm - 900.76) < 0.01,
        "settled RPM average was not saved")
    equal(governor.consumeProfileChanges(memory), true, "profile dirty signal")
    equal(governor.consumeProfileChanges(memory), false, "profile dirty reset")
end

do
    local memory = governor.new()
    control.turbineProfiles["preflight-starved"] = nil
    local plan
    for sample = 1, 10 do
        plan = evaluate(memory, "preflight-starved", 0, 2000,
            { inductorEngaged = true, flowRate = 1500 }, sample)
    end
    equal(plan.state, "CALIBRATION FAILED", "preflight steam failure")
    equal(plan.recommendedInductor, true, "preflight failure keeps load engaged")
end

do
    local memory = governor.new()
    control.turbineProfiles["installed-running"] = nil
    local plan = evaluate(memory, "installed-running", 900.76, 2000,
        { inductorEngaged = true, flowRate = 2000 }, 1)
    equal(plan.state, "CALIBRATION PREFLIGHT", "unknown running turbine preflight")
    equal(plan.recommendedInductor, true, "preflight keeps load engaged")
end

do
    local memory = governor.new()
    control.turbineProfiles["spool-starved"] = nil
    for sample = 1, 5 do
        evaluate(memory, "spool-starved", 0, 2000,
            { inductorEngaged = true, flowRate = 2000 }, sample)
    end
    local first = evaluate(memory, "spool-starved", 500, 2000,
        { inductorEngaged = false, flowRate = 1500 }, 6)
    equal(first.state, "CALIBRATION SPOOL", "first spool steam drop")
    local failed = evaluate(memory, "spool-starved", 550, 2000,
        { inductorEngaged = false, flowRate = 1500 }, 7)
    equal(failed.state, "CALIBRATION FAILED", "spool steam failure")
    equal(failed.recommendedInductor, true, "spool failure re-engages load")
    local engaged = 0
    local applied = governor.apply(memory,
        { name = "spool-starved", governor = failed }, control, { now = 7 }, {
            setInductor = function(_, value)
                engaged = engaged + 1
                return true, value
            end,
        })
    equal(engaged, 1, "failed spool emergency clutch write")
    equal(applied.actuatorState, "APPLIED", "failed spool clutch state")
end

do
    local memory = governor.new()
    control.turbineProfiles["too-low"] = nil
    reachLearning(memory, "too-low")
    local plan
    for sample = 1, 9 do
        plan = evaluate(memory, "too-low", 800, 2000, { flowRate = 2000 }, 7 + sample)
    end
    equal(plan.state, "CALIBRATION FAILED", "invalid low settle failure")
    equal(control.turbineProfiles["too-low"], nil, "invalid low profile rejection")
    equal(plan.recommendedInductor, true, "failed calibration inductor latch")
end

do
    local memory = governor.new()
    control.turbineProfiles["stopped"] = nil
    reachLearning(memory, "stopped")
    local plan
    for sample = 1, 10 do
        plan = evaluate(memory, "stopped", 0, 2000, { flowRate = 2000 }, 7 + sample)
    end
    equal(plan.state, "CALIBRATION FAILED", "stopped rotor failure")
end

do
    local memory = governor.new()
    control.turbineProfiles["starved"] = nil
    reachLearning(memory, "starved")
    local plan
    for sample = 1, 10 do
        plan = evaluate(memory, "starved", 900, 2000, { flowRate = 1000 }, 7 + sample)
    end
    equal(plan.state, "CALIBRATION FAILED", "steam-starvation failure")
end

do
    local memory = governor.new()
    control.turbineProfiles["timeout"] = nil
    evaluate(memory, "timeout", 0, 2000, { inductorEngaged = false }, 1)
    local plan = evaluate(memory, "timeout", 500, 2000,
        { inductorEngaged = false }, 602)
    equal(plan.state, "CALIBRATION FAILED", "calibration timeout")
end

do
    local memory = governor.new()
    setProfile("overspeed", 1800)
    local first = evaluate(memory, "overspeed", 2001, 1000)
    local second = evaluate(memory, "overspeed", 2002, 1000)
    local third = evaluate(memory, "overspeed", 2003, 1000)
    equal(first.state, "VERIFYING OVERSPEED", "overspeed sample one")
    equal(second.state, "VERIFYING OVERSPEED", "overspeed sample two")
    equal(third.state, "OVERSPEED", "overspeed confirmation")
    equal(third.recommendedFlow, 0, "overspeed flow cut")
end

do
    local memory = governor.new()
    setProfile("maintenance", 1800)
    local plan = governor.evaluate(memory, turbine("maintenance", 1700, 1000),
        control, { maintenance = true })
    local writes = 0
    local result = governor.apply(memory, { name = "maintenance", governor = plan },
        control, { now = 10, maintenance = true }, {
            setFlowLimit = function() writes = writes + 1 return true end,
        })
    equal(writes, 0, "maintenance write count")
    equal(result.actuatorState, "PAUSED", "maintenance actuator state")
end

print("turbine governor tests passed")
