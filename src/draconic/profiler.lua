local config = dofile("/helios/config.lua")
local engine = dofile("/helios/draconic/profiler_engine.lua")

local VERSION = "0.1.0-alpha.1"
local REQUEST_CHANNEL, TELEMETRY_CHANNEL = 43120, 43121
local DATA_DIR = "/helios/data/draconic-profiler"
local PROFILE_FILE = DATA_DIR .. "/operating_profiles.lua"
local SESSION_FILE = DATA_DIR .. "/current_session.lua"
local guardianId = tonumber((config.network or {}).guardianId)
if not guardianId then error("Profiler Guardian computer ID is not configured", 0) end

local function wirelessModem()
    local names = peripheral.getNames()
    table.sort(names)
    for _, name in ipairs(names) do
        local modem = peripheral.wrap(name)
        if modem and type(modem.isWireless) == "function" then
            local ok, wireless = pcall(modem.isWireless)
            if ok and wireless then return name, modem end
        end
    end
end

local modemName, modem = wirelessModem()
if not modem then error("Attach a wireless modem to the Draconic Profiler", 0) end
modem.open(TELEMETRY_CHANNEL)

local function loadTable(path)
    if not fs.exists(path) then return {} end
    local ok, value = pcall(dofile, path)
    return ok and type(value) == "table" and value or {}
end

local function saveTable(path, value)
    if not fs.exists(DATA_DIR) then fs.makeDir(DATA_DIR) end
    local temporary = path .. ".new"
    local handle = fs.open(temporary, "w")
    if not handle then return false end
    handle.write("return " .. textutils.serialize(value));handle.close()
    if fs.exists(path) then fs.delete(path) end
    fs.move(temporary, path)
    return true
end

local profiles = loadTable(PROFILE_FILE)
local trend = engine.new({ maxAge = 1800, maxSamples = 400, bracketSize = 250000 })
local latest, latestAt, guardianVersion
local classification, explanation = "WAITING", "Waiting for Guardian telemetry"
local lastProfileAt, lastSaveAt, lastSubscribeAt = 0, 0, 0

local computer = term.current()
local monitorName, monitor
for _, name in ipairs(peripheral.getNames()) do
    local types = { peripheral.getType(name) }
    for _, peripheralType in ipairs(types) do
        if peripheralType == "monitor" then monitorName, monitor = name, peripheral.wrap(name);break end
    end
    if monitor then break end
end
if monitor and type(monitor.setTextScale) == "function" then pcall(monitor.setTextScale, 0.5) end

local function fmt(value)
    value = tonumber(value)
    if not value then return "N/A" end
    local units, index = { "", "k", "M", "B", "T" }, 1
    while math.abs(value) >= 1000 and index < #units do value, index = value / 1000, index + 1 end
    return string.format(math.abs(value) >= 100 and "%.0f%s" or "%.2f%s", value, units[index])
end

local function pct(value)
    return value and string.format("%.1f%%", value) or "N/A"
end

local function colourFor(state)
    if state == "STABLE" then return colors.lime end
    if state == "IMPROVING" then return colors.green end
    if state == "DETERIORATING" or state == "CRITICAL" then return colors.red end
    if state == "LINK STALE" then return colors.orange end
    return colors.yellow
end

local function render(target)
    local width, height = target.getSize()
    target.setBackgroundColor(colors.black);target.setTextColor(colors.white);target.clear()
    local function line(row, value, colour)
        if row < 1 or row > height then return end
        target.setCursorPos(1, row);target.setTextColor(colour or colors.white)
        target.write(string.sub(tostring(value or ""), 1, width))
    end
    line(1, "HELIOS // DRACONIC PROFILER  " .. VERSION, colors.yellow)
    line(2, classification, colourFor(classification))
    line(3, explanation, colors.lightGray)
    local connected = latestAt and os.epoch("utc") / 1000 - latestAt <= 5
    line(5, "Guardian " .. guardianId .. "  " .. (connected and "ONLINE" or "WAITING"), connected and colors.lime or colors.orange)
    line(6, "Wireless modem: " .. tostring(modemName), colors.cyan)
    if not latest then
        line(8, "Read-only subscription requests are being sent.", colors.lightGray)
        line(9, "Confirm the Guardian also has a wireless modem.", colors.lightGray)
        return
    end
    local sample = trend.samples[#trend.samples]
    local short = engine.metrics(trend, 30, latestAt)
    local medium = engine.metrics(trend, 300, latestAt)
    line(8, "LIVE OPERATING POINT", colors.cyan)
    line(9, "Generation: " .. fmt(sample.generation) .. " RF/t   Export: " .. fmt(sample.export) .. " RF/t")
    line(10, "Core: " .. fmt(sample.temperature) .. " C   Field: " .. pct(sample.field), colors.orange)
    line(11, "Saturation: " .. pct(sample.saturation) .. "   Fuel conversion: " .. pct(sample.fuel))
    line(12, "Field input/drain: " .. fmt(sample.fieldInput) .. " / " .. fmt(sample.fieldDrain) .. " RF/t")
    line(14, "TREND                         30 SEC       5 MIN", colors.cyan)
    line(15, string.format("Field %%/min             %10s  %10s", fmt(short and short.fieldSlope), fmt(medium and medium.fieldSlope)))
    line(16, string.format("Core C/min               %10s  %10s", fmt(short and short.temperatureSlope), fmt(medium and medium.temperatureSlope)))
    line(17, string.format("Saturation %%/min        %10s  %10s", fmt(short and short.saturationSlope), fmt(medium and medium.saturationSlope)))
    local key = tostring(math.floor(sample.bracket or 0))
    local profile = profiles[key]
    line(19, "OUTPUT BRACKET: " .. fmt(sample.bracket) .. " RF/t", colors.cyan)
    if profile then
        line(20, "Observed: " .. math.floor(profile.seconds or 0) .. "s   Stable: " .. math.floor(profile.stableSeconds or 0) .. "s")
        line(21, "Field range: " .. pct(profile.fieldMin) .. " - " .. pct(profile.fieldMax))
        line(22, "Core range: " .. fmt(profile.temperatureMin) .. " - " .. fmt(profile.temperatureMax) .. " C")
        line(23, "Fuel range: " .. pct(profile.fuelMin) .. " - " .. pct(profile.fuelMax))
    end
    line(height, "READ ONLY | Guardian " .. tostring(guardianVersion or "unknown") .. " | Q quit", colors.gray)
end

local function redraw()
    if monitor then render(monitor) end
    render(computer)
end

local function subscribe()
    modem.transmit(REQUEST_CHANNEL, TELEMETRY_CHANNEL, {
        heliosProfiler = true,
        version = 1,
        kind = "subscribe",
        profilerId = os.getComputerID(),
        targetGuardianId = guardianId,
        sentAt = os.epoch("utc") / 1000,
    })
    lastSubscribeAt = os.epoch("utc") / 1000
end

subscribe();redraw()
local timer = os.startTimer(1)
while true do
    local event, a, channel, replyChannel, message = os.pullEvent()
    if event == "char" and a == "q" then
        saveTable(PROFILE_FILE, profiles)
        saveTable(SESSION_FILE, { guardianId = guardianId, lastTelemetry = latest, lastSeen = latestAt })
        return
    elseif event == "modem_message" and a == modemName and channel == TELEMETRY_CHANNEL and
           type(message) == "table" and message.heliosProfiler == true and
           message.kind == "telemetry" and tonumber(message.guardianId) == guardianId and
           tonumber(message.targetProfilerId) == os.getComputerID() and type(message.payload) == "table" then
        local now = os.epoch("utc") / 1000
        latest, latestAt, guardianVersion = message.payload, now, message.guardianVersion
        local sample = engine.add(trend, latest, now)
        classification, explanation = engine.classify(trend, now)
        if now - lastProfileAt >= 5 then
            local profileElapsed = lastProfileAt > 0 and math.max(0, math.min(10, now - lastProfileAt)) or 0
            profiles = engine.updateProfile(profiles, trend, sample, classification, profileElapsed)
            lastProfileAt = now
        end
        redraw()
    elseif event == "timer" and a == timer then
        local now = os.epoch("utc") / 1000
        if now - lastSubscribeAt >= 3 then subscribe() end
        classification, explanation = engine.classify(trend, now)
        if now - lastSaveAt >= 60 then
            saveTable(PROFILE_FILE, profiles)
            saveTable(SESSION_FILE, { guardianId = guardianId, lastTelemetry = latest, lastSeen = latestAt })
            lastSaveAt = now
        end
        redraw();timer = os.startTimer(1)
    elseif event == "peripheral" or event == "peripheral_detach" or event == "monitor_resize" or event == "term_resize" then
        redraw()
    end
end
