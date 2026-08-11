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
        mode = "observe",
        state = state,
        action = "HOLD",
        reason = reason,
        trusted = trusted ~= false,
    }
end

function governor.new()
    return { turbines = {} }
end

function governor.evaluate(memory, turbine, control, context)
    control = control or {}
    context = context or {}
    memory.turbines = memory.turbines or {}

    local target = tonumber(control.targetRpm) or 1800
    local deadband = math.max(1, tonumber(control.rpmDeadband) or 25)
    local overspeedRpm = math.max(target + deadband, tonumber(control.overspeedRpm) or 2000)
    local overspeedSamples = math.max(1, math.floor(tonumber(control.overspeedSamples) or 3))
    local maxStep = math.max(1, tonumber(control.maxFlowStep) or 100)
    local name = tostring(turbine.name or "unknown")
    local previous = memory.turbines[name] or { overspeedCount = 0 }

    local result
    if context.maintenance then
        result = hold("MAINTENANCE", "Automatic decisions paused during maintenance")
    elseif context.mainframeId and contains(context.idConflicts, context.mainframeId) then
        result = hold("NO TRUSTED DATA", "Mainframe computer ID is conflicting", false)
    elseif turbine.error then
        result = hold("NO TRUSTED DATA", tostring(turbine.error), false)
    elseif turbine.active == false then
        result = hold("OFFLINE", "Turbine is not active")
    elseif turbine.rotorSpeed == nil then
        result = hold("NO RPM DATA", "Rotor-speed telemetry is unavailable", false)
    elseif turbine.flowRateMax == nil and turbine.flowRate == nil then
        result = hold("NO FLOW DATA", "Flow setting telemetry is unavailable", false)
    else
        local rpm = tonumber(turbine.rotorSpeed)
        local currentFlow = tonumber(turbine.flowRateMax) or tonumber(turbine.flowRate)
        local rpmError = target - rpm
        local rpmTrend = previous.rpm and (rpm - previous.rpm) or 0
        local overspeedCount = rpm >= overspeedRpm and (previous.overspeedCount + 1) or 0
        local recommendedFlow = currentFlow
        local state = "STABLE"
        local action = "HOLD"
        local reason = "Rotor is inside the target deadband"

        if rpm >= overspeedRpm then
            if overspeedCount >= overspeedSamples then
                state = "OVERSPEED"
                action = "CUT FLOW"
                reason = "Confirmed overspeed interlock recommendation"
                recommendedFlow = 0
            else
                state = "VERIFYING OVERSPEED"
                action = "HOLD"
                reason = ("Overspeed sample %d/%d"):format(overspeedCount, overspeedSamples)
            end
        elseif math.abs(rpmError) <= deadband then
            if math.abs(rpmTrend) > deadband / 5 then
                state = "SETTLING"
                reason = rpmTrend > 0 and "Inside target band and still accelerating" or
                    "Inside target band and still decelerating"
            end
        else
            local scale = clamp(math.abs(rpmError) / (deadband * 4), 0.25, 1)
            local step = math.max(1, round(maxStep * scale))
            if rpmError > 0 then
                state = rpm < 100 and "STARTING" or
                    (rpmTrend > 1 and "ACCELERATING" or "BELOW TARGET")
                action = "INCREASE FLOW"
                reason = "Rotor is below the target band"
                recommendedFlow = currentFlow + step
            else
                state = rpmTrend < -1 and "DECELERATING" or "ABOVE TARGET"
                action = "DECREASE FLOW"
                reason = "Rotor is above the target band"
                recommendedFlow = currentFlow - step
            end
        end

        local flowMaximum = tonumber(turbine.flowRateLimit)
        recommendedFlow = clamp(recommendedFlow, 0, flowMaximum or math.max(currentFlow, recommendedFlow))
        recommendedFlow = round(recommendedFlow)
        result = {
            mode = "observe",
            state = state,
            action = action,
            reason = reason,
            trusted = true,
            targetRpm = target,
            rpmDeadband = deadband,
            overspeedRpm = overspeedRpm,
            overspeedCount = overspeedCount,
            overspeedSamples = overspeedSamples,
            rpmError = rpmError,
            rpmTrend = rpmTrend,
            currentFlow = currentFlow,
            actualFlow = tonumber(turbine.flowRate),
            recommendedFlow = recommendedFlow,
            flowChange = recommendedFlow - currentFlow,
        }
        previous.overspeedCount = overspeedCount
    end

    if result.state ~= "VERIFYING OVERSPEED" and result.state ~= "OVERSPEED" then
        previous.overspeedCount = 0
    end
    previous.rpm = tonumber(turbine.rotorSpeed)
    memory.turbines[name] = previous
    result.targetRpm = result.targetRpm or target
    result.rpmDeadband = result.rpmDeadband or deadband
    result.overspeedRpm = result.overspeedRpm or overspeedRpm
    result.currentFlow = result.currentFlow or tonumber(turbine.flowRateMax) or tonumber(turbine.flowRate)
    result.actualFlow = result.actualFlow or tonumber(turbine.flowRate)
    result.recommendedFlow = result.recommendedFlow or result.currentFlow
    result.flowChange = result.flowChange or 0
    return result
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
