local governor = {}

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function round(value)
    return math.floor(value + 0.5)
end

local function hasConflict(context)
    local wanted = tonumber(context and context.mainframeId)
    for _, id in ipairs((context and context.idConflicts) or {}) do
        if tonumber(id) == wanted then return true end
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
        actuatorState = "HOLD",
    }
end

function governor.new()
    return { reactors = {} }
end

function governor.steamDemand(turbines)
    if #(turbines or {}) == 0 then
        return nil, 0, "No turbine telemetry is available"
    end
    local total, active = 0, 0
    for _, turbine in ipairs(turbines or {}) do
        if turbine.active == true then
            if turbine.error then
                return nil, active, "Active turbine telemetry is unavailable"
            end
            if turbine.governor and turbine.governor.trusted == false then
                return nil, active, "Active turbine telemetry is untrusted"
            end
            local requested = tonumber(turbine.flowRateMax)
            if requested == nil then
                return nil, active, "Active turbine intake setting is unavailable"
            end
            total, active = total + math.max(0, requested), active + 1
        end
    end
    return total, active
end

function governor.evaluate(memory, reactor, control, context, targetSteam, activeTurbines)
    memory.reactors = memory.reactors or {}
    control, context = control or {}, context or {}
    local name = tostring(reactor and reactor.name or "unknown")
    local previous = memory.reactors[name] or {}
    local result

    if type(reactor) ~= "table" then
        result = hold("NO REACTOR", "Reactor telemetry is unavailable", false)
    elseif hasConflict(context) then
        result = hold("ID CONFLICT", "Mainframe identity is not unique", false)
    elseif reactor.error then
        result = hold("NO TRUSTED DATA", tostring(reactor.error), false)
    elseif reactor.active ~= true then
        result = hold("INACTIVE", "Reactor is not active", false)
    elseif reactor.mode ~= "steam" then
        result = hold("NOT STEAM MODE", "Only actively cooled reactors are managed", false)
    elseif tonumber(reactor.steamProduction) == nil then
        result = hold("NO STEAM DATA", "Steam-production telemetry is unavailable", false)
    elseif tonumber(reactor.controlRodLevel) == nil then
        result = hold("NO ROD DATA", "Control-rod telemetry is unavailable", false)
    elseif tonumber(reactor.controlRodMinimum) and tonumber(reactor.controlRodMaximum) and
           tonumber(reactor.controlRodMinimum) ~= tonumber(reactor.controlRodMaximum) then
        result = hold("RODS NOT UNIFORM",
            "Automatic all-rod control requires equal starting levels", false)
    elseif tonumber(targetSteam) == nil then
        result = hold("NO TRUSTED DEMAND", tostring(context.demandError or
            "Turbine steam demand is unavailable"), false)
    else
        local production = math.max(0, tonumber(reactor.steamProduction))
        local target = math.max(0, tonumber(targetSteam))
        local current = clamp(tonumber(reactor.controlRodLevel), 0, 100)
        local maxStep = math.max(1, math.min(10,
            tonumber(control.maxRodStep) or 5))
        local deadband = math.max(tonumber(control.reactorSteamDeadbandMin) or 25,
            target * (tonumber(control.reactorSteamDeadband) or 0.03))
        local highBuffer = tonumber(control.reactorHotFluidHigh) or 85
        local hotFluid = tonumber(reactor.hotFluidPercent)
        local proposed, state, action, reason = current, "STABLE", "HOLD",
            "Steam production matches trusted turbine demand"

        if hotFluid and hotFluid >= highBuffer then
            if current >= 100 then
                state, action = "STEAM SURPLUS", "HOLD"
                reason = ("Hot-fluid buffer is %.1f%% with rods fully inserted"):format(
                    hotFluid)
            else
                proposed = current + maxStep
                state, action = "BUFFER HIGH", "INSERT RODS"
                reason = ("Hot-fluid buffer is %.1f%%; reduce steam production"):format(
                    hotFluid)
            end
        elseif target <= 0 then
            if current < 100 then
                proposed = current + maxStep
                state, action = "NO DEMAND", "INSERT RODS"
                reason = "No active turbine is requesting steam"
            else
                state, reason = "IDLE", "No active turbine demand; rods fully inserted"
            end
        else
            local errorAmount = target - production
            if math.abs(errorAmount) > deadband then
                local scale = clamp(math.abs(errorAmount) / math.max(target, 1),
                    1 / maxStep, 1)
                local step = math.max(1, round(maxStep * scale))
                if errorAmount > 0 then
                    if current <= 0 then
                        state, action = "STEAM DEFICIT", "HOLD"
                        reason = "Reactor cannot meet turbine demand with rods fully withdrawn"
                    else
                        proposed = current - step
                        state, action = "STEAM LOW", "WITHDRAW RODS"
                        reason = "Steam production is below trusted turbine demand"
                    end
                else
                    if current >= 100 then
                        state, action = "STEAM SURPLUS", "HOLD"
                        reason = "Reactor exceeds demand with rods fully inserted"
                    else
                        proposed = current + step
                        state, action = "STEAM HIGH", "INSERT RODS"
                        reason = "Steam production exceeds trusted turbine demand"
                    end
                end
            end
        end

        proposed = round(clamp(proposed, 0, 100))
        local changing = proposed ~= round(current)
        if changing then
            previous.actionSamples = previous.action == action and
                ((previous.actionSamples or 0) + 1) or 1
            previous.action = action
        else
            previous.actionSamples, previous.action = 0, nil
        end

        result = {
            mode = "automatic",
            state = state,
            action = action,
            reason = reason,
            trusted = true,
            activeTurbines = activeTurbines or 0,
            targetSteam = target,
            steamProduction = production,
            steamError = target - production,
            steamDeadband = deadband,
            currentRodLevel = current,
            recommendedRodLevel = proposed,
            rodChange = proposed - current,
            actionSamples = previous.actionSamples,
            hotFluidPercent = hotFluid,
        }
    end

    if result.trusted == false or result.action == "HOLD" then
        previous.actionSamples, previous.action = 0, nil
    end
    memory.reactors[name] = previous
    return result
end

function governor.evaluateAll(memory, reactors, turbines, control, context)
    local demand, activeTurbines, demandError = governor.steamDemand(turbines)
    local activeReactors = 0
    for _, reactor in ipairs(reactors or {}) do
        if reactor.active == true and reactor.mode == "steam" and not reactor.error then
            activeReactors = activeReactors + 1
        end
    end
    if activeReactors > 1 then
        demand = nil
        demandError = "Multiple active steam reactors require routing assignments"
    end
    local target = demand
    local present = {}
    for _, reactor in ipairs(reactors or {}) do
        present[tostring(reactor.name)] = true
        local reactorContext = {}
        for key, value in pairs(context or {}) do reactorContext[key] = value end
        reactorContext.demandError = demandError
        reactor.governor = governor.evaluate(memory, reactor, control, reactorContext,
            target, activeTurbines)
    end
    for name in pairs(memory.reactors or {}) do
        if not present[name] then memory.reactors[name] = nil end
    end
    return reactors
end

function governor.apply(memory, reactor, control, context, writers)
    control, context = control or {}, context or {}
    local plan = reactor and reactor.governor
    if not plan then return nil end
    local name = tostring(reactor.name or "unknown")
    local previous = memory.reactors[name] or {}
    local now = tonumber(context.now) or 0
    local interval = math.max(2, tonumber(control.reactorAdjustmentInterval) or 5)
    local samples = math.max(2, math.floor(tonumber(control.reactorCommandSamples) or 3))
    local current, proposed = tonumber(plan.currentRodLevel),
        tonumber(plan.recommendedRodLevel)
    local needsWrite = current ~= nil and proposed ~= nil and
        round(current) ~= round(proposed)

    if control.actuatorsEnabled ~= true then
        plan.actuatorState = "DISABLED"
        previous.actionSamples, previous.action = 0, nil
    elseif context.maintenance then
        plan.actuatorState = "PAUSED"
        previous.actionSamples, previous.action = 0, nil
    elseif plan.trusted == false then
        plan.actuatorState = "UNTRUSTED"
        previous.actionSamples, previous.action = 0, nil
    elseif not needsWrite then
        plan.actuatorState = "HOLD"
    elseif (tonumber(plan.actionSamples) or 0) < samples then
        plan.actuatorState = "VERIFYING"
    elseif type(writers) ~= "table" or
           type(writers.setAllControlRodLevels) ~= "function" then
        plan.actuatorState = "FAULT"
        plan.actuatorError = "Required reactor write adapter is unavailable"
    elseif previous.lastAttemptAt and now - previous.lastAttemptAt < interval then
        plan.actuatorState = previous.lastError and "FAULT" or "WAITING"
        plan.actuatorError = previous.lastError
        plan.nextAdjustmentIn = interval - (now - previous.lastAttemptAt)
    else
        previous.lastAttemptAt = now
        local ok, applied, reason = writers.setAllControlRodLevels(reactor, proposed)
        if ok then
            previous.lastAppliedAt = now
            previous.lastAppliedRodLevel = tonumber(applied) or proposed
            previous.lastError = nil
            plan.appliedRodLevel = previous.lastAppliedRodLevel
            plan.actuatorState = "APPLIED"
        else
            previous.lastError = tostring(reason or "Reactor rejected the rod command")
            plan.reportedRodLevel = tonumber(applied)
            plan.actuatorError = previous.lastError
            plan.actuatorState = "FAULT"
        end
    end

    plan.lastAppliedAt = previous.lastAppliedAt
    plan.lastAppliedRodLevel = previous.lastAppliedRodLevel
    memory.reactors[name] = previous
    return plan
end

function governor.applyAll(memory, reactors, control, context, writers)
    for _, reactor in ipairs(reactors or {}) do
        governor.apply(memory, reactor, control, context, writers)
    end
    return reactors
end

return governor
