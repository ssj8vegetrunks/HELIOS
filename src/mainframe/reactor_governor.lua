local governor = {}
local clearCooldown
local saveProfile

-- @section COMMON FUNCTIONS
local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

local function round(value, places)
    local scale = 10 ^ (places or 0)
    return math.floor(value * scale + 0.5) / scale
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

local function rodExposure(reactor)
    local count = math.floor(tonumber(reactor and reactor.controlRods) or 0)
    local levels = reactor and reactor.controlRodLevels
    if count < 1 or type(levels) ~= "table" then return nil, count end
    local exposure = 0
    for index = 0, count - 1 do
        local level = tonumber(levels[index])
        if level == nil then return nil, count end
        exposure = exposure + (100 - clamp(level, 0, 100)) / 100
    end
    return exposure, count
end

local function wantedRodLevel(index, exposure, count)
    local exposurePoints = math.floor(clamp(exposure, 0, count) * 100 + 0.5)
    local pointsPerRod = math.floor(exposurePoints / count)
    local remainder = exposurePoints % count
    local exposedPercent = pointsPerRod + (index < remainder and 1 or 0)
    return 100 - exposedPercent
end

local function layoutIsBalanced(reactor, exposure, count)
    local levels = reactor.controlRodLevels or {}
    for index = 0, count - 1 do
        local actual = tonumber(levels[index])
        if actual == nil or
           math.abs(actual - wantedRodLevel(index, exposure, count)) > 0.5 then
            return false
        end
    end
    return true
end

local function rollingSteam(previous, production, control)
    local wanted = math.max(3,
        math.floor(tonumber(control.reactorSteamAverageSamples) or 10))
    previous.productionSamples = previous.productionSamples or {}
    local samples = previous.productionSamples
    samples[#samples + 1] = production
    while #samples > wanted do table.remove(samples, 1) end
    local total, minimum, maximum = 0, nil, nil
    for _, sample in ipairs(samples) do
        total = total + sample
        minimum = minimum and math.min(minimum, sample) or sample
        maximum = maximum and math.max(maximum, sample) or sample
    end
    return total / #samples, #samples, #samples >= wanted, minimum, maximum
end

function governor.new()
    return { reactors = {}, profileDirty = false }
end

-- @section CALIBRATION PROFILE STORAGE
function governor.consumeProfileChanges(memory)
    local dirty = memory and memory.profileDirty == true
    if memory then memory.profileDirty = false end
    return dirty
end

local function clearTransient(previous)
    previous.productionSamples = {}
    previous.stableSamples = 0
    previous.processStableSamples = 0
    previous.actionSamples = 0
    previous.action = nil
    previous.observation = nil
    previous.points = {}
    previous.observedRodExposure = nil
    previous.lastAttemptAt = nil
    previous.lastError = nil
    previous.turbineBufferPercent = nil
    previous.bufferRecoverySamples = 0
    previous.bufferExposureFloor = nil
    previous.bufferExposureDemand = nil
    previous.settleStartedAt = nil
    clearCooldown(previous)
end

function governor.deleteCalibration(memory, control, name)
    name = tostring(name or "unknown")
    control.reactorProfiles = control.reactorProfiles or {}
    control.reactorProfiles[name] = nil
    memory.reactors = memory.reactors or {}
    local previous = memory.reactors[name] or {}
    previous.recalibrating = false
    previous.calibrationPhase = nil
    previous.previousProfile = nil
    clearTransient(previous)
    memory.reactors[name] = previous
    memory.profileDirty = true
    return true
end

function governor.beginRecalibration(memory, control, name)
    name = tostring(name or "unknown")
    control.reactorProfiles = control.reactorProfiles or {}
    memory.reactors = memory.reactors or {}
    local previous = memory.reactors[name] or {}
    previous.previousProfile = control.reactorProfiles[name]
    control.reactorProfiles[name] = nil
    clearTransient(previous)
    previous.recalibrating = true
    previous.calibrationPhase = "BASELINE"
    memory.reactors[name] = previous
    memory.profileDirty = true
    return true
end

function governor.saveCurrentCalibration(memory, control, reactor, context)
    if type(reactor) ~= "table" or reactor.mode ~= "steam" then
        return false, "Only steam reactors can be calibrated"
    end
    local exposure = rodExposure(reactor)
    if exposure == nil then return false, "Control-rod telemetry is unavailable" end
    local plan = reactor.governor or {}
    local production = tonumber(plan.averageSteamProduction) or
        tonumber(reactor.steamProduction)
    local target = tonumber(plan.targetSteam)
    if production == nil then return false, "Steam-production telemetry is unavailable" end
    if target == nil or target <= 0 then return false, "No turbine steam target is available" end
    saveProfile(memory, control, tostring(reactor.name), exposure, production,
        target, context or {})
    local previous = memory.reactors[tostring(reactor.name)] or {}
    previous.recalibrating = false
    previous.calibrationPhase = nil
    previous.previousProfile = nil
    clearTransient(previous)
    previous.observedRodExposure = exposure
    memory.reactors[tostring(reactor.name)] = previous
    return true
end

-- @section STEAM DEMAND AND SOURCE STATUS
function governor.steamDemand(turbines, control)
    if #(turbines or {}) == 0 then
        return nil, 0, "No turbine telemetry is available"
    end
    control = control or {}
    local total, active = 0, 0
    for _, turbine in ipairs(turbines or {}) do
        if turbine.active == true then
            if turbine.error then
                return nil, active, "Active turbine telemetry is unavailable"
            end
            if turbine.governor and turbine.governor.trusted == false then
                return nil, active, "Active turbine telemetry is untrusted"
            end
            local profile = (control.turbineProfiles or {})[tostring(turbine.name)]
            local requested = profile and tonumber(profile.flowLimit) or
                tonumber(turbine.flowRateLimit) or tonumber(turbine.flowRateMax)
            if requested == nil then
                return nil, active, "Active turbine intake setting is unavailable"
            end
            total, active = total + math.max(0, requested), active + 1
        end
    end
    return total, active
end

function governor.steamSourceStatus(reactors, demand, control)
    local sources = {}
    for _, reactor in ipairs(reactors or {}) do
        if reactor.mode == "steam" and not reactor.error then
            sources[#sources + 1] = reactor
        end
    end
    if #sources == 0 then
        return { managed = false, ready = true, state = "UNMANAGED" }
    elseif #sources > 1 then
        return {
            managed = true,
            ready = false,
            state = "ROUTING REQUIRED",
            reason = "Multiple steam reactors require routing assignments",
        }
    end

    local reactor = sources[1]
    local plan = reactor.governor or {}
    local required = math.max(0, tonumber(demand) or 0)
    local production = tonumber(plan.averageSteamProduction)
    local samples = tonumber(plan.averageSteamSamples) or 0
    local wantedSamples = math.max(3,
        math.floor(tonumber((control or {}).reactorSteamAverageSamples) or 10))
    local ratio = clamp(tonumber((control or {}).calibrationSteamRatio) or 0.98,
        0.1, 1)
    local ready = required <= 0 or (
        reactor.active == true and plan.trusted ~= false and
        production ~= nil and samples >= wantedSamples and
        production >= required * ratio)
    local reason
    if reactor.active ~= true then
        reason = "Starting steam reactor"
    elseif plan.trusted == false then
        reason = tostring(plan.reason or "Steam reactor telemetry is untrusted")
    elseif samples < wantedSamples then
        reason = ("Averaging reactor steam %d/%d"):format(samples, wantedSamples)
    elseif production == nil then
        reason = "Waiting for reactor steam telemetry"
    elseif not ready then
        reason = ("Reactor supplying %.0f of %.0f mB/t"):format(production, required)
    else
        reason = ("Reactor supplying %.0f mB/t for %.0f mB/t demand"):format(
            production, required)
    end
    return {
        managed = true,
        ready = ready,
        state = ready and "READY" or "PREPARING",
        reason = reason,
        reactor = reactor.name,
        demand = required,
        production = production,
        bufferPercent = tonumber(reactor.hotFluidPercent),
    }
end

clearCooldown = function(previous)
    previous.cooldownStartedAt = nil
    previous.cooldownReferenceAt = nil
    previous.cooldownReferenceSteam = nil
    previous.cooldownReferenceTemperature = nil
    previous.cooldownLastProgressAt = nil
end

-- @section LEARNING AND RESPONSE LOGIC
local function observeCooldown(previous, reactor, control, context, production)
    local now = tonumber(context and context.now) or 0
    local casingTemperature = tonumber(reactor and reactor.casingTemperature)
    local window = math.max(5, tonumber(control.reactorCooldownWindow) or 10)
    local timeout = math.max(60, tonumber(control.reactorCooldownStallTimeout) or 180)
    local steamDelta = math.max(0.1, tonumber(control.reactorCooldownSteamDelta) or 2)
    local temperatureDelta = math.max(0.01,
        tonumber(control.reactorCooldownTemperatureDelta) or 0.05)

    if previous.cooldownStartedAt == nil then
        previous.cooldownStartedAt = now
        previous.cooldownReferenceAt = now
        previous.cooldownReferenceSteam = production
        previous.cooldownReferenceTemperature = casingTemperature
        previous.cooldownLastProgressAt = now
    elseif now - (previous.cooldownReferenceAt or now) >= window then
        local steamFalling = previous.cooldownReferenceSteam ~= nil and
            production <= previous.cooldownReferenceSteam - steamDelta
        local temperatureFalling = casingTemperature ~= nil and
            previous.cooldownReferenceTemperature ~= nil and
            casingTemperature <= previous.cooldownReferenceTemperature - temperatureDelta
        if steamFalling or temperatureFalling then previous.cooldownLastProgressAt = now end
        previous.cooldownReferenceAt = now
        previous.cooldownReferenceSteam = production
        previous.cooldownReferenceTemperature = casingTemperature
    end
    local stalledFor = math.max(0, now - (previous.cooldownLastProgressAt or now))
    return stalledFor < timeout, stalledFor, casingTemperature
end

local function observeResponse(previous, reactor, control, context, production,
                               productionLow, productionHigh, sampleCount, target)
    local now = tonumber(context and context.now) or 0
    local temperature = tonumber(reactor.casingTemperature)
    local prior = previous.observation
    local absoluteDelta = math.max(1,
        tonumber(control.reactorLearningSteamDelta) or 10)
    local tolerance = math.max(0.005, math.min(0.25,
        tonumber(control.reactorLearningSteamTolerance) or 0.05))
    local productionRange = math.max(0,
        (tonumber(productionHigh) or production) -
        (tonumber(productionLow) or production))
    -- Replacing one sample in a rolling average can move the mean by as much
    -- as one observed range divided by the window size. Treat that movement
    -- as the reactor's normal operating band, not as a fresh transient.
    local steamDelta = math.max(absoluteDelta,
        math.abs(tonumber(target) or production) * tolerance,
        productionRange / math.max(1, tonumber(sampleCount) or 1))
    local temperatureDelta = math.max(0.01,
        tonumber(control.reactorLearningTemperatureDelta) or 0.1)
    local minimumResponse = math.max(5,
        tonumber(control.reactorMinimumResponseTime) or 15)
    local settleTimeout = math.max(minimumResponse + 5,
        tonumber(control.reactorSettleTimeout) or 90)
    local processMoving, temperatureMoving = false, false

    if prior then
        processMoving = math.abs(production - prior.production) > steamDelta
        if temperature and prior.temperature then
            temperatureMoving =
                math.abs(temperature - prior.temperature) > temperatureDelta
        end
    end
    local waiting = previous.lastAppliedAt and now - previous.lastAppliedAt < minimumResponse
    if previous.settleStartedAt == nil then
        previous.settleStartedAt = tonumber(previous.lastAppliedAt) or now
    end
    local settleAge = math.max(0, now - previous.settleStartedAt)
    local settleTimedOut = not waiting and settleAge >= settleTimeout
    if not prior or processMoving or waiting then
        previous.processStableSamples = 0
    else
        previous.processStableSamples = (previous.processStableSamples or 0) + 1
    end
    if not prior or processMoving or temperatureMoving or waiting then
        previous.stableSamples = 0
    else
        previous.stableSamples = (previous.stableSamples or 0) + 1
    end
    previous.observation = {
        at = now,
        production = production,
        temperature = temperature,
    }
    return not processMoving and not temperatureMoving and not waiting,
        processMoving or temperatureMoving or waiting, {
            waiting = waiting == true,
            processMoving = processMoving,
            temperatureMoving = temperatureMoving,
            steamTolerance = steamDelta,
            settleAge = settleAge,
            settleTimedOut = settleTimedOut,
        }
end

local function addLearningPoint(previous, exposure, production)
    previous.points = previous.points or {}
    for _, point in ipairs(previous.points) do
        if math.abs(point.exposure - exposure) < 0.05 then
            point.exposure, point.steam = exposure, production
            return
        end
    end
    previous.points[#previous.points + 1] = { exposure = exposure, steam = production }
    while #previous.points > 4 do table.remove(previous.points, 1) end
end

local function learnedExposure(previous, profile, current, production, target, count)
    local points = previous.points or {}
    if #points >= 2 then
        local first, second = points[#points - 1], points[#points]
        local steamChange = second.steam - first.steam
        if math.abs(steamChange) >= math.max(10, target * 0.01) then
            return clamp(first.exposure +
                (target - first.steam) * (second.exposure - first.exposure) /
                    steamChange, 0, count)
        end
    end
    if production > 1 and current > 0 then
        return clamp(current * target / production, 0, count)
    end
    if type(profile) == "table" and tonumber(profile.exposure) and
       tonumber(profile.targetSteam) and tonumber(profile.targetSteam) > 0 then
        return clamp(tonumber(profile.exposure) * target /
            tonumber(profile.targetSteam), 0, count)
    end
    return clamp(current + 0.25, 0, count)
end

saveProfile = function(memory, control, name, exposure, production, target, context,
                       productionLow, productionHigh)
    control.reactorProfiles = control.reactorProfiles or {}
    local old = control.reactorProfiles[name]
    if not old or math.abs((tonumber(old.exposure) or -1) - exposure) >= 0.01 or
       math.abs((tonumber(old.targetSteam) or -1) - target) >= 1 then
        control.reactorProfiles[name] = {
            exposure = round(exposure, 2),
            steam = round(production, 1),
            steamLow = round(tonumber(productionLow) or production, 1),
            steamHigh = round(tonumber(productionHigh) or production, 1),
            targetSteam = round(target, 1),
            updatedAt = tonumber(context and context.now) or 0,
            bufferExposure = old and old.bufferExposure or nil,
            bufferDemand = old and old.bufferDemand or nil,
            bufferSteam = old and old.bufferSteam or nil,
            bufferUpdatedAt = old and old.bufferUpdatedAt or nil,
            learnedMaximumSteam = old and old.learnedMaximumSteam or nil,
        }
        memory.profileDirty = true
    end
end

local function saveBufferDefault(memory, control, name, exposure, production,
                                 target, requested, context, productionLow,
                                 productionHigh)
    control.reactorProfiles = control.reactorProfiles or {}
    local profile = control.reactorProfiles[name]
    if type(profile) ~= "table" then return profile, false end
    local roundedExposure = round(exposure, 2)
    local roundedDemand = round(requested, 1)
    local changed = math.abs((tonumber(profile.bufferExposure) or -1) -
        roundedExposure) >= 0.01 or
        math.abs((tonumber(profile.bufferDemand) or -1) - roundedDemand) >= 1
    if changed then
        local now = tonumber(context and context.now) or 0
        profile.exposure = roundedExposure
        profile.steam = round(production, 1)
        profile.steamLow = round(tonumber(productionLow) or production, 1)
        profile.steamHigh = round(tonumber(productionHigh) or production, 1)
        profile.targetSteam = round(target, 1)
        profile.updatedAt = now
        profile.bufferExposure = roundedExposure
        profile.bufferDemand = roundedDemand
        profile.bufferSteam = round(production, 1)
        profile.bufferUpdatedAt = now
        memory.profileDirty = true
    end
    return profile, changed
end

-- @section REACTOR GOVERNOR
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
    elseif reactor.mode == "power" then
        result = hold("MONITOR ONLY", "Power reactor is excluded from steam control")
        result.managed = false
        result.actuatorState = "MONITOR"
    elseif reactor.mode ~= "steam" then
        result = hold("UNKNOWN MODE", "Reactor cooling mode is unavailable", false)
    elseif tonumber(targetSteam) == nil then
        result = hold("NO TRUSTED DEMAND", tostring(context.demandError or
            "Turbine steam demand is unavailable"), false)
    elseif reactor.active == false then
        local requested = math.max(0, tonumber(targetSteam) or 0)
        local reserve = math.max(0, math.min(0.25,
            tonumber(control.reactorSteamReserveMargin) or 0.15))
        if requested > 0 then
            result = {
                mode = "automatic",
                state = "STARTING",
                action = "START REACTOR",
                reason = "Turbine demand requires the steam reactor online",
                trusted = true,
                managed = true,
                currentActive = false,
                recommendedActive = true,
                activeChange = true,
                requestedSteam = requested,
                targetSteam = requested * (1 + reserve),
                activeTurbines = activeTurbines or 0,
            }
        else
            result = hold("OFFLINE", "No turbine demand requires this reactor")
            result.managed = true
        end
    elseif reactor.active ~= true then
        result = hold("NO STATE DATA", "Reactor active-state telemetry is unavailable", false)
    elseif tonumber(reactor.steamProduction) == nil then
        result = hold("NO STEAM DATA", "Steam-production telemetry is unavailable", false)
    else
        local exposure, rodCount = rodExposure(reactor)
        if exposure == nil then
            result = hold("NO ROD DATA",
                "Individual control-rod telemetry is unavailable", false)
        else
            local rawProduction = math.max(0, tonumber(reactor.steamProduction))
            -- Rod changes made outside HELIOS do not pass through apply(), so they
            -- must invalidate the same observations as a governor command. Mixing
            -- samples from two layouts can hide a real steam deficit.
            if previous.observedRodExposure ~= nil and
               math.abs(exposure - previous.observedRodExposure) >= 0.005 then
                previous.productionSamples = {}
                previous.stableSamples = 0
                previous.processStableSamples = 0
                previous.observation = nil
                previous.settleStartedAt = nil
                clearCooldown(previous)
            end
            previous.observedRodExposure = exposure
            local production, averageSamples, averageReady, productionLow,
                productionHigh = rollingSteam(previous, rawProduction, control)
            local requestedSteam = math.max(0, tonumber(targetSteam))
            local reserveMargin = math.max(0, math.min(0.25,
                tonumber(control.reactorSteamReserveMargin) or 0.15))
            local normalTarget = requestedSteam > 0 and
                requestedSteam * (1 + reserveMargin) or 0
            local profile = (control.reactorProfiles or {})[name]
            local primeRequested = context.steamPrimeRequested == true and
                type(profile) == "table" and previous.recalibrating ~= true
            local primeMargin = math.max(reserveMargin, math.min(2,
                tonumber(control.reactorSteamPrimeMargin) or 0.90))
            local target = primeRequested and
                math.max(normalTarget, requestedSteam * (1 + primeMargin)) or
                normalTarget
            local hotFluid = tonumber(reactor.hotFluidPercent)
            local lowBuffer = tonumber(control.reactorHotFluidLow) or 15
            local deadband = math.max(tonumber(control.reactorSteamDeadbandMin) or 25,
                target * (tonumber(control.reactorSteamDeadband) or 0.01))
            local maxStep = math.max(0.01, math.min(1,
                tonumber(control.maxRodEquivalentStep) or 0.25))
            local stableRequired = math.max(3,
                math.floor(tonumber(control.reactorLearningSamples) or 8))
            -- Calibration advances through a durable, forward-only phase. The
            -- old recalibrating boolean could not distinguish a completed
            -- baseline from one still being collected, so every positive test
            -- exposure was mistaken for a reason to close the rods again.
            if previous.calibrationPhase == "TESTING" and exposure > 0.005 then
                previous.calibrationPhase = "ADJUSTING"
            end
            local calibrationPhase = previous.calibrationPhase
            local calibrationTemperature = tonumber(reactor.casingTemperature)
            local calibrationMaxTemperature = math.max(50,
                tonumber(control.reactorCalibrationMaxTemperature) or 150)
            local baselineSteamLimit = deadband
            local needsFreshBaseline = exposure <= 0.005 and
                (calibrationPhase == "BASELINE" or
                    (calibrationPhase == nil and type(profile) ~= "table"))
            local _, responding, response = observeResponse(previous, reactor, control,
                context, production, productionLow, productionHigh,
                averageSamples, target)
            -- Once calibration has produced a trusted operating point, project
            -- that measured steam-per-exposed-rod response to full exposure.
            -- This records plant capability without deliberately flooding the
            -- steam network with a separate full-output GUI test.
            if averageReady and type(profile) == "table" and rodCount > 0 and
               exposure >= 0.25 then
                local estimatedMaximum = math.max(productionHigh,
                    production / exposure * rodCount)
                local previousMaximum = tonumber(profile.learnedMaximumSteam) or 0
                if estimatedMaximum > previousMaximum * 1.01 then
                    profile.learnedMaximumSteam = round(estimatedMaximum, 1)
                    memory.profileDirty = true
                end
            end
            local stable = (previous.stableSamples or 0) >= stableRequired
            -- Steam is evaluated as a rolling operating band after the normal
            -- post-write delay. Casing drift remains diagnostic, and a bounded
            -- timeout guarantees that natural reactor pulsing cannot hold a
            -- calibration or ordinary demand adjustment forever.
            local processStable = averageReady and not response.waiting and (
                (previous.processStableSamples or 0) >= stableRequired or
                response.settleTimedOut)
            local turbineBuffer = tonumber(context.turbineBufferPercent)
            local turbineBufferReady = math.max(50, math.min(
                tonumber(control.reactorHotFluidHigh) or 85,
                tonumber(control.calibrationBufferReady) or 85))
            local bufferTelemetryReady =
                context.turbineBufferTelemetryComplete == true
            local firstCalibrationBufferFeedback =
                previous.recalibrating == true and
                calibrationPhase == "ADJUSTING" and averageReady and
                production >= target - deadband
            local bufferFeedbackEnabled = not primeRequested and
                (activeTurbines or 0) > 0 and bufferTelemetryReady and
                turbineBuffer ~= nil and (
                    (type(profile) == "table" and
                        previous.recalibrating ~= true) or
                    firstCalibrationBufferFeedback)
            if previous.bufferExposureFloor == nil and type(profile) == "table" and
               tonumber(profile.bufferExposure) ~= nil and
               tonumber(profile.bufferDemand) ~= nil and
               requestedSteam >= tonumber(profile.bufferDemand) - 1 then
                previous.bufferExposureFloor = tonumber(profile.bufferExposure)
                previous.bufferExposureDemand = tonumber(profile.bufferDemand)
            end
            -- The reactor hot-fluid buffer is authoritative for the complete
            -- steam network. A turbine buffer can remain full while the pipe
            -- network drains, but a recovering reactor buffer proves that total
            -- production is catching up with downstream demand.
            local reactorBufferLow = 80
            local reactorBufferReady = math.max(reactorBufferLow + 1,
                tonumber(control.reactorHotFluidHigh) or 85)
            local reactorBufferRecovering =
                previous.reactorBufferRecovering == true

            -- Hysteresis prevents recovery from ending as soon as the source
            -- buffer barely crosses the low threshold. Enter below 80% and
            -- remain latched until the reactor reaches the configured 85% goal.
            if bufferFeedbackEnabled and hotFluid ~= nil then
                if hotFluid < reactorBufferLow then
                    reactorBufferRecovering = true
                elseif hotFluid >= reactorBufferReady then
                    reactorBufferRecovering = false
                end
            else
                reactorBufferRecovering = false
            end
            previous.reactorBufferRecovering = reactorBufferRecovering

            local bufferBelowReady = bufferFeedbackEnabled and
                hotFluid ~= nil and reactorBufferRecovering
            local bufferFilling = false
            local bufferDelta = math.max(0.01,
                tonumber(control.reactorLearningBufferDelta) or 0.1)

            -- If the source buffer is flat or falling below 80%, the network is
            -- consuming stored steam faster than the reactor replaces it.
            if bufferBelowReady and not response.waiting then
                local priorBuffer = tonumber(previous.reactorBufferPercent)
                if priorBuffer ~= nil and
                   hotFluid >= priorBuffer + bufferDelta then
                    previous.bufferRecoverySamples = 0
                    bufferFilling = true
                else
                    previous.bufferRecoverySamples =
                        (previous.bufferRecoverySamples or 0) + 1
                end
            else
                previous.bufferRecoverySamples = 0
            end
            previous.reactorBufferPercent = hotFluid
            previous.turbineBufferPercent = turbineBuffer
            local bufferRecoveryRequired = bufferBelowReady and
                (previous.bufferRecoverySamples or 0) >= stableRequired

            -- A learned downstream-loss allowance must disappear when turbine
            -- demand falls, but it remains valid when another turbine is added.
            if previous.bufferExposureFloor ~= nil and
               previous.bufferExposureDemand ~= nil and
               requestedSteam < previous.bufferExposureDemand - 1 then
                previous.bufferExposureFloor = nil
                previous.bufferExposureDemand = nil
            end
            if type(profile) ~= "table" or target <= 0 then
                previous.bufferExposureFloor = nil
                previous.bufferExposureDemand = nil
            end
            local bufferDefaultSaved = false
            local exposureFloor = tonumber(previous.bufferExposureFloor)
            if exposureFloor ~= nil and bufferFeedbackEnabled and
               exposure >= exposureFloor - 0.005 and
               (bufferFilling or hotFluid >= reactorBufferReady) then
                profile, bufferDefaultSaved = saveBufferDefault(memory, control,
                    name, exposure, production, normalTarget, requestedSteam,
                    context, productionLow, productionHigh)
            end
            local firstCalibrationBufferSatisfied =
                firstCalibrationBufferFeedback and bufferFeedbackEnabled and
                not response.waiting and
                (bufferFilling or hotFluid >= reactorBufferReady)
            local calibrationCompleted = false
            local proposed, state, action, reason = exposure, "STABLE", "HOLD",
                "Steam production matches trusted turbine demand"
            local balanced = layoutIsBalanced(reactor, exposure, rodCount)

            if calibrationPhase == "BASELINE" and exposure > 0.005 then
                proposed = 0
                state, action = "RECALIBRATING", "REDUCE EXPOSURE"
                reason = "Insert every rod and establish a fresh zero-exposure baseline"
            elseif not balanced then
                proposed = 0
                state, action = "BASELINING", "REDUCE EXPOSURE"
                reason = "Insert every rod before switching to balanced exposure"
            elseif target <= 0 then
                if exposure > 0.005 then
                    proposed, state, action = 0, "NO DEMAND", "REDUCE EXPOSURE"
                    reason = "No active turbine is requesting steam"
                else
                    state, reason = "IDLE", "No active turbine demand; all rods inserted"
                end
            elseif needsFreshBaseline and not averageReady then
                previous.stableSamples = 0
                state = "AVERAGING"
                reason = ("Collecting zero-exposure steam sample %d/%d"):
                    format(averageSamples,
                        math.max(3, math.floor(tonumber(
                            control.reactorSteamAverageSamples) or 10)))
            elseif needsFreshBaseline and production > baselineSteamLimit then
                local cooling, stalledFor, temperature = observeCooldown(previous,
                    reactor, control, context, production)
                if cooling then
                    state = "COOLING"
                    reason = temperature and
                        ("Residual steam %.0f mB/t; waiting below %.0f (case %.1f C)"):
                            format(production, baselineSteamLimit, temperature) or
                        ("Residual steam %.0f mB/t; waiting below %.0f"):
                            format(production, baselineSteamLimit)
                else
                    state = "STEAM SURPLUS"
                    reason = ("Steam and casing temperature have not declined for %.0f seconds"):
                        format(stalledFor)
                end
            elseif needsFreshBaseline and hotFluid ~= nil and
                   hotFluid > lowBuffer then
                state = "COOLING"
                reason = ("Hot-fluid buffer is %.1f%%; waiting below %.1f%%"):
                    format(hotFluid, lowBuffer)
            elseif needsFreshBaseline and calibrationTemperature ~= nil and
                   calibrationTemperature > calibrationMaxTemperature then
                state = "COOLING"
                reason = ("Casing is %.1f C; calibration begins below %.1f C"):
                    format(calibrationTemperature, calibrationMaxTemperature)
            elseif needsFreshBaseline then
                clearCooldown(previous)
                addLearningPoint(previous, exposure, production)
                previous.calibrationPhase = "TESTING"
                proposed = math.min(maxStep, rodCount)
                state, action = "RECALIBRATING", "INCREASE EXPOSURE"
                reason = ("Zero-exposure baseline ready at %.0f mB/t; begin learning"):
                    format(production)
            elseif calibrationPhase == "TESTING" and exposure <= 0.005 then
                -- Keep proposing the first bounded test until the three-reading
                -- actuator confirmation succeeds. Do not fall back into baseline.
                proposed = math.min(maxStep, rodCount)
                state, action = "RECALIBRATING", "INCREASE EXPOSURE"
                reason = ("Baseline complete; testing %.2f rod-equivalents"):
                    format(proposed)
            elseif not averageReady then
                previous.stableSamples = 0
                state = "AVERAGING"
                reason = ("Collecting steam sample %d/%d"):
                    format(averageSamples,
                        math.max(3, math.floor(tonumber(
                            control.reactorSteamAverageSamples) or 10)))
            elseif firstCalibrationBufferSatisfied then
                -- The downstream system has now proven this exposure. A large
                -- reactor may never report a flat instantaneous output, so the
                -- first rising turbine buffer completes calibration and saves
                -- the measured production band as the operating profile.
                clearCooldown(previous)
                addLearningPoint(previous, exposure, production)
                saveProfile(memory, control, name, exposure, production,
                    normalTarget, context, productionLow, productionHigh)
                profile = (control.reactorProfiles or {})[name]
                profile, bufferDefaultSaved = saveBufferDefault(memory, control,
                    name, exposure, production, normalTarget, requestedSteam,
                    context, productionLow, productionHigh)
                previous.bufferExposureFloor = exposure
                previous.bufferExposureDemand = requestedSteam
                previous.recalibrating = false
                previous.calibrationPhase = nil
                previous.previousProfile = nil
                calibrationCompleted = true
                state = "LEARNED"
                reason = bufferFilling and
                    ("Turbine buffer is climbing at %.1f%%; saved %.0f-%.0f mB/t range"):
                        format(turbineBuffer, productionLow, productionHigh) or
                    ("Turbine buffer reached %.1f%%; saved %.0f-%.0f mB/t range"):
                        format(turbineBuffer, productionLow, productionHigh)
            elseif exposure <= 0.005 and production < requestedSteam - deadband and
                   type(profile) == "table" and tonumber(profile.exposure) and
                   tonumber(profile.exposure) > 0 then
                local estimate = learnedExposure(previous, profile, exposure,
                    production, target, rodCount)
                proposed = math.min(maxStep, math.max(0.01, estimate))
                state, action = "RECOVERING", "INCREASE EXPOSURE"
                reason = ("Steam is below demand; restore learned %.2f rod-equivalents"):
                    format(tonumber(profile.exposure))
            elseif bufferRecoveryRequired then
                if exposure >= rodCount - 0.005 then
                    state = "STEAM DEFICIT"
                    reason = ("Turbine buffer remains at %.1f%% with every rod exposed"):
                        format(turbineBuffer)
                else
                    proposed = math.min(exposure + maxStep, rodCount)
                    state, action = "BUFFER RECOVERY", "INCREASE EXPOSURE"
                    reason = ("Reactor steam buffer stalled at %.1f%%; increase reactor output"):
                        format(hotFluid)
                end
            elseif (responding or not stable) and not processStable then
                state = "RESPONDING"
                reason = response.waiting and
                    "Waiting for the post-adjustment steam response" or
                    ("Learning normal output range %.0f-%.0f mB/t"):
                        format(productionLow, productionHigh)
            else
                clearCooldown(previous)
                -- Once telemetry has settled, a full buffer is a valid operating
                -- condition. The steam loop exhausts overflow, so active demand
                -- must retain its reserve instead of draining the network again.
                addLearningPoint(previous, exposure, production)

                if production < target - deadband then
                    if exposure >= rodCount - 0.005 then
                        state = "STEAM DEFICIT"
                        reason = "Reactor cannot meet turbine demand with every rod exposed"
                    else
                        local estimate = learnedExposure(previous, profile, exposure,
                            production, target, rodCount)
                        proposed = math.min(exposure + maxStep,
                            math.max(exposure + 0.01, estimate))
                        state, action = "STEAM LOW", "INCREASE EXPOSURE"
                        reason = ("Formula estimate %.2f rod-equivalents; increase gradually"):
                            format(estimate)
                    end
                elseif bufferBelowReady then
                    state = "BUFFER FILLING"
                    reason = bufferDefaultSaved and
                        ("Reactor steam buffer is climbing at %.1f%%; saved reactor default"):
                            format(hotFluid) or bufferFilling and
                        ("Reactor steam buffer is filling at %.1f%%; hold reactor output"):
                            format(hotFluid) or
                        ("Reactor steam buffer is %.1f%%; observing recovery %d/%d"):
                            format(hotFluid,
                                previous.bufferRecoverySamples or 0,
                                stableRequired)
                elseif production > target + deadband then
                    local estimate = learnedExposure(previous, profile, exposure,
                        production, target, rodCount)
                    proposed = math.max(exposure - maxStep,
                        math.min(exposure - 0.01, estimate))
                    local exposureFloor = tonumber(previous.bufferExposureFloor)
                    if exposureFloor ~= nil then
                        proposed = math.max(proposed, exposureFloor)
                    end
                    if proposed < exposure - 0.005 then
                        state, action = "STEAM HIGH", "REDUCE EXPOSURE"
                        reason = ("Formula estimate %.2f rod-equivalents; reduce gradually"):
                            format(estimate)
                    else
                        proposed = exposure
                        state = "BUFFER RESERVE"
                        reason = ("Holding %.2f rod-equivalents learned from reactor buffer demand"):
                            format(exposureFloor or exposure)
                    end
                elseif primeRequested then
                    state = "PRIMING STEAM"
                    reason = ("Holding elevated %.0f mB/t output until steam buffers are ready"):
                        format(target)
                else
                    calibrationCompleted = previous.recalibrating == true
                    -- A drained hot-fluid buffer is normal when reactor output
                    -- closely matches live turbine demand. Stable production is
                    -- sufficient to learn the operating point; only the high
                    -- buffer branch above must prevent saving.
                    saveProfile(memory, control, name, exposure, production, target,
                        context, productionLow, productionHigh)
                    previous.recalibrating = false
                    previous.calibrationPhase = nil
                    previous.previousProfile = nil
                    state = "LEARNED"
                    reason = ("Holding %.2f exposed rod-equivalents for %.0f mB/t"):
                        format(exposure, target)
                end
            end

            proposed = round(clamp(proposed, 0, rodCount), 2)
            local changing = action ~= "HOLD" and
                (math.abs(proposed - exposure) >= 0.005 or not balanced)
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
                managed = true,
                activeTurbines = activeTurbines or 0,
                requestedSteam = requestedSteam,
                targetSteam = target,
                normalTargetSteam = normalTarget,
                steamPriming = primeRequested,
                steamProduction = rawProduction,
                averageSteamProduction = round(production, 1),
                steamProductionLow = round(productionLow, 1),
                steamProductionHigh = round(productionHigh, 1),
                averageSteamSamples = averageSamples,
                steamError = target - production,
                steamDeadband = deadband,
                rodCount = rodCount,
                currentRodExposure = round(exposure, 2),
                recommendedRodExposure = proposed,
                rodExposureChange = round(proposed - exposure, 2),
                actionSamples = previous.actionSamples,
                stableSamples = previous.stableSamples or 0,
                processStableSamples = previous.processStableSamples or 0,
                steamStabilityTolerance = round(response.steamTolerance, 1),
                settleAge = round(response.settleAge, 1),
                settleTimedOut = response.settleTimedOut == true,
                temperatureMoving = response.temperatureMoving == true,
                hotFluidPercent = hotFluid,
                turbineBufferPercent = turbineBuffer,
                turbineBufferReady = turbineBufferReady,
                turbineBufferFeedback = bufferFeedbackEnabled,
                bufferFilling = bufferFilling,
                bufferRecoverySamples = previous.bufferRecoverySamples or 0,
                bufferRecoveryRequested = state == "BUFFER RECOVERY" and
                    action == "INCREASE EXPOSURE",
                bufferExposureFloor = previous.bufferExposureFloor,
                bufferDefaultSaved = bufferDefaultSaved,
                learnedProfile = profile,
                recalibrating = previous.recalibrating == true,
                calibrationPhase = previous.calibrationPhase,
                calibrationCompleted = calibrationCompleted,
                coolingSince = previous.cooldownStartedAt,
                coolingLastProgressAt = previous.cooldownLastProgressAt,
            }
        end
    end

    if result.trusted == false or result.action == "HOLD" then
        previous.actionSamples, previous.action = 0, nil
    end
    memory.reactors[name] = previous
    return result
end

-- @section MULTI-REACTOR EVALUATION
function governor.evaluateAll(memory, reactors, turbines, control, context)
    local demand, activeTurbines, demandError = governor.steamDemand(turbines, control)
    local turbineBufferPercent, bufferReadings = nil, 0
    for _, turbine in ipairs(turbines or {}) do
        if turbine.active == true and not turbine.error and
           not (turbine.governor and turbine.governor.trusted == false) then
            local buffer = tonumber(turbine.inputPercent)
            if buffer ~= nil then
                turbineBufferPercent = turbineBufferPercent and
                    math.min(turbineBufferPercent, buffer) or buffer
                bufferReadings = bufferReadings + 1
            end
        end
    end
    local steamReactors = 0
    for _, reactor in ipairs(reactors or {}) do
        if reactor.mode == "steam" and not reactor.error then
            steamReactors = steamReactors + 1
        end
    end
    if steamReactors > 1 then
        demand = nil
        demandError = "Multiple steam reactors require routing assignments"
    end
    local present = {}
    for _, reactor in ipairs(reactors or {}) do
        present[tostring(reactor.name)] = true
        local reactorContext = {}
        for key, value in pairs(context or {}) do reactorContext[key] = value end
        reactorContext.demandError = demandError
        reactorContext.turbineBufferPercent = turbineBufferPercent
        reactorContext.turbineBufferTelemetryComplete = activeTurbines > 0 and
            bufferReadings == activeTurbines
        reactor.governor = governor.evaluate(memory, reactor, control, reactorContext,
            demand, activeTurbines)
    end
    for name in pairs(memory.reactors or {}) do
        if not present[name] then memory.reactors[name] = nil end
    end
    return reactors, demand, activeTurbines, demandError
end

-- @section ACTUATOR APPLICATION
function governor.apply(memory, reactor, control, context, writers)
    control, context = control or {}, context or {}
    local plan = reactor and reactor.governor
    if not plan then return nil end
    local name = tostring(reactor.name or "unknown")
    local previous = memory.reactors[name] or {}
    local now = tonumber(context.now) or 0
    local interval = math.max(2, tonumber(control.reactorAdjustmentInterval) or 5)
    local samples = math.max(2,
        math.floor(tonumber(control.reactorCommandSamples) or 3))
    local current, proposed = tonumber(plan.currentRodExposure),
        tonumber(plan.recommendedRodExposure)
    local needsWrite = current ~= nil and proposed ~= nil and
        math.abs(current - proposed) >= 0.005
    local needsActive = type(plan.recommendedActive) == "boolean" and
        plan.recommendedActive ~= reactor.active

    if control.actuatorsEnabled ~= true then
        plan.actuatorState = "DISABLED"
        previous.actionSamples, previous.action = 0, nil
    elseif context.maintenance then
        plan.actuatorState = "PAUSED"
        previous.actionSamples, previous.action = 0, nil
    elseif plan.managed == false then
        plan.actuatorState = "MONITOR"
    elseif plan.trusted == false then
        plan.actuatorState = "UNTRUSTED"
        previous.actionSamples, previous.action = 0, nil
    elseif not needsWrite and not needsActive then
        plan.actuatorState = "HOLD"
    elseif not needsActive and (tonumber(plan.actionSamples) or 0) < samples then
        plan.actuatorState = "VERIFYING"
    elseif type(writers) ~= "table" or
           (needsActive and type(writers.setActive) ~= "function") or
           (needsWrite and type(writers.setControlRodExposure) ~= "function") then
        plan.actuatorState = "FAULT"
        plan.actuatorError = needsActive and
            "Required reactor activation adapter is unavailable" or
            "Required individual control-rod adapter is unavailable"
    elseif previous.lastAttemptAt and now - previous.lastAttemptAt < interval then
        plan.actuatorState = previous.lastError and "FAULT" or "WAITING"
        plan.actuatorError = previous.lastError
        plan.nextAdjustmentIn = interval - (now - previous.lastAttemptAt)
    else
        previous.lastAttemptAt = now
        local ok, applied, reason
        if needsActive then
            ok, applied, reason = writers.setActive(reactor, plan.recommendedActive)
        else
            ok, applied, reason = writers.setControlRodExposure(reactor, proposed)
        end
        if ok then
            previous.lastAppliedAt = now
            previous.settleStartedAt = now
            if needsActive then
                previous.lastAppliedActive = applied == true
                plan.appliedActive = previous.lastAppliedActive
            else
                previous.lastAppliedRodExposure = tonumber(applied) or proposed
                plan.appliedRodExposure = previous.lastAppliedRodExposure
                if plan.bufferRecoveryRequested == true then
                    previous.bufferExposureFloor = previous.lastAppliedRodExposure
                    previous.bufferExposureDemand =
                        tonumber(plan.requestedSteam) or 0
                    plan.bufferExposureFloor = previous.bufferExposureFloor
                end
            end
            previous.lastError = nil
            previous.stableSamples = 0
            previous.processStableSamples = 0
            previous.productionSamples = {}
            previous.observation = nil
            previous.turbineBufferPercent = nil
            previous.bufferRecoverySamples = 0
            plan.actuatorState = "APPLIED"
        else
            previous.lastError = tostring(reason or (needsActive and
                "Reactor rejected the activation command" or
                "Reactor rejected the rod command"))
            if needsActive then
                plan.reportedActive = type(applied) == "boolean" and applied or nil
            else
                plan.reportedRodExposure = tonumber(applied)
            end
            plan.actuatorError = previous.lastError
            plan.actuatorState = "FAULT"
        end
    end

    plan.lastAppliedAt = previous.lastAppliedAt
    plan.lastAppliedRodExposure = previous.lastAppliedRodExposure
    plan.lastAppliedActive = previous.lastAppliedActive
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
