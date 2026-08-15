local governor = {}

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function round(value)
    return math.floor(value + 0.5)
end

local function contains(list, wanted)
    for _, value in ipairs(list or {}) do
        if tonumber(value) == tonumber(wanted) then return true end
    end
    return false
end

local function hold(state, reason, trusted)
    return {
        mode = "automatic",
        state = state,
        action = "HOLD",
        reason = reason,
        trusted = trusted ~= false,
    }
end

local function profileFor(control, name)
    control.turbineProfiles = control.turbineProfiles or {}
    local profile = control.turbineProfiles[name]
    if type(profile) ~= "table" or tonumber(profile.targetRpm) == nil then return nil end
    return profile
end

local function isSteamSupplyFailure(reason)
    reason = tostring(reason or "")
    return string.find(reason, "Cannot maintain calibration steam", 1, true) == 1 or
        string.find(reason, "Steam supply lost", 1, true) == 1 or
        string.find(reason, "Actual steam telemetry", 1, true) == 1
end

local function saveProfile(memory, control, name, learnedRpm, learnedFlow)
    local lowBand = tonumber(control.lowBandRpm) or 900
    local highBand = tonumber(control.highBandRpm) or 1800
    local target = math.abs(learnedRpm - lowBand) <= math.abs(learnedRpm - highBand)
        and lowBand or highBand
    control.turbineProfiles = control.turbineProfiles or {}
    control.turbineProfiles[name] = {
        targetRpm = target,
        learnedRpm = learnedRpm,
        flowLimit = learnedFlow and round(learnedFlow) or nil,
        calibrated = true,
    }
    memory.profileDirty = true
    return control.turbineProfiles[name]
end

function governor.new()
    return { turbines = {}, profileDirty = false }
end

function governor.consumeProfileChanges(memory)
    local changed = memory.profileDirty == true
    memory.profileDirty = false
    return changed
end

function governor.resetCalibration(memory, control, name)
    name = tostring(name or "")
    control.turbineProfiles = control.turbineProfiles or {}
    local hadProfile = control.turbineProfiles[name] ~= nil
    control.turbineProfiles[name] = nil
    memory.turbines[name] = { overspeedCount = 0 }
    if hadProfile then memory.profileDirty = true end
    return true
end

function governor.evaluate(memory, turbine, control, context)
    control = control or {}
    context = context or {}
    memory.turbines = memory.turbines or {}

    local name = tostring(turbine.name or "unknown")
    local previous = memory.turbines[name] or { overspeedCount = 0 }
    local profile = profileFor(control, name)
    local lowBand = tonumber(control.lowBandRpm) or 900
    local highBand = tonumber(control.highBandRpm) or 1800
    local target = profile and tonumber(profile.targetRpm) or highBand
    local deadband = math.max(1, tonumber(control.rpmDeadband) or 25)
    local overspeedMargin = math.max(deadband, tonumber(control.overspeedMargin) or 200)
    local overspeedRpm = profile and (target + overspeedMargin) or
        math.max(highBand + deadband, tonumber(control.overspeedRpm) or 2000)
    local overspeedSamples = math.max(1, math.floor(tonumber(control.overspeedSamples) or 3))
    local maxStep = math.max(1, tonumber(control.maxFlowStep) or 100)
    local lowEscapeRpm = math.max(lowBand + deadband,
        tonumber(control.calibrationLowEscapeRpm) or (lowBand + 100))
    local coldStartRpm = math.max(0, tonumber(control.coldStartRpm) or 100)
    local settleDelta = math.max(0.1, tonumber(control.calibrationSettleDelta) or 2)
    local settleSamples = math.max(3,
        math.floor(tonumber(control.calibrationSettleSamples) or 8))
    local minimumCalibrationRpm = math.max(0,
        tonumber(control.calibrationMinimumRpm) or (lowBand - deadband * 2))
    local steamRatio = clamp(tonumber(control.calibrationSteamRatio) or 0.98, 0.1, 1)
    local steamSamples = math.max(3,
        math.floor(tonumber(control.calibrationSteamSamples) or 5))
    local failureSamples = math.max(3,
        math.floor(tonumber(control.calibrationFailureSamples) or 10))
    local spoolFailureSamples = math.max(1,
        math.floor(tonumber(control.calibrationSpoolFailureSamples) or 2))
    local escapeSamples = math.max(2,
        math.floor(tonumber(control.calibrationBandEscapeSamples) or 3))
    local stallTimeout = math.max(30,
        tonumber(control.calibrationStallTimeout) or 180)
    local now = tonumber(context.now) or 0

    local result
    if context.maintenance then
        result = hold("MAINTENANCE", "Automatic decisions paused during maintenance")
    elseif context.mainframeId and contains(context.idConflicts, context.mainframeId) then
        result = hold("NO TRUSTED DATA", "Mainframe computer ID is conflicting", false)
    elseif turbine.error then
        result = hold("NO TRUSTED DATA", tostring(turbine.error), false)
    elseif turbine.active == false then
        result = hold("OFFLINE", "Turbine is not active")
    elseif turbine.active ~= true then
        result = hold("NO STATE DATA", "Turbine active-state telemetry is unavailable", false)
    elseif turbine.rotorSpeed == nil then
        result = hold("NO RPM DATA", "Rotor-speed telemetry is unavailable", false)
    elseif turbine.flowRateMax == nil then
        result = hold("NO FLOW SETTING", "Configured flow-limit telemetry is unavailable", false)
    elseif turbine.flowRateLimit == nil then
        result = hold("NO HARD LIMIT", "Turbine hard flow limit is unavailable", false)
    elseif type(turbine.inductorEngaged) ~= "boolean" then
        result = hold("NO INDUCTOR STATE", "Inductor-state telemetry is unavailable", false)
    else
        local rpm = tonumber(turbine.rotorSpeed)
        local currentFlow = tonumber(turbine.flowRateMax)
        local flowMaximum = tonumber(turbine.flowRateLimit)
        local rpmTrend = previous.rpm and (rpm - previous.rpm) or 0
        local overspeedCount = rpm >= overspeedRpm and (previous.overspeedCount + 1) or 0
        local recommendedFlow = currentFlow
        local recommendedInductor = turbine.inductorEngaged
        local state, action, reason = "STABLE", "HOLD", "Rotor is inside the target deadband"

        local function beginPhase(phase)
            previous.phase = phase
            previous.phaseStartedAt = now
            previous.progressAt = now
            previous.progressRpm = rpm
            previous.settleCount = 0
            previous.settleSum = 0
            previous.escapeCount = 0
            previous.failureCount = 0
            previous.lowSteamCount = 0
            previous.fallbackTuning = false
        end

        local function updateProgress(direction)
            if previous.progressRpm == nil then
                previous.progressRpm = rpm
                previous.progressAt = now
            end
            local delta = rpm - previous.progressRpm
            if (direction > 0 and delta >= settleDelta) or
               (direction < 0 and delta <= -settleDelta) or
               (direction == 0 and math.abs(delta) >= settleDelta) then
                previous.progressRpm = rpm
                previous.progressAt = now
            end
            return now > 0 and previous.progressAt and
                now - previous.progressAt >= stallTimeout
        end

        local function fullSteam(required)
            local actual = tonumber(turbine.flowRate)
            required = math.max(0, tonumber(required) or 0)
            return actual ~= nil and (required == 0 or actual >= required * steamRatio), actual
        end

        local function countStable(wanted)
            local stable = math.abs(rpm - wanted) <= deadband and previous.rpm and
                math.abs(rpmTrend) <= settleDelta
            previous.settleCount = stable and ((previous.settleCount or 0) + 1) or 0
            previous.settleSum = stable and ((previous.settleSum or 0) + rpm) or 0
            return previous.settleCount >= settleSamples
        end

        local function countStableRange(minimum, maximum)
            local stable = rpm >= minimum and rpm <= maximum and previous.rpm and
                math.abs(rpmTrend) <= settleDelta
            previous.settleCount = stable and ((previous.settleCount or 0) + 1) or 0
            previous.settleSum = stable and ((previous.settleSum or 0) + rpm) or 0
            return previous.settleCount >= settleSamples
        end

        local function learnBand(wanted, flow)
            local learned = previous.settleCount > 0 and
                previous.settleSum / previous.settleCount or rpm
            profile = saveProfile(memory, control, name, learned, flow)
            target = wanted
            overspeedRpm = target + overspeedMargin
            previous.phase = "OPERATING"
            previous.settleCount, previous.settleSum = 0, 0
            return learned
        end

        if profile then
            previous.phase = "OPERATING"
        elseif previous.phase == nil then
            beginPhase("PREFLIGHT")
        elseif previous.phase == "ENGAGE_LOW" and turbine.inductorEngaged == true then
            beginPhase("TEST_LOW")
        elseif previous.phase == "RELEASE_HIGH" and turbine.inductorEngaged == false then
            beginPhase("SPOOL_HIGH")
        elseif previous.phase == "ENGAGE_HIGH" and turbine.inductorEngaged == true then
            beginPhase("TEST_HIGH")
        end

        if rpm >= overspeedRpm then
            recommendedInductor = true
            if overspeedCount >= overspeedSamples then
                state, action = "OVERSPEED", "CUT FLOW"
                reason = "Confirmed overspeed: engage inductor and cut steam"
                recommendedFlow = 0
            else
                state = "VERIFYING OVERSPEED"
                action = turbine.inductorEngaged and "HOLD" or "ENGAGE INDUCTOR"
                reason = ("Overspeed sample %d/%d"):format(overspeedCount, overspeedSamples)
            end
        elseif not profile and context.steamSourceManaged == true and
               context.steamSourceReady ~= true then
            previous.phase = "PREFLIGHT"
            previous.calibrationError = nil
            previous.fullSteamCount = 0
            previous.lowSteamCount = 0
            previous.settleCount = 0
            previous.settleSum = 0
            state = "WAITING FOR STEAM SOURCE"
            recommendedInductor = true
            recommendedFlow = flowMaximum
            if turbine.inductorEngaged == false then
                action = "ENGAGE INDUCTOR"
            elseif currentFlow < flowMaximum then
                action = "MAXIMIZE FLOW"
            else
                action = "WAIT FOR STEAM SOURCE"
            end
            reason = tostring(context.steamSourceReason or
                "Preparing managed steam supply before turbine calibration")
        elseif not profile and previous.phase == "FAILED" and
               context.steamSourceManaged == true and
               isSteamSupplyFailure(previous.calibrationError) then
            beginPhase("PREFLIGHT")
            previous.calibrationError = nil
            previous.fullSteamCount = 0
            previous.lowSteamCount = 0
            state = "CALIBRATION PREFLIGHT"
            action = turbine.inductorEngaged and "VERIFY STEAM" or "ENGAGE INDUCTOR"
            reason = "Managed steam restored; retrying turbine calibration"
            recommendedInductor = true
            recommendedFlow = flowMaximum
        elseif previous.phase == "FAILED" then
            state = "CALIBRATION FAILED"
            action = turbine.inductorEngaged and "HOLD" or "ENGAGE INDUCTOR"
            reason = previous.calibrationError or "Calibration conditions were invalid"
            recommendedInductor = true
        elseif not profile and previous.phase == "PREFLIGHT" then
            local actualFlow = tonumber(turbine.flowRate)
            local fullSteam = actualFlow ~= nil and flowMaximum > 0 and
                actualFlow >= flowMaximum * steamRatio
            previous.fullSteamCount = fullSteam and
                ((previous.fullSteamCount or 0) + 1) or 0
            previous.lowSteamCount = fullSteam and 0 or
                ((previous.lowSteamCount or 0) + 1)
            state = "CALIBRATION PREFLIGHT"
            recommendedInductor = true
            recommendedFlow = flowMaximum
            if turbine.inductorEngaged == false then
                action = "ENGAGE INDUCTOR"
                reason = "Steam preflight runs with generator load engaged"
                previous.fullSteamCount = 0
            elseif currentFlow < flowMaximum then
                action = "MAXIMIZE FLOW"
                reason = "Request full steam before calibration spool"
                previous.fullSteamCount = 0
            elseif previous.lowSteamCount >= failureSamples then
                previous.phase = "FAILED"
                previous.calibrationError = actualFlow == nil and
                    "Actual steam telemetry is unavailable" or
                    ("Cannot maintain calibration steam: %.0f of %.0f mB/t"):format(
                        actualFlow, flowMaximum)
                state = "CALIBRATION FAILED"
                action = turbine.inductorEngaged and "HOLD" or "ENGAGE INDUCTOR"
                reason = previous.calibrationError
                recommendedFlow = currentFlow
            elseif previous.fullSteamCount >= steamSamples then
                beginPhase("SPOOL_LOW")
                action = "DISENGAGE INDUCTOR"
                recommendedInductor = false
                reason = ("Full steam verified %d/%d; test 900 RPM band first"):format(
                    previous.fullSteamCount, steamSamples)
            else
                action = "VERIFY STEAM"
                reason = ("Full-steam sample %d/%d"):format(
                    previous.fullSteamCount, steamSamples)
            end
        elseif not profile and (previous.phase == "SPOOL_LOW" or
               previous.phase == "SPOOL_HIGH") then
            local spoolTarget = previous.phase == "SPOOL_LOW" and lowBand or highBand
            local steamOk, actualFlow = fullSteam(flowMaximum)
            local steamStarved = not steamOk
            previous.lowSteamCount = steamStarved and
                ((previous.lowSteamCount or 0) + 1) or 0
            state = previous.phase == "SPOOL_LOW" and "CALIBRATION SPOOL 900" or
                "CALIBRATION SPOOL 1800"
            recommendedFlow = flowMaximum
            if previous.lowSteamCount >= spoolFailureSamples then
                previous.phase = "FAILED"
                previous.calibrationError = actualFlow == nil and
                    "Actual steam telemetry was lost during calibration spool" or
                    ("Steam supply lost during spool: requested %.0f, received %.0f mB/t"):format(
                        flowMaximum, actualFlow)
                state = "CALIBRATION FAILED"
                action = turbine.inductorEngaged and "HOLD" or "ENGAGE INDUCTOR"
                reason = previous.calibrationError
                recommendedInductor = true
                recommendedFlow = currentFlow
            elseif rpm >= spoolTarget then
                previous.phase = previous.phase == "SPOOL_LOW" and
                    "ENGAGE_LOW" or "ENGAGE_HIGH"
                recommendedInductor = true
                action = "ENGAGE INDUCTOR"
                reason = ("Reached %.0f RPM; apply generator load"):format(spoolTarget)
            elseif updateProgress(1) then
                previous.phase = "FAILED"
                previous.calibrationError = ("Rotor stopped gaining speed before %.0f RPM"):format(
                    spoolTarget)
                state = "CALIBRATION FAILED"
                action = turbine.inductorEngaged and "HOLD" or "ENGAGE INDUCTOR"
                reason = previous.calibrationError
                recommendedInductor = true
            else
                recommendedInductor = false
                action = turbine.inductorEngaged and "DISENGAGE INDUCTOR" or
                    (currentFlow < flowMaximum and "MAXIMIZE FLOW" or "WAIT FOR SPEED")
                reason = ("Unloaded spool to %.0f RPM"):format(spoolTarget)
            end
        elseif not profile and (previous.phase == "ENGAGE_LOW" or
               previous.phase == "ENGAGE_HIGH") then
            local band = previous.phase == "ENGAGE_LOW" and lowBand or highBand
            state = ("CALIBRATION ENGAGE %.0f"):format(band)
            action = "ENGAGE INDUCTOR"
            reason = ("Engage generator load and observe %.0f RPM band"):format(band)
            recommendedInductor = true
            recommendedFlow = flowMaximum
        elseif not profile and previous.phase == "RELEASE_HIGH" then
            state = "CALIBRATION ESCALATE"
            action = "DISENGAGE INDUCTOR"
            reason = "900 RPM band was overpowered; continue unloaded to 1800 RPM"
            recommendedInductor = false
            recommendedFlow = flowMaximum
        elseif not profile and previous.phase == "TEST_LOW" then
            state = "CALIBRATION TEST 900"
            recommendedInductor = true
            recommendedFlow = flowMaximum
            local steamOk, actualFlow = fullSteam(flowMaximum)
            previous.lowSteamCount = not steamOk and
                ((previous.lowSteamCount or 0) + 1) or 0
            if turbine.inductorEngaged == false then
                action = "ENGAGE INDUCTOR"
                reason = "900 RPM test requires generator load"
                previous.settleCount, previous.settleSum = 0, 0
            elseif previous.lowSteamCount >= spoolFailureSamples then
                previous.phase = "FAILED"
                previous.calibrationError = ("Steam supply lost during 900 RPM test: requested %.0f, received %.0f mB/t"):format(
                    flowMaximum, actualFlow or 0)
                state, action, reason = "CALIBRATION FAILED", "HOLD", previous.calibrationError
                recommendedFlow = currentFlow
            elseif rpm > lowEscapeRpm and rpmTrend > 0 then
                previous.escapeCount = (previous.escapeCount or 0) + 1
                previous.settleCount, previous.settleSum = 0, 0
                action = "VERIFY HIGH BAND"
                reason = ("Rotor climbing past %.0f RPM: %d/%d"):format(
                    lowEscapeRpm, previous.escapeCount, escapeSamples)
                if previous.escapeCount >= escapeSamples then
                    previous.phase = "RELEASE_HIGH"
                    action = "DISENGAGE INDUCTOR"
                    recommendedInductor = false
                    reason = "900 RPM band cannot absorb full steam; test 1800 RPM"
                end
            elseif countStableRange(minimumCalibrationRpm, lowEscapeRpm) then
                local learned = learnBand(lowBand, currentFlow)
                state, action = "CALIBRATED", "HOLD"
                reason = ("Stable at %.1f RPM; saved 900 RPM profile"):format(learned)
            elseif rpm < minimumCalibrationRpm and rpmTrend < -settleDelta then
                previous.failureCount = (previous.failureCount or 0) + 1
                action = "VERIFY LOW BAND"
                reason = ("Rotor falling below valid 900 RPM band: %d/%d"):format(
                    previous.failureCount, failureSamples)
                if previous.failureCount >= failureSamples then
                    previous.phase = "FAILED"
                    previous.calibrationError = "No sustainable 900 RPM operating band"
                    state, action, reason = "CALIBRATION FAILED", "HOLD",
                        previous.calibrationError
                end
            elseif updateProgress(0) then
                previous.phase = "FAILED"
                previous.calibrationError = ("Rotor stalled at %.1f RPM outside the 900 RPM band"):format(rpm)
                state, action, reason = "CALIBRATION FAILED", "HOLD", previous.calibrationError
                recommendedFlow = currentFlow
            else
                previous.escapeCount = 0
                previous.failureCount = 0
                action = "OBSERVE 900 BAND"
                reason = "Generator loaded at full steam; watching RPM trend"
            end
        elseif not profile and previous.phase == "TEST_HIGH" then
            state = "CALIBRATION TEST 1800"
            recommendedInductor = true
            local requiredFlow = currentFlow
            local steamOk, actualFlow = fullSteam(requiredFlow)
            previous.lowSteamCount = not steamOk and
                ((previous.lowSteamCount or 0) + 1) or 0
            if turbine.inductorEngaged == false then
                action = "ENGAGE INDUCTOR"
                reason = "1800 RPM test requires generator load"
                previous.settleCount, previous.settleSum = 0, 0
            elseif previous.lowSteamCount >= spoolFailureSamples then
                previous.phase = "FAILED"
                previous.calibrationError = ("Steam supply lost during 1800 RPM test: requested %.0f, received %.0f mB/t"):format(
                    requiredFlow, actualFlow or 0)
                state, action, reason = "CALIBRATION FAILED", "HOLD", previous.calibrationError
            elseif countStable(highBand) then
                local learned = learnBand(highBand, currentFlow)
                state, action = "CALIBRATED", "HOLD"
                reason = ("Stable at %.1f RPM; saved 1800 RPM at %.0f mB/t"):format(
                    learned, currentFlow)
            elseif rpm > highBand + deadband and rpmTrend > 0 then
                action = "DECREASE FLOW"
                reason = "Rotor still climbing above 1800 RPM; trim steam"
                recommendedFlow = currentFlow - maxStep
                previous.settleCount, previous.settleSum = 0, 0
            elseif rpm < highBand - deadband and rpmTrend <= settleDelta then
                previous.escapeCount = (previous.escapeCount or 0) + 1
                action = "VERIFY FALLBACK"
                reason = ("1800 RPM band losing speed: %d/%d"):format(
                    previous.escapeCount, escapeSamples)
                recommendedFlow = flowMaximum
                if previous.escapeCount >= escapeSamples then
                    beginPhase("FALLBACK_LOW")
                    state = "CALIBRATION FALLBACK 900"
                    action = "MAXIMIZE FLOW"
                    reason = "1800 RPM unsustainable; keep full steam and test 900 RPM"
                end
            elseif updateProgress(0) then
                previous.phase = "FAILED"
                previous.calibrationError = ("Rotor stalled at %.1f RPM outside the 1800 RPM band"):format(rpm)
                state, action, reason = "CALIBRATION FAILED", "HOLD", previous.calibrationError
            else
                previous.escapeCount = 0
                action = "OBSERVE 1800 BAND"
                reason = "Generator loaded; watching RPM trend"
            end
        elseif not profile and previous.phase == "FALLBACK_LOW" then
            state = "CALIBRATION FALLBACK 900"
            recommendedInductor = true
            local steamOk, actualFlow = fullSteam(currentFlow)
            previous.lowSteamCount = not steamOk and
                ((previous.lowSteamCount or 0) + 1) or 0
            if turbine.inductorEngaged == false then
                action = "ENGAGE INDUCTOR"
                reason = "Fallback test keeps generator load engaged"
            elseif previous.lowSteamCount >= spoolFailureSamples then
                previous.phase = "FAILED"
                previous.calibrationError = ("Steam supply lost during 900 RPM fallback: requested %.0f, received %.0f mB/t"):format(
                    flowMaximum, actualFlow or 0)
                state, action, reason = "CALIBRATION FAILED", "HOLD", previous.calibrationError
            elseif countStableRange(minimumCalibrationRpm, lowBand + deadband) then
                local learned = learnBand(lowBand, currentFlow)
                state, action = "CALIBRATED", "HOLD"
                reason = ("1800 RPM failed; stable at %.1f RPM, saved 900 RPM profile"):format(
                    learned)
            elseif rpm < minimumCalibrationRpm and rpmTrend < -settleDelta and
                   currentFlow >= flowMaximum then
                previous.failureCount = (previous.failureCount or 0) + 1
                action = "VERIFY FAILURE"
                reason = ("Rotor falling below both operating bands: %d/%d"):format(
                    previous.failureCount, failureSamples)
                if previous.failureCount >= failureSamples then
                    previous.phase = "FAILED"
                    previous.calibrationError = "No sustainable 900 or 1800 RPM operating band"
                    state, action, reason = "CALIBRATION FAILED", "HOLD",
                        previous.calibrationError
                end
            elseif rpm >= highBand - deadband and rpmTrend > settleDelta then
                beginPhase("TEST_HIGH")
                state = "CALIBRATION TEST 1800"
                action = "OBSERVE 1800 BAND"
                reason = "Rotor recovered toward the 1800 RPM band"
            elseif rpm > lowBand + deadband and rpmTrend < -settleDelta then
                if previous.fallbackTuning then
                    recommendedFlow = currentFlow
                    action = "WAIT FOR 900 BAND"
                    reason = "Hold the tuned flow while rotor falls toward 900 RPM"
                else
                    recommendedFlow = flowMaximum
                    action = currentFlow < flowMaximum and "MAXIMIZE FLOW" or
                        "WAIT FOR 900 BAND"
                    reason = "Rotor is naturally falling; maintain full steam toward 900 RPM"
                end
                updateProgress(-1)
            elseif rpm > lowBand + deadband then
                previous.fallbackTuning = true
                recommendedFlow = currentFlow - maxStep
                action = "DECREASE FLOW"
                reason = "Rotor settled above 900 RPM; trim steam toward low band"
                updateProgress(0)
            elseif rpm < minimumCalibrationRpm and currentFlow < flowMaximum then
                recommendedFlow = flowMaximum
                action = "MAXIMIZE FLOW"
                reason = "Restore full steam before rejecting the 900 RPM band"
            elseif updateProgress(0) then
                previous.phase = "FAILED"
                previous.calibrationError = ("Rotor stalled at %.1f RPM outside either operating band"):format(rpm)
                state, action, reason = "CALIBRATION FAILED", "HOLD", previous.calibrationError
            else
                previous.failureCount = 0
                action = "OBSERVE 900 BAND"
                reason = "Watching the fallback RPM trend"
            end
        else
            recommendedInductor = true
            if turbine.inductorEngaged == false then
                state, action = "RESTORING LOAD", "ENGAGE INDUCTOR"
                reason = "Calibrated operation keeps the inductor engaged"
            else
                local rpmError = target - rpm
                if math.abs(rpmError) <= deadband then
                    if math.abs(rpmTrend) > deadband / 5 then
                        state = "SETTLING"
                        reason = rpmTrend > 0 and "Inside target band and still accelerating" or
                            "Inside target band and still decelerating"
                    end
                else
                    local scale = clamp(math.abs(rpmError) / (deadband * 4), 0.25, 1)
                    local step = math.max(1, round(maxStep * scale))
                    if rpmError > 0 then
                        state = rpmTrend > 1 and "ACCELERATING" or "BELOW TARGET"
                        action = "INCREASE FLOW"
                        reason = "Rotor is below the learned target band"
                        recommendedFlow = currentFlow + step
                    else
                        state = rpmTrend < -1 and "DECELERATING" or "ABOVE TARGET"
                        action = "DECREASE FLOW"
                        reason = "Rotor is above the learned target band"
                        recommendedFlow = currentFlow - step
                    end
                end
            end
        end

        recommendedFlow = round(clamp(recommendedFlow, 0, flowMaximum))
        result = {
            mode = "automatic",
            state = state,
            action = action,
            reason = reason,
            trusted = true,
            calibrationPhase = previous.phase,
            calibrated = profile ~= nil,
            learnedRpm = profile and tonumber(profile.learnedRpm) or nil,
            learnedFlow = profile and tonumber(profile.flowLimit) or nil,
            targetRpm = target,
            rpmDeadband = deadband,
            overspeedRpm = overspeedRpm,
            overspeedCount = overspeedCount,
            overspeedSamples = overspeedSamples,
            rpmError = target - rpm,
            rpmTrend = rpmTrend,
            currentFlow = currentFlow,
            actualFlow = tonumber(turbine.flowRate),
            recommendedFlow = recommendedFlow,
            flowChange = recommendedFlow - currentFlow,
            currentInductor = turbine.inductorEngaged,
            recommendedInductor = recommendedInductor,
            inductorChange = recommendedInductor ~= turbine.inductorEngaged,
            calibrationSpoolRpm = previous.phase == "SPOOL_LOW" and lowBand or highBand,
            calibrationSettleCount = previous.settleCount or 0,
            calibrationSettleSamples = settleSamples,
        }
        if action ~= "HOLD" and action ~= "WAIT FOR SPEED" and
           action ~= "WAIT FOR STEAM SOURCE" and
           action ~= "WAIT TO SETTLE" and action ~= "MEASURE SETTLE" then
            previous.actionSamples = previous.action == action and
                ((previous.actionSamples or 0) + 1) or 1
            previous.action = action
        else
            previous.actionSamples = 0
            previous.action = nil
        end
        result.actionSamples = previous.actionSamples
        previous.overspeedCount = overspeedCount
    end

    if result.state ~= "VERIFYING OVERSPEED" and result.state ~= "OVERSPEED" then
        previous.overspeedCount = 0
    end
    if result.action == "HOLD" then
        previous.actionSamples = 0
        previous.action = nil
    end
    previous.rpm = tonumber(turbine.rotorSpeed)
    memory.turbines[name] = previous
    result.targetRpm = result.targetRpm or target
    result.rpmDeadband = result.rpmDeadband or deadband
    result.overspeedRpm = result.overspeedRpm or overspeedRpm
    result.currentFlow = result.currentFlow or tonumber(turbine.flowRateMax)
    result.actualFlow = result.actualFlow or tonumber(turbine.flowRate)
    result.recommendedFlow = result.recommendedFlow or result.currentFlow
    result.flowChange = result.flowChange or 0
    if result.currentInductor == nil then result.currentInductor = turbine.inductorEngaged end
    if result.recommendedInductor == nil then result.recommendedInductor = turbine.inductorEngaged end
    result.inductorChange = result.recommendedInductor ~= nil and
        result.currentInductor ~= nil and result.recommendedInductor ~= result.currentInductor
    return result
end

function governor.apply(memory, turbine, control, context, writers)
    control = control or {}
    context = context or {}
    local plan = turbine and turbine.governor
    if not plan then return nil end

    local name = tostring(turbine.name or "unknown")
    local previous = memory.turbines[name] or {}
    local now = tonumber(context.now) or 0
    local interval = math.max(1, tonumber(control.adjustmentInterval) or 2)
    local commandSamples = math.max(1, math.floor(tonumber(control.commandSamples) or 2))
    local current = tonumber(plan.currentFlow)
    local proposed = tonumber(plan.recommendedFlow)
    local needsFlow = current ~= nil and proposed ~= nil and current ~= proposed
    local needsInductor = plan.inductorChange == true
    local emergency = plan.action == "CUT FLOW" or
        (plan.state == "CALIBRATION FAILED" and needsInductor and
            plan.recommendedInductor == true)

    plan.mode = control.actuatorsEnabled == true and "automatic" or "observe"
    if control.actuatorsEnabled ~= true then
        plan.actuatorState = "DISABLED"
    elseif context.maintenance then
        plan.actuatorState = "PAUSED"
    elseif plan.trusted == false then
        plan.actuatorState = "UNTRUSTED"
    elseif not needsFlow and not needsInductor then
        plan.actuatorState = "HOLD"
    elseif not emergency and (tonumber(plan.actionSamples) or 0) < commandSamples then
        plan.actuatorState = "VERIFYING"
    elseif type(writers) ~= "table" or
           (needsFlow and type(writers.setFlowLimit) ~= "function") or
           (needsInductor and type(writers.setInductor) ~= "function") then
        plan.actuatorState = "FAULT"
        plan.actuatorError = "Required turbine write adapter is unavailable"
    elseif not emergency and previous.lastAttemptAt and
           now - previous.lastAttemptAt < interval then
        plan.actuatorState = previous.lastError and "FAULT" or "WAITING"
        plan.actuatorError = previous.lastError
        plan.nextAdjustmentIn = interval - (now - previous.lastAttemptAt)
    else
        previous.lastAttemptAt = now
        local ok, appliedFlow, appliedInductor, reason = true, nil, nil, nil
        if needsInductor then
            ok, appliedInductor, reason = writers.setInductor(turbine, plan.recommendedInductor)
        end
        if ok and needsFlow then
            ok, appliedFlow, reason = writers.setFlowLimit(turbine, proposed)
        end
        if ok then
            previous.lastAppliedAt = now
            if needsFlow then
                previous.lastAppliedFlow = tonumber(appliedFlow) or proposed
                plan.appliedFlow = previous.lastAppliedFlow
            end
            if needsInductor then
                previous.lastAppliedInductor = appliedInductor == true
                plan.appliedInductor = previous.lastAppliedInductor
            end
            previous.lastError = nil
            plan.actuatorState = "APPLIED"
        else
            previous.lastError = tostring(reason or "Turbine rejected the actuator command")
            plan.actuatorState = "FAULT"
            plan.actuatorError = previous.lastError
            if needsFlow then plan.reportedFlow = tonumber(appliedFlow) end
            if needsInductor then plan.reportedInductor = appliedInductor end
        end
    end

    plan.lastAppliedAt = previous.lastAppliedAt
    plan.lastAppliedFlow = previous.lastAppliedFlow
    plan.lastAppliedInductor = previous.lastAppliedInductor
    memory.turbines[name] = previous
    return plan
end

function governor.applyAll(memory, turbines, control, context, writers)
    for _, turbine in ipairs(turbines or {}) do
        governor.apply(memory, turbine, control, context, writers)
    end
    return turbines
end

function governor.evaluateAll(memory, turbines, control, context)
    local present = {}
    for _, turbine in ipairs(turbines or {}) do
        present[tostring(turbine.name)] = true
        turbine.governor = governor.evaluate(memory, turbine, control, context)
    end
    for name in pairs(memory.turbines or {}) do
        if not present[name] then memory.turbines[name] = nil end
    end
    return turbines
end

return governor
