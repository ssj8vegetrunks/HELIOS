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
    calibrationLowEscapeRpm = 1000,
    coldStartRpm = 100,
    calibrationSettleDelta = 2,
    calibrationSettleSamples = 8,
    calibrationMinimumRpm = 850,
    calibrationSteamRatio = 0.98,
    calibrationSteamSamples = 5,
    calibrationFailureSamples = 10,
    calibrationSpoolFailureSamples = 2,
    calibrationBandEscapeSamples = 3,
    calibrationStallTimeout = 180,
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

local function setProfile(name, target, learned, flow)
    control.turbineProfiles[name] = {
        targetRpm = target,
        learnedRpm = learned or target,
        flowLimit = flow,
        calibrated = true,
    }
end

local function preflight(memory, name, startAt)
    local plan
    startAt = startAt or 1
    for sample = 0, 4 do
        plan = evaluate(memory, name, 0, 2000,
            { inductorEngaged = true, flowRate = 2000 }, startAt + sample)
    end
    equal(plan.action, "DISENGAGE INDUCTOR", name .. " preflight release")
    return startAt + 5
end

local function reachLowTest(memory, name, startAt)
    local now = preflight(memory, name, startAt)
    local engage = evaluate(memory, name, 900, 2000,
        { inductorEngaged = false, flowRate = 2000 }, now)
    equal(engage.action, "ENGAGE INDUCTOR", name .. " low engage")
    local test = evaluate(memory, name, 900, 2000,
        { inductorEngaged = true, flowRate = 2000 }, now + 1)
    equal(test.state, "CALIBRATION TEST 900", name .. " low test")
    return now + 2
end

local function reachHighTest(memory, name, startAt)
    local now = reachLowTest(memory, name, startAt)
    for sample = 0, 2 do
        evaluate(memory, name, 1001 + sample * 5, 2000,
            { inductorEngaged = true, flowRate = 2000 }, now + sample)
    end
    local release = evaluate(memory, name, 1020, 2000,
        { inductorEngaged = true, flowRate = 2000 }, now + 3)
    equal(release.action, "DISENGAGE INDUCTOR", name .. " high release")
    evaluate(memory, name, 1100, 2000,
        { inductorEngaged = false, flowRate = 2000 }, now + 4)
    local engage = evaluate(memory, name, 1800, 2000,
        { inductorEngaged = false, flowRate = 2000 }, now + 5)
    equal(engage.action, "ENGAGE INDUCTOR", name .. " high engage")
    local test = evaluate(memory, name, 1800, 2000,
        { inductorEngaged = true, flowRate = 2000 }, now + 6)
    equal(test.state, "CALIBRATION TEST 1800", name .. " high test")
    return now + 7
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
    setProfile("bands", 900, 900.76, 2000)
    local low = evaluate(memory, "bands", 800, 1000)
    equal(low.action, "INCREASE FLOW", "900-band low action")
    equal(low.targetRpm, 900, "saved low target")
    equal(low.learnedFlow, 2000, "saved flow exposed")
    local high = evaluate(memory, "bands", 1000, 1100)
    equal(high.action, "DECREASE FLOW", "900-band high action")
    equal(high.recommendedInductor, true, "operating inductor latch")
end

-- A 900-RPM machine is learned without ever spooling to 1800.
do
    local memory = governor.new()
    control.turbineProfiles["low-machine"] = nil
    local now = reachLowTest(memory, "low-machine", 1)
    local plan
    for sample = 0, 8 do
        plan = evaluate(memory, "low-machine", 900.76, 2000,
            { inductorEngaged = true, flowRate = 2000 }, now + sample)
    end
    local learned = control.turbineProfiles["low-machine"]
    assert(learned, "low machine profile was not saved")
    equal(learned.targetRpm, 900, "low machine selected band")
    equal(learned.flowLimit, 2000, "low machine saved flow")
end

-- A stable result below the 1000-RPM escape threshold still belongs to band 900.
do
    local memory = governor.new()
    control.turbineProfiles["low-nearby"] = nil
    local now = reachLowTest(memory, "low-nearby", 1)
    for sample = 0, 8 do
        evaluate(memory, "low-nearby", 950, 2000,
            { inductorEngaged = true, flowRate = 2000 }, now + sample)
    end
    equal(control.turbineProfiles["low-nearby"].targetRpm, 900,
        "nearby low result selected band")
end

-- A turbine that overpowers 900 proceeds to 1800 and saves its trimmed flow.
do
    local memory = governor.new()
    control.turbineProfiles["high-machine"] = nil
    local now = reachHighTest(memory, "high-machine", 1)
    local trim = evaluate(memory, "high-machine", 1840, 2000,
        { inductorEngaged = true, flowRate = 2000 }, now)
    equal(trim.action, "DECREASE FLOW", "high machine steam trim")
    equal(trim.recommendedFlow, 1900, "high machine bounded trim")
    local plan
    for sample = 1, 9 do
        plan = evaluate(memory, "high-machine", 1800.5, 1900,
            { inductorEngaged = true, flowRate = 1900 }, now + sample)
    end
    local learned = control.turbineProfiles["high-machine"]
    assert(learned, "high machine profile was not saved")
    equal(learned.targetRpm, 1800, "high machine selected band")
    equal(learned.flowLimit, 1900, "high machine saved flow")
end

-- A failed 1800 test keeps full steam while falling and may still learn 900.
do
    local memory = governor.new()
    control.turbineProfiles["fallback-machine"] = nil
    local now = reachHighTest(memory, "fallback-machine", 1)
    local plan
    for sample = 0, 2 do
        plan = evaluate(memory, "fallback-machine", 1700 - sample * 50, 2000,
            { inductorEngaged = true, flowRate = 2000 }, now + sample)
    end
    equal(plan.state, "CALIBRATION FALLBACK 900", "fallback phase entered")
    equal(plan.recommendedFlow, 2000, "fallback preserves full steam while falling")
    for sample = 3, 11 do
        plan = evaluate(memory, "fallback-machine", 900.5, 2000,
            { inductorEngaged = true, flowRate = 2000 }, now + sample)
    end
    assert(control.turbineProfiles["fallback-machine"],
        "fallback low profile was not saved")
    equal(control.turbineProfiles["fallback-machine"].targetRpm, 900,
        "fallback selected low band")
end

-- A rotor that settles between bands is deliberately trimmed toward 900.
do
    local memory = governor.new()
    control.turbineProfiles["between-bands"] = nil
    local now = reachHighTest(memory, "between-bands", 1)
    for sample = 0, 2 do
        evaluate(memory, "between-bands", 1700, 2000,
            { inductorEngaged = true, flowRate = 2000 }, now + sample)
    end
    local trim = evaluate(memory, "between-bands", 1700, 2000,
        { inductorEngaged = true, flowRate = 2000 }, now + 3)
    equal(trim.state, "CALIBRATION FALLBACK 900", "between bands fallback")
    trim = evaluate(memory, "between-bands", 1700, 2000,
        { inductorEngaged = true, flowRate = 2000 }, now + 4)
    equal(trim.action, "DECREASE FLOW", "between bands steam trim")
    equal(trim.recommendedFlow, 1900, "between bands bounded trim")
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
    control.turbineProfiles["spool-starved"] = nil
    local now = preflight(memory, "spool-starved", 1)
    evaluate(memory, "spool-starved", 500, 2000,
        { inductorEngaged = false, flowRate = 1500 }, now)
    local failed = evaluate(memory, "spool-starved", 550, 2000,
        { inductorEngaged = false, flowRate = 1500 }, now + 1)
    equal(failed.state, "CALIBRATION FAILED", "spool steam failure")
    equal(failed.recommendedInductor, true, "spool failure re-engages load")
end

-- Falling below both bands at full steam is the final failure boundary.
do
    local memory = governor.new()
    control.turbineProfiles["no-band"] = nil
    local now = reachHighTest(memory, "no-band", 1)
    for sample = 0, 2 do
        evaluate(memory, "no-band", 1700 - sample * 50, 2000,
            { inductorEngaged = true, flowRate = 2000 }, now + sample)
    end
    local plan
    for sample = 1, 10 do
        plan = evaluate(memory, "no-band", 840 - sample * 3, 2000,
            { inductorEngaged = true, flowRate = 2000 }, now + 2 + sample)
    end
    equal(plan.state, "CALIBRATION FAILED", "no sustainable band failure")
    equal(control.turbineProfiles["no-band"], nil, "failed profile rejection")
end

-- Long legitimate motion does not hit a total calibration timeout.
do
    local memory = governor.new()
    control.turbineProfiles["slow-fall"] = nil
    local now = reachHighTest(memory, "slow-fall", 1)
    for sample = 0, 2 do
        evaluate(memory, "slow-fall", 1700 - sample * 10, 2000,
            { inductorEngaged = true, flowRate = 2000 }, now + sample)
    end
    local plan = evaluate(memory, "slow-fall", 1200, 2000,
        { inductorEngaged = true, flowRate = 2000 }, now + 700)
    assert(plan.state ~= "CALIBRATION FAILED", "legitimate slow fall used a total timeout")
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
