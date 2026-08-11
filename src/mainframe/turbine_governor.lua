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
    elseif turbine.active ~= true then
        result = hold("NO STATE DATA", "Turbine active-state telemetry is unavailable", false)
    elseif turbine.rotorSpeed == nil then
        result = hold("NO RPM DATA", "Rotor-speed telemetry is unavailable", false)
    elseif turbine.flowRateMax == nil then
        result = hold("NO FLOW SETTING", "Configured flow-limit telemetry is unavailable", false)
    elseif turbine.flowRateLimit == nil then
        result = hold("NO HARD LIMIT", "Turbine hard flow limit is unavailable", false)
    else
        local rpm = tonumber(turbine.rotorSpeed)
        local currentFlow = tonumber(turbine.flowRateMax)
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
            mode = "automatic",
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
        if action ~= "HOLD" then
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
    return result
end

function governor.apply(memory, turbine, control, context, writer)
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

    plan.mode = control.actuatorsEnabled == true and "automatic" or "observe"
    if control.actuatorsEnabled ~= true then
        plan.actuatorState = "DISABLED"
    elseif context.maintenance then
        plan.actuatorState = "PAUSED"
    elseif plan.trusted == false then
        plan.actuatorState = "UNTRUSTED"
    elseif plan.action == "HOLD" or current == nil or proposed == nil or current == proposed then
        plan.actuatorState = "HOLD"
    elseif plan.action ~= "CUT FLOW" and (tonumber(plan.actionSamples) or 0) < commandSamples then
        plan.actuatorState = "VERIFYING"
    elseif type(writer) ~= "function" then
        plan.actuatorState = "FAULT"
        plan.actuatorError = "Turbine write adapter is unavailable"
    elseif plan.action ~= "CUT FLOW" and previous.lastAttemptAt and
           now - previous.lastAttemptAt < interval then
        plan.actuatorState = previous.lastError and "FAULT" or "WAITING"
        plan.actuatorError = previous.lastError
        plan.nextAdjustmentIn = interval - (now - previous.lastAttemptAt)
    else
        previous.lastAttemptAt = now
        local ok, applied, reason = writer(turbine, proposed)
        if ok then
            previous.lastAppliedAt = now
            previous.lastAppliedFlow = tonumber(applied) or proposed
            previous.lastError = nil
            plan.actuatorState = "APPLIED"
            plan.appliedFlow = previous.lastAppliedFlow
        else
            previous.lastError = tostring(reason or "Turbine rejected the flow limit")
            plan.actuatorState = "FAULT"
            plan.actuatorError = previous.lastError
            plan.reportedFlow = tonumber(applied)
        end
    end

    plan.lastAppliedAt = previous.lastAppliedAt
    plan.lastAppliedFlow = previous.lastAppliedFlow
    memory.turbines[name] = previous
    return plan
end

function governor.applyAll(memory, turbines, control, context, writer)
    for _, turbine in ipairs(turbines or {}) do
        governor.apply(memory, turbine, control, context, writer)
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
