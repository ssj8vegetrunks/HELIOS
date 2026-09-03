local engine = {}

local function number(value)
    value = tonumber(value)
    return value and value == value and value ~= math.huge and value ~= -math.huge and value or nil
end

local function percent(value, maximum)
    value, maximum = number(value), number(maximum)
    return value and maximum and maximum > 0 and value / maximum * 100 or nil
end

local function minimum(a, b)
    if a == nil then return b end
    if b == nil then return a end
    return math.min(a, b)
end

local function maximum(a, b)
    if a == nil then return b end
    if b == nil then return a end
    return math.max(a, b)
end

function engine.new(options)
    options = options or {}
    return {
        samples = {},
        maxAge = math.max(300, number(options.maxAge) or 1800),
        maxSamples = math.max(60, math.floor(number(options.maxSamples) or 400)),
        bracketSize = math.max(1000, number(options.bracketSize) or 250000),
        lastBracket = nil,
        bracketChangedAt = nil,
    }
end

function engine.normalize(payload, receivedAt)
    payload = type(payload) == "table" and payload or {}
    return {
        at = number(receivedAt) or 0,
        state = string.lower(tostring(payload.state or "unknown")),
        generation = number(payload.generationRate),
        temperature = number(payload.temperature),
        field = percent(payload.fieldStrength, payload.maxFieldStrength),
        saturation = percent(payload.energySaturation, payload.maxEnergySaturation),
        fuel = percent(payload.fuelConversion, payload.maxFuelConversion),
        fieldInput = number(payload.fieldInput or payload.fieldGate),
        fieldDrain = number(payload.fieldDrainRate),
        export = number(payload.exportFlow or payload.exportGate),
        exportTarget = number(payload.exportGate),
        alarmLevel = number(payload.alarmLevel),
        mode = tostring(payload.mode or "unknown"),
        request = tostring(payload.request or "unknown"),
    }
end

function engine.bracket(state, sample)
    local output = sample and (sample.export or sample.generation) or 0
    return math.floor(math.max(0, number(output) or 0) / state.bracketSize + 0.5) * state.bracketSize
end

function engine.add(state, payload, receivedAt)
    local sample = engine.normalize(payload, receivedAt)
    local bracket = engine.bracket(state, sample)
    sample.bracket = bracket
    if state.lastBracket ~= bracket then
        state.lastBracket = bracket
        state.bracketChangedAt = sample.at
    end
    state.samples[#state.samples + 1] = sample
    local cutoff = sample.at - state.maxAge
    while #state.samples > state.maxSamples or
          (#state.samples > 1 and state.samples[1].at < cutoff) do
        table.remove(state.samples, 1)
    end
    return sample
end

local function slope(first, last, key)
    local a, b = first and first[key], last and last[key]
    local seconds = first and last and last.at - first.at or 0
    if a == nil or b == nil or seconds <= 0 then return nil end
    return (b - a) / seconds * 60
end

function engine.metrics(state, seconds, now)
    local samples = state.samples
    local last = samples[#samples]
    if not last then return nil end
    now = number(now) or last.at
    local cutoff = now - math.max(1, number(seconds) or 30)
    local first, count
    local fieldMin, fieldMax, temperatureMin, temperatureMax
    local saturationMin, saturationMax
    for _, sample in ipairs(samples) do
        if sample.at >= cutoff then
            first = first or sample
            count = (count or 0) + 1
            fieldMin, fieldMax = minimum(fieldMin, sample.field), maximum(fieldMax, sample.field)
            temperatureMin, temperatureMax = minimum(temperatureMin, sample.temperature), maximum(temperatureMax, sample.temperature)
            saturationMin, saturationMax = minimum(saturationMin, sample.saturation), maximum(saturationMax, sample.saturation)
        end
    end
    if not first then first, count = last, 1 end
    return {
        seconds = math.max(0, last.at - first.at),
        count = count,
        fieldSlope = slope(first, last, "field"),
        temperatureSlope = slope(first, last, "temperature"),
        saturationSlope = slope(first, last, "saturation"),
        fieldMin = fieldMin, fieldMax = fieldMax,
        temperatureMin = temperatureMin, temperatureMax = temperatureMax,
        saturationMin = saturationMin, saturationMax = saturationMax,
    }
end

function engine.classify(state, now)
    local last = state.samples[#state.samples]
    if not last then return "WAITING", "Waiting for Guardian telemetry" end
    now = number(now) or last.at
    if now - last.at > 5 then return "LINK STALE", "No recent Guardian telemetry" end
    if last.alarmLevel and last.alarmLevel >= 3 then return "CRITICAL", "Guardian reports a critical alarm" end
    if last.state ~= "running" and last.state ~= "online" then
        return "REACTOR " .. string.upper(last.state), "Waiting for an online operating state"
    end
    local sinceChange = now - (state.bracketChangedAt or last.at)
    if sinceChange < 30 then return "SETTLING", "Output bracket changed recently" end
    local short = engine.metrics(state, 300, now)
    if not short or short.seconds < 60 then return "OBSERVING", "Building a warm-state trend" end
    local fieldSlope = short.fieldSlope or 0
    local temperatureSlope = short.temperatureSlope or 0
    if fieldSlope < -0.5 or temperatureSlope > 30 then
        return "DETERIORATING", "Field is falling or temperature is rising"
    end
    if math.abs(fieldSlope) <= 0.25 and math.abs(temperatureSlope) <= 15 then
        return "STABLE", "Warm-state output bracket is holding"
    end
    if fieldSlope > 0.25 or temperatureSlope < -15 then
        return "IMPROVING", "Containment or temperature is still improving"
    end
    return "OBSERVING", "Trend has not settled"
end

function engine.updateProfile(profiles, state, sample, classification, elapsed)
    profiles = type(profiles) == "table" and profiles or {}
    if not sample then return profiles end
    local key = tostring(math.floor(sample.bracket or 0))
    local profile = profiles[key] or { bracket = sample.bracket, samples = 0, seconds = 0, stableSeconds = 0 }
    profile.samples = (number(profile.samples) or 0) + 1
    profile.seconds = (number(profile.seconds) or 0) + math.max(0, number(elapsed) or 0)
    if classification == "STABLE" then
        profile.stableSeconds = (number(profile.stableSeconds) or 0) + math.max(0, number(elapsed) or 0)
    end
    profile.fieldMin = minimum(number(profile.fieldMin), sample.field)
    profile.fieldMax = maximum(number(profile.fieldMax), sample.field)
    profile.temperatureMin = minimum(number(profile.temperatureMin), sample.temperature)
    profile.temperatureMax = maximum(number(profile.temperatureMax), sample.temperature)
    profile.saturationMin = minimum(number(profile.saturationMin), sample.saturation)
    profile.saturationMax = maximum(number(profile.saturationMax), sample.saturation)
    profile.fuelMin = minimum(number(profile.fuelMin), sample.fuel)
    profile.fuelMax = maximum(number(profile.fuelMax), sample.fuel)
    profile.lastGeneration = sample.generation
    profile.lastExport = sample.export
    profile.lastFieldInput = sample.fieldInput
    profile.lastFieldDrain = sample.fieldDrain
    profile.lastClassification = classification
    profile.lastSeen = sample.at
    profiles[key] = profile
    return profiles
end

return engine
