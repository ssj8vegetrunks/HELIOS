-- HELIOS single-file installer
-- Milestone 8.5: coordinated reactor-first steam startup.

local VERSION = "1.4.0-alpha.14"
local INSTALL_DIR = "/helios"
local STAGE_DIR = "/.helios-install"

local function clear()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
end

local function title(subtitle)
    clear()
    term.setTextColor(colors.yellow)
    print("HELIOS")
    term.setTextColor(colors.lightGray)
    print("Industrial Power Management Suite")
    term.setTextColor(colors.gray)
    print(subtitle or "")
    term.setTextColor(colors.white)
    print("")
end

local function choose(prompt, options)
    while true do
        print(prompt)
        for index, option in ipairs(options) do
            print(("  [%d] %s"):format(index, option.label))
        end
        term.setTextColor(colors.yellow)
        write("> ")
        term.setTextColor(colors.white)
        local answer = read()
        local selected = tonumber(answer)
        if selected and options[selected] then
            return options[selected].value
        end
        term.setTextColor(colors.red)
        print("Please enter a number from the list.")
        term.setTextColor(colors.white)
    end
end

local function confirm(prompt)
    write(prompt .. " [Y/N] ")
    local answer = read():lower()
    return answer == "y" or answer == "yes"
end

local function writeFile(path, contents)
    local parent = fs.getDir(path)
    if parent ~= "" and not fs.exists(parent) then
        fs.makeDir(parent)
    end
    local handle, reason = fs.open(path, "w")
    if not handle then error("Could not write " .. path .. ": " .. tostring(reason), 0) end
    handle.write(contents)
    handle.close()
end

local function removeOldBackups()
    for _, name in ipairs(fs.list("/")) do
        if name == "helios.previous" or string.match(name, "^helios%.previous%.%d+$") then
            fs.delete("/" .. name)
        end
    end
end

local FILES = {
    ["core/config.lua"] = [=[
local config = {}

function config.load()
    if not fs.exists("/helios/config.lua") then
        error("HELIOS configuration is missing. Run the installer again.", 0)
    end
    local loaded = dofile("/helios/config.lua")
    if type(loaded) ~= "table" then
        error("HELIOS configuration is invalid.", 0)
    end
    if loaded.role ~= "mainframe" and loaded.role ~= "terminal" then
        error("HELIOS configuration contains an invalid role.", 0)
    end
    loaded.discovery = loaded.discovery or {}
    if loaded.discovery.defaultMode ~= "manual" then
        loaded.discovery.defaultMode = "event"
    end
    local timeout = tonumber(loaded.discovery.maintenanceTimeout)
    if not timeout or timeout < 60 then timeout = 1800 end
    loaded.discovery.maintenanceTimeout = math.floor(timeout)
    loaded.alarms = loaded.alarms or {}
    if loaded.alarms.enabled == nil then loaded.alarms.enabled = true end
    loaded.alarms.lowFuel = tonumber(loaded.alarms.lowFuel) or 20
    loaded.alarms.criticalFuel = tonumber(loaded.alarms.criticalFuel) or 5
    loaded.alarms.volume = tonumber(loaded.alarms.volume) or 1.5
    loaded.alarms.confirmSamples = math.max(1, math.floor(tonumber(loaded.alarms.confirmSamples) or 3))
    loaded.alarms.warningRepeat = math.max(5, math.floor(tonumber(loaded.alarms.warningRepeat) or 30))
    loaded.alarms.criticalRepeat = math.max(2, math.floor(tonumber(loaded.alarms.criticalRepeat) or 5))
    loaded.ui = loaded.ui or {}
    loaded.ui.showPeripheralNames = loaded.ui.showPeripheralNames == true
    loaded.ui.monitorTextScale = tonumber(loaded.ui.monitorTextScale) or 0.5
    loaded.control = loaded.control or {}
    loaded.control.mode = "automatic"
    loaded.control.actuatorsEnabled = loaded.role == "mainframe"
    loaded.control.targetRpm = tonumber(loaded.control.targetRpm) or 1800
    loaded.control.rpmDeadband = math.max(1, tonumber(loaded.control.rpmDeadband) or 25)
    loaded.control.overspeedRpm = math.max(loaded.control.targetRpm + loaded.control.rpmDeadband,
        tonumber(loaded.control.overspeedRpm) or 2000)
    loaded.control.overspeedSamples = math.max(1,
        math.floor(tonumber(loaded.control.overspeedSamples) or 3))
    loaded.control.storageLow = tonumber(loaded.control.storageLow) or 25
    loaded.control.storageHigh = tonumber(loaded.control.storageHigh) or 85
    loaded.control.maxRodStep = math.max(1, math.min(10,
        tonumber(loaded.control.maxRodStep) or 5))
    loaded.control.reactorAdjustmentInterval = math.max(2,
        tonumber(loaded.control.reactorAdjustmentInterval) or 5)
    loaded.control.reactorCommandSamples = math.max(2,
        math.floor(tonumber(loaded.control.reactorCommandSamples) or 3))
    loaded.control.reactorSteamDeadband = math.max(0.005, math.min(0.25,
        tonumber(loaded.control.reactorSteamDeadband) or 0.01))
    loaded.control.reactorSteamDeadbandMin = math.max(1,
        tonumber(loaded.control.reactorSteamDeadbandMin) or 25)
    loaded.control.reactorSteamReserveMargin = math.max(0, math.min(0.25,
        tonumber(loaded.control.reactorSteamReserveMargin) or 0.025))
    loaded.control.reactorSteamAverageSamples = math.max(3,
        math.floor(tonumber(loaded.control.reactorSteamAverageSamples) or 10))
    loaded.control.reactorHotFluidHigh = math.max(50, math.min(99,
        tonumber(loaded.control.reactorHotFluidHigh) or 85))
    loaded.control.reactorHotFluidLow = math.max(1, math.min(
        loaded.control.reactorHotFluidHigh - 1,
        tonumber(loaded.control.reactorHotFluidLow) or 15))
    loaded.control.maxRodEquivalentStep = math.max(0.01, math.min(1,
        tonumber(loaded.control.maxRodEquivalentStep) or 0.25))
    loaded.control.reactorLearningSamples = math.max(3,
        math.floor(tonumber(loaded.control.reactorLearningSamples) or 8))
    loaded.control.reactorLearningSteamDelta = math.max(1,
        tonumber(loaded.control.reactorLearningSteamDelta) or 10)
    loaded.control.reactorLearningTemperatureDelta = math.max(0.01,
        tonumber(loaded.control.reactorLearningTemperatureDelta) or 0.1)
    loaded.control.reactorLearningBufferDelta = math.max(0.01,
        tonumber(loaded.control.reactorLearningBufferDelta) or 0.1)
    loaded.control.reactorMinimumResponseTime = math.max(5,
        tonumber(loaded.control.reactorMinimumResponseTime) or 15)
    loaded.control.reactorProfiles = loaded.control.reactorProfiles or {}
    loaded.control.reactorCooldownWindow = math.max(5,
        tonumber(loaded.control.reactorCooldownWindow) or 10)
    loaded.control.reactorCooldownStallTimeout = math.max(60,
        tonumber(loaded.control.reactorCooldownStallTimeout) or 180)
    loaded.control.reactorCooldownSteamDelta = math.max(0.1,
        tonumber(loaded.control.reactorCooldownSteamDelta) or 2)
    loaded.control.reactorCooldownTemperatureDelta = math.max(0.01,
        tonumber(loaded.control.reactorCooldownTemperatureDelta) or 0.05)
    loaded.control.reactorCalibrationMaxTemperature = math.max(50,
        tonumber(loaded.control.reactorCalibrationMaxTemperature) or 150)
    loaded.control.maxFlowStep = tonumber(loaded.control.maxFlowStep) or 100
    loaded.control.adjustmentInterval = tonumber(loaded.control.adjustmentInterval) or 2
    loaded.control.commandSamples = math.max(1,
        math.floor(tonumber(loaded.control.commandSamples) or 2))
    loaded.control.lowBandRpm = tonumber(loaded.control.lowBandRpm) or 900
    loaded.control.highBandRpm = tonumber(loaded.control.highBandRpm) or 1800
    loaded.control.calibrationLowEscapeRpm = math.max(
        loaded.control.lowBandRpm + loaded.control.rpmDeadband,
        tonumber(loaded.control.calibrationLowEscapeRpm) or
            (loaded.control.lowBandRpm + 100))
    loaded.control.coldStartRpm = math.max(0,
        tonumber(loaded.control.coldStartRpm) or 100)
    loaded.control.calibrationSettleDelta = math.max(0.1,
        tonumber(loaded.control.calibrationSettleDelta) or 2)
    loaded.control.calibrationSettleSamples = math.max(3,
        math.floor(tonumber(loaded.control.calibrationSettleSamples) or 8))
    loaded.control.calibrationMinimumRpm = math.max(0,
        tonumber(loaded.control.calibrationMinimumRpm) or
            (loaded.control.lowBandRpm - loaded.control.rpmDeadband * 2))
    loaded.control.calibrationSteamRatio = math.max(0.1, math.min(1,
        tonumber(loaded.control.calibrationSteamRatio) or 0.98))
    loaded.control.calibrationSteamSamples = math.max(3,
        math.floor(tonumber(loaded.control.calibrationSteamSamples) or 5))
    loaded.control.calibrationFailureSamples = math.max(3,
        math.floor(tonumber(loaded.control.calibrationFailureSamples) or 10))
    loaded.control.calibrationSpoolFailureSamples = math.max(1,
        math.floor(tonumber(loaded.control.calibrationSpoolFailureSamples) or 2))
    loaded.control.calibrationBandEscapeSamples = math.max(2,
        math.floor(tonumber(loaded.control.calibrationBandEscapeSamples) or 3))
    loaded.control.calibrationStallTimeout = math.max(30,
        tonumber(loaded.control.calibrationStallTimeout) or 180)
    loaded.control.overspeedMargin = math.max(loaded.control.rpmDeadband,
        tonumber(loaded.control.overspeedMargin) or 200)
    loaded.control.turbineProfiles = loaded.control.turbineProfiles or {}
    loaded.power = loaded.power or {}
    local validUnits = { FE = true, RF = true, J = true, EU = true }
    if not validUnits[loaded.power.unit] then loaded.power.unit = "FE" end
    if loaded.power.numberFormat ~= "full" then loaded.power.numberFormat = "compact" end
    local decimals = math.floor(tonumber(loaded.power.decimals) or 1)
    loaded.power.decimals = math.max(1, math.min(2, decimals))
    loaded.power.ratios = loaded.power.ratios or {}
    loaded.power.ratios.FE = tonumber(loaded.power.ratios.FE) or 1
    loaded.power.ratios.RF = tonumber(loaded.power.ratios.RF) or 1
    loaded.power.ratios.J = tonumber(loaded.power.ratios.J) or 2.5
    loaded.power.ratios.EU = tonumber(loaded.power.ratios.EU) or 0.25
    loaded.deviceAliases = loaded.deviceAliases or {}
    return loaded
end

function config.save(loaded)
    local handle, reason = fs.open("/helios/config.lua", "w")
    if not handle then return false, reason end
    handle.write("return " .. textutils.serialize(loaded))
    handle.close()
    return true
end

return config
]=],

    ["core/display.lua"] = [=[
local display = {}

local native = term.current()
local monitors = {}
local proxy
local active = false
local textScale = 0.5

local function isMonitor(name)
    local types = { peripheral.getType(name) }
    for _, peripheralType in ipairs(types) do
        if peripheralType == "monitor" then return true end
    end
    return false
end

local function refreshMonitors()
    local found = {}
    for _, name in ipairs(peripheral.getNames()) do
        if isMonitor(name) then
            local monitor = peripheral.wrap(name)
            if monitor then
                local ok, currentScale = pcall(monitor.getTextScale)
                if not ok or currentScale ~= textScale then
                    pcall(monitor.setTextScale, textScale)
                end
                pcall(monitor.setBackgroundColor, native.getBackgroundColor())
                pcall(monitor.setTextColor, native.getTextColor())
                pcall(monitor.setCursorBlink, native.getCursorBlink())
                found[#found + 1] = monitor
            end
        end
    end
    monitors = found
end

local function mirror(method, ...)
    local results = { native[method](...) }
    for _, monitor in ipairs(monitors) do
        pcall(monitor[method], ...)
    end
    return table.unpack(results)
end

local function buildProxy()
    local target = {}
    target.write = function(...) return mirror("write", ...) end
    target.blit = function(...) return mirror("blit", ...) end
    target.clear = function(...)
        refreshMonitors()
        return mirror("clear", ...)
    end
    target.clearLine = function(...) return mirror("clearLine", ...) end
    target.getCursorPos = function(...) return native.getCursorPos(...) end
    target.setCursorPos = function(...) return mirror("setCursorPos", ...) end
    target.setCursorBlink = function(...) return mirror("setCursorBlink", ...) end
    target.getCursorBlink = function(...) return native.getCursorBlink(...) end
    target.isColor = function(...) return native.isColor(...) end
    target.getSize = function(...) return native.getSize(...) end
    target.scroll = function(...) return mirror("scroll", ...) end
    target.setTextColor = function(...) return mirror("setTextColor", ...) end
    target.getTextColor = function(...) return native.getTextColor(...) end
    target.setTextColour = target.setTextColor
    target.getTextColour = target.getTextColor
    target.setBackgroundColor = function(...) return mirror("setBackgroundColor", ...) end
    target.getBackgroundColor = function(...) return native.getBackgroundColor(...) end
    target.setBackgroundColour = target.setBackgroundColor
    target.getBackgroundColour = target.getBackgroundColor
    target.isColour = target.isColor
    target.setPaletteColor = function(...) return mirror("setPaletteColor", ...) end
    target.getPaletteColor = function(...) return native.getPaletteColor(...) end
    target.setPaletteColour = target.setPaletteColor
    target.getPaletteColour = target.getPaletteColor
    return target
end

function display.start(config)
    if active then return end
    textScale = tonumber(config and config.ui and config.ui.monitorTextScale) or 0.5
    textScale = math.max(0.5, math.min(5, textScale))
    refreshMonitors()
    proxy = buildProxy()
    term.redirect(proxy)
    active = true
end

function display.stop()
    if not active then return end
    term.redirect(native)
    active = false
end

function display.count()
    refreshMonitors()
    return #monitors
end

return display
]=],

    ["core/network.lua"] = [=[
local network = {}

network.protocol = "helios.v1"
local PEER_FILE = "/helios/data/terminals.lua"

local function hasType(name, wanted)
    for _, peripheralType in ipairs({ peripheral.getType(name) }) do
        if peripheralType == wanted then return true end
    end
    return false
end

function network.openAll()
    local opened = 0
    for _, name in ipairs(peripheral.getNames()) do
        if hasType(name, "modem") and not rednet.isOpen(name) then
            local ok = pcall(rednet.open, name)
            if ok then opened = opened + 1 end
        elseif hasType(name, "modem") then
            opened = opened + 1
        end
    end
    return opened
end

function network.send(target, message)
    if type(target) ~= "number" or type(message) ~= "table" then return false end
    return rednet.send(target, message, network.protocol)
end

function network.broadcast(message)
    if type(message) ~= "table" then return false end
    rednet.broadcast(message, network.protocol)
    return true
end

function network.valid(message, kind)
    return type(message) == "table" and message.helios == true and
        (kind == nil or message.kind == kind)
end

function network.now()
    return os.epoch("utc") / 1000
end

function network.sessionId(role)
    local seed = table.concat({
        tostring(role or "helios"),
        tostring(os.getComputerID()),
        tostring(os.epoch("utc")),
        tostring(os.clock()),
        tostring(math.random(1, 2147483647)),
    }, ":")
    return seed
end

function network.loadPeers()
    if not fs.exists(PEER_FILE) then return {} end
    local ok, peers = pcall(dofile, PEER_FILE)
    return ok and type(peers) == "table" and peers or {}
end

function network.savePeers(peers)
    if not fs.exists("/helios/data") then fs.makeDir("/helios/data") end
    local handle, reason = fs.open(PEER_FILE, "w")
    if not handle then return false, reason end
    handle.write("return " .. textutils.serialize(peers))
    handle.close()
    return true
end

return network
]=],

    ["core/power_format.lua"] = [=[
local formatter = {}

local function addCommas(value)
    local sign = value < 0 and "-" or ""
    local digits = tostring(math.floor(math.abs(value) + 0.5))
    local changed
    repeat
        digits, changed = digits:gsub("^(%d+)(%d%d%d)", "%1,%2")
    until changed == 0
    return sign .. digits
end

function formatter.convert(value, powerConfig)
    value = tonumber(value)
    if not value then return nil end
    local unit = powerConfig.unit or "FE"
    local ratio = tonumber((powerConfig.ratios or {})[unit]) or 1
    return value * ratio
end

function formatter.number(value, powerConfig)
    value = tonumber(value)
    if not value then return "N/A" end
    if powerConfig.numberFormat == "full" then return addCommas(value) end
    local absolute = math.abs(value)
    local scale, suffix = 1, ""
    if absolute >= 1e18 then scale, suffix = 1e18, "Qi"
    elseif absolute >= 1e15 then scale, suffix = 1e15, "Qa"
    elseif absolute >= 1e12 then scale, suffix = 1e12, "T"
    elseif absolute >= 1e9 then scale, suffix = 1e9, "B"
    elseif absolute >= 1e6 then scale, suffix = 1e6, "M"
    elseif absolute >= 1e3 then scale, suffix = 1e3, "k"
    end
    if scale == 1 then
        local rounded = value >= 0 and math.floor(value + 0.5) or math.ceil(value - 0.5)
        return tostring(rounded)
    end
    local decimals = math.max(1, math.min(2, math.floor(tonumber(powerConfig.decimals) or 1)))
    return (("%." .. decimals .. "f%s"):format(value / scale, suffix))
end

function formatter.power(value, powerConfig, perTick)
    local converted = formatter.convert(value, powerConfig)
    if converted == nil then return "N/A" end
    return formatter.number(converted, powerConfig) .. " " .. (powerConfig.unit or "FE") .. (perTick and "/t" or "")
end

return formatter
]=],

    ["core/ui.lua"] = [=[
local ui = {}
local idConflicts = {}
local systemVersion

function ui.setVersion(version)
    systemVersion = version and tostring(version) or nil
end

function ui.setIdConflicts(conflicts)
    idConflicts = {}
    if type(conflicts) == "table" then
        for _, id in ipairs(conflicts) do idConflicts[#idConflicts + 1] = tostring(id) end
    end
end

function ui.hasIdConflict()
    return #idConflicts > 0
end

function ui.button(label, colour)
    local x, y = term.getCursorPos()
    term.setTextColor(colour or colors.cyan)
    local text = "[ " .. label .. " ]"
    print(text)
    term.setTextColor(colors.white)
    return { x1 = x, x2 = x + #text - 1, y = y }
end

function ui.inlineButton(label, colour)
    local x, y = term.getCursorPos()
    term.setTextColor(colour or colors.cyan)
    local text = "[" .. label .. "]"
    write(text)
    term.setTextColor(colors.white)
    return { x1 = x, x2 = x + #text - 1, y = y }
end

function ui.hit(button, x, y)
    return button and y == button.y and x >= button.x1 and x <= button.x2
end

function ui.eventPoint(event, first, second, third)
    if event == "monitor_touch" or event == "mouse_click" then
        return second, third
    end
    return nil, nil
end

function ui.prepare()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
end

function ui.header(role, subtitle)
    ui.prepare()
    if #idConflicts > 0 then
        local width = select(1, term.getSize())
        term.setBackgroundColor(colors.red)
        term.setTextColor(colors.white)
        local warning = " ID CONFLICT: " .. table.concat(idConflicts, ", ") .. " "
        print(string.sub(warning .. string.rep(" ", width), 1, width))
        term.setBackgroundColor(colors.black)
    end
    term.setTextColor(colors.yellow)
    local width = select(1, term.getSize())
    local heading = "HELIOS // " .. string.upper(role)
    local version = systemVersion and ("v" .. systemVersion) or ""
    local row = select(2, term.getCursorPos())
    term.setCursorPos(1, row)
    if #version > 0 and #version < width then
        local headingWidth = math.max(0, width - #version - 1)
        write(string.sub(heading, 1, headingWidth))
        term.setCursorPos(width - #version + 1, row)
        write(version)
    else
        write(string.sub(heading, 1, width))
    end
    term.setCursorPos(1, row + 1)
    term.setTextColor(colors.lightGray)
    print(subtitle)
    term.setTextColor(colors.gray)
    print(string.rep("-", math.min(select(1, term.getSize()), 40)))
    term.setTextColor(colors.white)
end

function ui.status(label, value, colour)
    term.setTextColor(colors.lightGray)
    write(label .. ": ")
    term.setTextColor(colour or colors.white)
    print(tostring(value))
    term.setTextColor(colors.white)
end

function ui.waitForExit(render)
    while true do
        local event, key = os.pullEvent()
        if event == "key" and key == keys.q then
            ui.prepare()
            return
        elseif event == "term_resize" or event == "monitor_resize" or
               event == "peripheral" or event == "peripheral_detach" then
            render()
        end
    end
end

return ui
]=],

    ["helios.lua"] = [=[
local args = { ... }
local config = dofile("/helios/core/config.lua").load()

if args[1] == "unpair" then
    if config.role ~= "terminal" then
        error("Only a HELIOS remote terminal can be unpaired.", 0)
    end
    config.mainframeId = nil
    local ok, reason = dofile("/helios/core/config.lua").save(config)
    if not ok then error("Could not save HELIOS configuration: " .. tostring(reason), 0) end
    print("Remote terminal unpaired. Restart HELIOS to discover a mainframe.")
    return
end

if args[1] == "status" then
    print("HELIOS " .. tostring(config.version))
    print("Role: " .. tostring(config.role))
    if config.role == "terminal" then
        print("Display: " .. tostring(config.display))
        print("Mainframe ID: " .. tostring(config.mainframeId or "not paired"))
    end
    print("Computer ID: " .. tostring(config.computerId))
    return
end

if args[1] == "scan" then
    if config.role ~= "mainframe" then
        error("Only the HELIOS mainframe can scan attached hardware.", 0)
    end
    local registry = dofile("/helios/mainframe/device_registry.lua")
    local devices = registry.scan()
    registry.save(devices)
    registry.printReport(devices)
    return
end

if args[1] == "reactors" then
    if config.role ~= "mainframe" then
        error("Only the HELIOS mainframe can read reactor telemetry.", 0)
    end
    local registry = dofile("/helios/mainframe/device_registry.lua")
    local adapter = dofile("/helios/mainframe/reactor_adapter.lua")
    local formatter = dofile("/helios/core/power_format.lua")
    local devices = registry.scan()
    adapter.printReport(adapter.readAll(devices), config, formatter)
    return
end

if args[1] == "turbines" then
    if config.role ~= "mainframe" then
        error("Only the HELIOS mainframe can read turbine telemetry.", 0)
    end
    local registry = dofile("/helios/mainframe/device_registry.lua")
    local adapter = dofile("/helios/mainframe/turbine_adapter.lua")
    local formatter = dofile("/helios/core/power_format.lua")
    local devices = registry.scan()
    adapter.printReport(adapter.readAll(devices), config, formatter)
    return
end

if args[1] == "storage" or args[1] == "batteries" then
    if config.role ~= "mainframe" then
        error("Only the HELIOS mainframe can read energy-storage telemetry.", 0)
    end
    local registry = dofile("/helios/mainframe/device_registry.lua")
    local adapter = dofile("/helios/mainframe/storage_adapter.lua")
    local formatter = dofile("/helios/core/power_format.lua")
    local devices = registry.scan()
    adapter.printReport(adapter.readAll(devices, config.power), config, formatter)
    return
end

if config.role == "mainframe" then
    dofile("/helios/mainframe/main.lua").run(config)
elseif config.role == "terminal" then
    dofile("/helios/terminal/main.lua").run(config)
else
    error("Unknown HELIOS role in /helios/config.lua: " .. tostring(config.role), 0)
end
]=],

    ["mainframe/device_registry.lua"] = [=[
local registry = {}
local REGISTRY_FILE = "/helios/data/devices.lua"

local function contains(value, fragment)
    return string.find(string.lower(value or ""), fragment, 1, true) ~= nil
end

local function methodSet(methods)
    local set = {}
    for _, method in ipairs(methods) do set[method] = true end
    return set
end

local function classify(name, types, methods)
    if contains(name, "turbine") then return "turbine" end
    if contains(name, "reactor") then return "reactor" end
    for _, peripheralType in ipairs(types) do
        if contains(peripheralType, "turbine") then return "turbine" end
    end
    for _, peripheralType in ipairs(types) do
        if contains(peripheralType, "reactor") then return "reactor" end
    end
    for _, peripheralType in ipairs(types) do
        if peripheralType == "monitor" then return "monitor" end
        if peripheralType == "modem" then return "modem" end
    end

    local available = methodSet(methods)
    local inductionIdentity = contains(name, "inductionport") or contains(name, "induction_port")
    for _, peripheralType in ipairs(types) do
        if contains(peripheralType, "inductionport") or contains(peripheralType, "induction_port") then
            inductionIdentity = true
        end
    end
    local inductionSignature = available.getEnergy and available.getMaxEnergy and
        (available.getLastInput or available.getLastOutput or available.getTransferCap or
         available.getInstalledCells or available.getInstalledProviders)
    if inductionIdentity and inductionSignature then return "battery" end

    local energyReader =
        (available.getEnergyStored and available.getMaxEnergyStored) or
        (available.getEnergy and available.getEnergyCapacity) or
        (available.getStoredEnergy and available.getEnergyCapacity) or
        (available.getStored and available.getCapacity)
    if energyReader then return "battery" end

    return "unknown"
end

function registry.scan()
    local devices = {}
    local names = peripheral.getNames()
    table.sort(names)

    for _, name in ipairs(names) do
        local types = { peripheral.getType(name) }
        local methods = peripheral.getMethods(name) or {}
        table.sort(types)
        table.sort(methods)
        devices[#devices + 1] = {
            name = name,
            types = types,
            methods = methods,
            category = classify(name, types, methods),
        }
    end
    return devices
end

function registry.save(devices)
    if not fs.exists("/helios/data") then fs.makeDir("/helios/data") end
    local handle, reason = fs.open(REGISTRY_FILE, "w")
    if not handle then return false, reason end
    handle.write("return " .. textutils.serialize({
        scannedAt = os.epoch("utc"),
        devices = devices,
    }))
    handle.close()
    return true
end

function registry.countByCategory(devices)
    local counts = { reactor = 0, turbine = 0, battery = 0, monitor = 0, modem = 0, unknown = 0 }
    for _, device in ipairs(devices) do
        counts[device.category] = (counts[device.category] or 0) + 1
    end
    return counts
end

function registry.printReport(devices)
    print("HELIOS hardware scan")
    print("Devices found: " .. #devices)
    print("")
    for _, device in ipairs(devices) do
        print(("[%s] %s"):format(string.upper(device.category), device.name))
        print("  Types: " .. (#device.types > 0 and table.concat(device.types, ", ") or "unreported"))
    end
    print("")
    print("Registry saved to " .. REGISTRY_FILE)
end

return registry
]=],

    ["mainframe/main.lua"] = [=[
local mainframe = {}

function mainframe.run(config)
    local display = dofile("/helios/core/display.lua")
    display.start(config)
    local ui = dofile("/helios/core/ui.lua")
    ui.setVersion(config.version)
    local configStore = dofile("/helios/core/config.lua")
    local registry = dofile("/helios/mainframe/device_registry.lua")
    local reactorAdapter = dofile("/helios/mainframe/reactor_adapter.lua")
    local reactorGovernor = dofile("/helios/mainframe/reactor_governor.lua")
    local turbineAdapter = dofile("/helios/mainframe/turbine_adapter.lua")
    local turbineGovernor = dofile("/helios/mainframe/turbine_governor.lua")
    local storageAdapter = dofile("/helios/mainframe/storage_adapter.lua")
    local powerFormat = dofile("/helios/core/power_format.lua")
    local network = dofile("/helios/core/network.lua")
    local devices = {}
    local reactors = {}
    local turbines = {}
    local storages = {}
    local registryStale = false
    local maintenance = false
    local maintenanceEndsAt
    local maintenanceTimer
    local countdownTimer
    local reactorTimer
    local currentAlarm
    local silencedAlarm
    local lastAlarmSound = 0
    local conditionSamples = {}
    local silenceButton
    local modemCount = network.openAll()
    local terminals = network.loadPeers()
    local missingDevices = {}
    local sessionId = network.sessionId("mainframe")
    local identityClaims = {}
    local idConflicts = {}
    local dashboardButtons = {}
    local governorMemory = turbineGovernor.new()
    local reactorGovernorMemory = reactorGovernor.new()

    local timeoutChoices = { 300, 900, 1800, 3600 }

    local function sameList(a, b)
        if #a ~= #b then return false end
        for index = 1, #a do if a[index] ~= b[index] then return false end end
        return true
    end

    local function refreshIdConflicts()
        local now = network.now()
        local conflicts = {}
        for id, claims in pairs(identityClaims) do
            local count = 0
            for claim, seenAt in pairs(claims) do
                if now - seenAt <= 10 then count = count + 1 else claims[claim] = nil end
            end
            if tonumber(id) == os.getComputerID() then count = count + 1 end
            if count > 1 then conflicts[#conflicts + 1] = tonumber(id) or id end
        end
        table.sort(conflicts, function(a, b) return tostring(a) < tostring(b) end)
        local changed = not sameList(idConflicts, conflicts)
        idConflicts = conflicts
        ui.setIdConflicts(idConflicts)
        return changed
    end

    local function advertiseIntegrity()
        network.broadcast({
            helios = true,
            kind = "integrity",
            sourceId = os.getComputerID(),
            sessionId = sessionId,
            idConflicts = idConflicts,
            sentAt = network.now(),
        })
    end

    local function modeName()
        if maintenance then return "MANUAL - MAINTENANCE" end
        if config.discovery.defaultMode == "manual" then return "MANUAL" end
        return "AUTOMATIC"
    end

    local function rescan(acceptChanges)
        modemCount = network.openAll()
        local previous = {}
        if acceptChanges then
            missingDevices = {}
        else
            for _, device in ipairs(devices) do
                if device.category == "reactor" or device.category == "turbine" or device.category == "battery" then
                    previous[device.name] = device.category
                end
            end
        end
        local scanned = registry.scan()
        local present = {}
        for _, device in ipairs(scanned) do
            present[device.name] = true
            missingDevices[device.name] = nil
        end
        for name, category in pairs(previous) do
            if not present[name] then missingDevices[name] = category end
        end
        devices = scanned
        registry.save(devices)
        reactors = reactorAdapter.readAll(devices)
        turbines = turbineAdapter.readAll(devices)
        storages = storageAdapter.readAll(devices, config.power)
        registryStale = false
    end

    local function playSound(sound, pitch, force)
        if not config.alarms.enabled and not force then return end
        for _, name in ipairs(peripheral.getNames()) do
            local types = { peripheral.getType(name) }
            for _, peripheralType in ipairs(types) do
                if peripheralType == "speaker" then
                    pcall(peripheral.call, name, "playSound", sound, config.alarms.volume, pitch)
                    break
                end
            end
        end
    end

    local function chooseAlarm()
        local candidates = {}
        local activeKeys = {}
        local function alarmName(name)
            return (config.deviceAliases and config.deviceAliases[name]) or name
        end
        local function add(level, key, message)
            activeKeys[key] = true
            conditionSamples[key] = (conditionSamples[key] or 0) + 1
            if conditionSamples[key] >= config.alarms.confirmSamples then
                candidates[#candidates + 1] = { level = level, key = key, message = message }
            end
        end
        local function addConfirmed(level, key, message)
            activeKeys[key] = true
            conditionSamples[key] = config.alarms.confirmSamples
            candidates[#candidates + 1] = { level = level, key = key, message = message }
        end

        for _, reactor in ipairs(reactors) do
            if reactor.error and not maintenance then
                add(3, reactor.name .. ":telemetry", alarmName(reactor.name) .. " TELEMETRY LOST")
            elseif reactor.governor and reactor.governor.actuatorState == "FAULT" then
                add(2, reactor.name .. ":control", alarmName(reactor.name) .. " CONTROL FAULT")
            elseif reactor.governor and reactor.governor.state == "STEAM DEFICIT" then
                add(2, reactor.name .. ":steam-deficit",
                    alarmName(reactor.name) .. " CANNOT MEET STEAM DEMAND")
            elseif reactor.governor and reactor.governor.state == "STEAM SURPLUS" then
                add(2, reactor.name .. ":steam-surplus",
                    alarmName(reactor.name) .. " STEAM OUTPUT CANNOT REDUCE")
            elseif reactor.governor and reactor.governor.state == "RODS NOT UNIFORM" then
                add(2, reactor.name .. ":rod-levels",
                    alarmName(reactor.name) .. " CONTROL RODS NOT UNIFORM")
            elseif reactor.fuelPercent then
                if reactor.fuelPercent <= config.alarms.criticalFuel then
                    add(3, reactor.name .. ":fuel-critical", alarmName(reactor.name) .. " FUEL CRITICAL")
                elseif reactor.fuelPercent <= config.alarms.lowFuel then
                    add(1, reactor.name .. ":fuel-low", alarmName(reactor.name) .. " FUEL LOW")
                end
            end
        end
        for _, turbine in ipairs(turbines) do
            if turbine.error and not maintenance then
                add(3, turbine.name .. ":telemetry", alarmName(turbine.name) .. " TELEMETRY LOST")
            elseif turbine.governor and turbine.governor.state == "OVERSPEED" then
                addConfirmed(3, turbine.name .. ":overspeed", alarmName(turbine.name) .. " OVERSPEED")
            elseif turbine.governor and turbine.governor.state == "CALIBRATION FAILED" then
                addConfirmed(2, turbine.name .. ":calibration",
                    alarmName(turbine.name) .. " CALIBRATION FAILED: " ..
                    tostring(turbine.governor.reason or "invalid operating result"))
            elseif turbine.governor and turbine.governor.actuatorState == "FAULT" then
                add(2, turbine.name .. ":control", alarmName(turbine.name) .. " CONTROL FAULT")
            end
        end
        for _, storage in ipairs(storages) do
            if storage.error and not maintenance then
                add(2, storage.name .. ":telemetry", alarmName(storage.name) .. " TELEMETRY LOST")
            end
        end
        if not maintenance then
            for name, category in pairs(missingDevices) do
                local level = category == "battery" and 2 or 3
                add(level, name .. ":missing", alarmName(name) .. " CONNECTION LOST")
            end
        end
        for key in pairs(conditionSamples) do
            if not activeKeys[key] then conditionSamples[key] = nil end
        end
        table.sort(candidates, function(a, b)
            if a.level ~= b.level then return a.level > b.level end
            return a.key < b.key
        end)
        return candidates[1]
    end

    local function updateAlarm()
        local previous = currentAlarm
        currentAlarm = chooseAlarm()
        if not currentAlarm then
            if previous then playSound("minecraft:block.note_block.pling", 1.5) end
            silencedAlarm = nil
            return
        end

        local signature = currentAlarm.level .. ":" .. currentAlarm.key
        local previousSignature = previous and (previous.level .. ":" .. previous.key) or nil
        if signature ~= previousSignature then
            silencedAlarm = nil
            lastAlarmSound = 0
        end
        if silencedAlarm == signature then return end

        local now = os.epoch("utc") / 1000
        local repeatAfter = currentAlarm.level >= 3 and
            config.alarms.criticalRepeat or config.alarms.warningRepeat
        if now - lastAlarmSound >= repeatAfter then
            local sound = currentAlarm.level >= 3 and "minecraft:block.note_block.bell" or "minecraft:block.note_block.pling"
            local pitch = currentAlarm.level >= 3 and 0.6 or 1.0
            playSound(sound, pitch)
            lastAlarmSound = now
        end
    end

    local function pollReactors()
        reactors = reactorAdapter.readAll(devices)
        turbines = turbineAdapter.readAll(devices)
        storages = storageAdapter.readAll(devices, config.power)
        local now = os.epoch("utc") / 1000
        local _, steamDemand = reactorGovernor.evaluateAll(reactorGovernorMemory,
            reactors, turbines, config.control, {
                maintenance = maintenance,
                mainframeId = os.getComputerID(),
                idConflicts = idConflicts,
                now = now,
            })
        if reactorGovernor.consumeProfileChanges(reactorGovernorMemory) then
            configStore.save(config)
        end
        reactorGovernor.applyAll(reactorGovernorMemory, reactors, config.control, {
            maintenance = maintenance,
            now = now,
        }, {
            setActive = reactorAdapter.setActive,
            setControlRodExposure = reactorAdapter.setControlRodExposure,
        })

        local steamSource = reactorGovernor.steamSourceStatus(reactors,
            steamDemand, config.control)
        turbineGovernor.evaluateAll(governorMemory, turbines, config.control, {
            maintenance = maintenance,
            mainframeId = os.getComputerID(),
            idConflicts = idConflicts,
            now = now,
            steamSourceManaged = steamSource.managed,
            steamSourceReady = steamSource.ready,
            steamSourceReason = steamSource.reason,
        })
        if turbineGovernor.consumeProfileChanges(governorMemory) then
            configStore.save(config)
        end
        turbineGovernor.applyAll(governorMemory, turbines, config.control, {
                maintenance = maintenance,
                now = now,
        }, {
            setFlowLimit = turbineAdapter.setFlowLimit,
            setInductor = turbineAdapter.setInductor,
        })
        updateAlarm()
        local conflictsChanged = refreshIdConflicts()
        if conflictsChanged or #idConflicts > 0 then advertiseIntegrity() end
    end

    local function alarmSignature()
        return currentAlarm and (currentAlarm.level .. ":" .. currentAlarm.key) or nil
    end

    local function snapshotFor(assignment)
        local includeAll = assignment == "all"
        return {
            helios = true,
            kind = "snapshot",
            version = config.version,
            sentAt = network.now(),
            assignment = assignment,
            reactors = (includeAll or assignment == "reactor") and reactors or {},
            turbines = (includeAll or assignment == "turbine") and turbines or {},
            storages = (includeAll or assignment == "battery") and storages or {},
            aliases = config.deviceAliases,
            showPeripheralNames = config.ui.showPeripheralNames,
            power = config.power,
            alarm = currentAlarm,
            alarmSilenced = currentAlarm ~= nil and silencedAlarm == alarmSignature(),
            alarmVolume = config.alarms.volume,
            idConflicts = idConflicts,
            control = config.control,
        }
    end

    local function sendSnapshot(id, assignment)
        network.send(id, snapshotFor(assignment or "all"))
    end

    local function broadcastSnapshots()
        for _, remote in pairs(terminals) do
            sendSnapshot(remote.id, remote.display)
        end
    end

    local function handleNetwork(sender, message, protocol)
        if protocol ~= network.protocol or not network.valid(message, "hello") then return false end
        local claim = tostring(message.sessionId or ("legacy:" .. tostring(sender)))
        local idKey = tostring(sender)
        identityClaims[idKey] = identityClaims[idKey] or {}
        identityClaims[idKey][claim] = network.now()
        local conflictsChanged = refreshIdConflicts()
        local assignment = ({ reactor = true, turbine = true, battery = true, all = true })[message.display]
            and message.display or "all"
        local key = tostring(sender) .. ":" .. claim
        for savedKey, remote in pairs(terminals) do
            if savedKey ~= key and tonumber(remote.id) == sender then terminals[savedKey] = nil end
        end
        local previous = terminals[key]
        terminals[key] = {
            id = sender,
            display = assignment,
            version = tostring(message.version or "unknown"),
            lastSeen = network.now(),
        }
        if not previous or previous.display ~= assignment or previous.version ~= terminals[key].version then
            network.savePeers(terminals)
        end
        sendSnapshot(sender, assignment)
        if conflictsChanged or #idConflicts > 0 then advertiseIntegrity() end
        return true
    end

    local function onlineTerminalCount()
        local now = network.now()
        local count = 0
        for _, remote in pairs(terminals) do
            if now - (tonumber(remote.lastSeen) or 0) <= 10 then count = count + 1 end
        end
        return count
    end

    local function deviceName(rawName)
        local alias = config.deviceAliases[rawName]
        if alias and alias ~= "" then
            if config.ui.showPeripheralNames then return alias .. " [" .. rawName .. "]" end
            return alias
        end
        return rawName
    end

    local function silenceCurrentAlarm()
        if currentAlarm then
            silencedAlarm = currentAlarm.level .. ":" .. currentAlarm.key
            broadcastSnapshots()
        end
    end

    local function alarmColour()
        if not currentAlarm then return colors.lime end
        return currentAlarm.level >= 3 and colors.red or colors.orange
    end

    local function saveConfig()
        local ok, reason = configStore.save(config)
        if not ok then error("Could not save HELIOS settings: " .. tostring(reason), 0) end
    end

    local function stopMaintenance()
        if maintenanceTimer then os.cancelTimer(maintenanceTimer) end
        if countdownTimer then os.cancelTimer(countdownTimer) end
        maintenance = false
        maintenanceEndsAt = nil
        maintenanceTimer = nil
        countdownTimer = nil
        rescan(true)
    end

    local function startMaintenance()
        if maintenanceTimer then os.cancelTimer(maintenanceTimer) end
        if countdownTimer then os.cancelTimer(countdownTimer) end
        maintenance = true
        maintenanceEndsAt = os.epoch("utc") + (config.discovery.maintenanceTimeout * 1000)
        maintenanceTimer = os.startTimer(config.discovery.maintenanceTimeout)
        countdownTimer = os.startTimer(1)
    end

    local function remainingMaintenance()
        if not maintenanceEndsAt then return 0 end
        return math.max(0, math.ceil((maintenanceEndsAt - os.epoch("utc")) / 1000))
    end

    local function controlStatus()
        if maintenance then return "MAINTENANCE / ACTUATORS PAUSED", colors.orange end
        if #idConflicts > 0 then return "CONTROL LOCKED / ID CONFLICT", colors.red end

        for _, turbine in ipairs(turbines) do
            local plan = turbine.governor or {}
            if plan.actuatorState == "FAULT" or plan.state == "CALIBRATION FAILED" then
                return "CONTROL FAULT / ATTENTION REQUIRED", colors.red
            end
            if plan.state == "WAITING FOR STEAM SOURCE" then
                return "AUTOMATIC / PREPARING STEAM", colors.orange
            end
            if tostring(plan.state or ""):find("CALIBRATION", 1, true) then
                return "AUTOMATIC / CALIBRATING TURBINES", colors.orange
            end
        end
        for _, reactor in ipairs(reactors) do
            local plan = reactor.governor or {}
            if plan.actuatorState == "FAULT" then
                return "CONTROL FAULT / ATTENTION REQUIRED", colors.red
            elseif plan.state == "STARTING" or plan.state == "BASELINING" or
                   plan.state == "AVERAGING" or plan.state == "RESPONDING" or
                   plan.state == "STEAM LOW" or plan.state == "STEAM HIGH" or
                   plan.state == "RECOVERING" or plan.state == "RECALIBRATING" then
                return "AUTOMATIC / PREPARING STEAM", colors.orange
            elseif plan.state == "COOLING" then
                return "AUTOMATIC / REACTOR COOLING", colors.orange
            elseif plan.state == "STEAM DEFICIT" or plan.state == "STEAM SURPLUS" then
                return "AUTOMATIC / STEAM CAPACITY LIMIT", colors.orange
            elseif reactor.active == true and reactor.mode == "steam" and
                   plan.trusted == false then
                return "AUTOMATIC / REACTOR CONTROL HELD", colors.orange
            end
        end

        local target, count, matching, allStable = nil, 0, true, true
        for _, turbine in ipairs(turbines) do
            local plan = turbine.governor or {}
            if turbine.active == true and plan.calibrated then
                local wanted = tonumber(plan.targetRpm)
                if target and wanted and math.abs(target - wanted) > 1 then matching = false end
                target = target or wanted
                count = count + 1
                if plan.state ~= "STABLE" or plan.actuatorState ~= "HOLD" then
                    allStable = false
                end
            end
        end
        if count > 0 and matching and target and allStable then
            return ("AUTOMATIC / HOLDING %.0f RPM"):format(target), colors.lime
        elseif count > 0 then
            return "AUTOMATIC / GOVERNORS ACTIVE", colors.lime
        elseif #turbines > 0 or #reactors > 0 then
            return "AUTOMATIC / WAITING FOR PLANT", colors.orange
        end
        return "AUTOMATIC / NO CONTROLLED PLANT", colors.gray
    end

    local function render()
        ui.setIdConflicts(idConflicts)
        ui.header("MAINFRAME", "Central control authority")
        ui.status("System", "ONLINE", colors.lime)
        ui.status("Computer ID", config.computerId)
        ui.status("Attached hardware", #devices, #devices > 0 and colors.lime or colors.orange)
        local monitorCount = display.count()
        ui.status("Monitor output", monitorCount > 0 and (monitorCount .. " MIRRORED") or "NONE",
            monitorCount > 0 and colors.lime or colors.gray)
        ui.status("Remote terminals", ("%d ONLINE / %d KNOWN"):format(onlineTerminalCount(),
            (function() local count = 0 for _ in pairs(terminals) do count = count + 1 end return count end)()),
            onlineTerminalCount() > 0 and colors.lime or colors.gray)
        ui.status("Discovery", modeName(), maintenance and colors.orange or colors.cyan)
        local controlText, controlColour = controlStatus()
        ui.status("Control", controlText, controlColour)
        if registryStale then
            term.setTextColor(colors.orange)
            print("Registry may be outdated")
            term.setTextColor(colors.white)
        elseif maintenance then
            print(("Auto return in %d:%02d"):format(
                math.floor(remainingMaintenance() / 60), remainingMaintenance() % 60
            ))
        end

        local counts = registry.countByCategory(devices)
        print(("R:%d T:%d B:%d M:%d"):format(
            counts.reactor, counts.turbine, counts.battery, counts.monitor
        ))

        if currentAlarm then
            term.setTextColor(alarmColour())
            print("!! " .. currentAlarm.message)
            term.setTextColor(colors.white)
            local _, row = term.getCursorPos()
            print("[ SILENCE ALARM ]")
            silenceButton = { y = row, x1 = 1, x2 = 17 }
        else
            silenceButton = nil
            ui.status("Alarms", config.alarms.enabled and "CLEAR" or "DISABLED",
                config.alarms.enabled and colors.lime or colors.gray)
        end

        local width, height = term.getSize()
        local availableRows = math.max(0, height - 18)
        if #devices > availableRows then
            availableRows = math.max(0, availableRows - 1)
        end
        for index = 1, math.min(#devices, availableRows) do
            local device = devices[index]
            local line = ("%-7s %s"):format(string.upper(device.category), deviceName(device.name))
            print(string.sub(line, 1, width))
        end
        if #devices > availableRows then
            print(("+ %d more (run: helios scan)"):format(#devices - availableRows))
        end
        print("")
        dashboardButtons = {}
        dashboardButtons.reactors = ui.inlineButton("REACTORS", colors.cyan)
        write(" ")
        dashboardButtons.turbines = ui.inlineButton("TURBINES", colors.cyan)
        write(" ")
        dashboardButtons.storage = ui.inlineButton("STORAGE", colors.cyan)
        print("")
        dashboardButtons.control = ui.inlineButton("CONTROL", colors.lime)
        write(" ")
        dashboardButtons.rescan = ui.inlineButton("RESCAN", colors.cyan)
        write(" ")
        dashboardButtons.settings = ui.inlineButton("SETTINGS", colors.cyan)
        print("")
        term.setTextColor(colors.gray)
        print("Keyboard: V/G/E/C/R/S | Q exit")
        term.setTextColor(colors.white)
    end

    local function controlView()
        local selected = 1
        local buttons = {}
        local function draw()
            ui.setIdConflicts(idConflicts)
            ui.header("POWER CONTROL", "Automatic turbine governor")
            ui.status("Mode", "AUTOMATIC", colors.lime)
            ui.status("Actuators", "ENABLED - GUARDED", colors.lime)
            if #turbines == 0 then
                ui.status("Status", "NO TURBINES FOUND", colors.orange)
            else
                if selected > #turbines then selected = #turbines end
                local turbine = turbines[selected]
                local plan = turbine.governor or {}
                ui.status("Turbine", ("%d/%d %s"):format(selected, #turbines,
                    deviceName(turbine.name)), colors.cyan)
                ui.status("Governor", plan.state or "WAITING",
                    (plan.trusted == false or plan.actuatorState == "FAULT" or
                        plan.state == "CALIBRATION FAILED") and colors.red or colors.lime)
                ui.status("Rotor / target", ("%.1f / %d RPM"):format(
                    tonumber(turbine.rotorSpeed) or 0,
                    tonumber(plan.targetRpm) or config.control.highBandRpm), colors.cyan)
                if plan.currentFlow ~= nil and plan.recommendedFlow ~= nil then
                    ui.status("Flow-limit plan", ("%.0f -> %.0f mB/t"):format(
                        plan.currentFlow, plan.recommendedFlow), colors.cyan)
                else
                    ui.status("Flow-limit plan", "HOLD - TELEMETRY REQUIRED", colors.gray)
                end
                ui.status("Action", (plan.action or "HOLD") .. " / " ..
                    (plan.actuatorState or "WAITING"),
                    (plan.action == "CUT FLOW" or plan.actuatorState == "FAULT") and colors.red or colors.white)
            end
            print("")
            term.setTextColor(colors.lime)
            write("[ AUTOMATIC ] ")
            term.setTextColor(colors.gray)
            print("[ MANUAL - LOCKED ]")
            print("Targets learned automatically; manual tuning LOCKED")
            term.setTextColor(colors.white)
            buttons.previous = ui.inlineButton("< PREVIOUS", colors.cyan)
            write(" ")
            buttons.next = ui.inlineButton("NEXT >", colors.cyan)
            write(" ")
            buttons.back = ui.inlineButton("BACK", colors.cyan)
            print("")
            if #turbines > 0 then
                buttons.retry = ui.button("RETRY CALIBRATION", colors.orange)
            else
                buttons.retry = nil
            end
        end
        while true do
            draw()
            local event, value, message, protocol = os.pullEvent()
            local x, y = ui.eventPoint(event, value, message, protocol)
            if event == "key" and value == keys.b then return
            elseif ((event == "key" and value == keys.left) or ui.hit(buttons.previous, x, y)) and #turbines > 0 then
                selected = ((selected - 2) % #turbines) + 1
            elseif ((event == "key" and value == keys.right) or ui.hit(buttons.next, x, y)) and #turbines > 0 then
                selected = (selected % #turbines) + 1
            elseif ui.hit(buttons.retry, x, y) and #turbines > 0 then
                turbineGovernor.resetCalibration(governorMemory, config.control,
                    turbines[selected].name)
                configStore.save(config)
                pollReactors()
            elseif ui.hit(buttons.back, x, y) then return
            elseif event == "rednet_message" then handleNetwork(value, message, protocol)
            elseif event == "peripheral" or event == "peripheral_detach" then
                if maintenance or config.discovery.defaultMode == "manual" then registryStale = true else rescan() end
            elseif event == "timer" and value == reactorTimer then
                pollReactors()
                broadcastSnapshots()
                reactorTimer = os.startTimer(1)
            end
        end
    end

    local function restoreTimersAfterTextInput()
        if reactorTimer then os.cancelTimer(reactorTimer) end
        pollReactors()
        reactorTimer = os.startTimer(1)
        if maintenance then
            if maintenanceTimer then os.cancelTimer(maintenanceTimer) end
            if countdownTimer then os.cancelTimer(countdownTimer) end
            local remaining = remainingMaintenance()
            if remaining <= 0 then
                stopMaintenance()
            else
                maintenanceTimer = os.startTimer(remaining)
                countdownTimer = os.startTimer(1)
            end
        end
    end

    local function namingSettings()
        local selected = 1
        local buttons = {}
        while true do
            ui.header("DEVICE NAMES", "Persistent local aliases")
            if #devices == 0 then
                ui.status("Status", "NO DEVICES FOUND", colors.orange)
            else
                if selected > #devices then selected = #devices end
                local device = devices[selected]
                ui.status("Device", ("%d/%d"):format(selected, #devices), colors.cyan)
                ui.status("Category", string.upper(device.category))
                ui.status("Name", config.deviceAliases[device.name] or "Not set")
                ui.status("Peripheral", device.name, colors.gray)
            end
            print("")
            buttons.previous = ui.button("< PREVIOUS", colors.cyan)
            buttons.next = ui.button("NEXT >", colors.cyan)
            buttons.edit = ui.button("EDIT NAME (keyboard)", colors.cyan)
            buttons.clear = ui.button("CLEAR NAME", colors.orange)
            buttons.back = ui.button("BACK", colors.cyan)

            local event, value, message, protocol = os.pullEvent()
            local touchX, touchY = ui.eventPoint(event, value, message, protocol)
            if (event == "key" and value == keys.b) or ui.hit(buttons.back, touchX, touchY) then
                return
            elseif ((event == "key" and value == keys.left) or ui.hit(buttons.previous, touchX, touchY)) and #devices > 0 then
                selected = ((selected - 2) % #devices) + 1
            elseif ((event == "key" and value == keys.right) or ui.hit(buttons.next, touchX, touchY)) and #devices > 0 then
                selected = (selected % #devices) + 1
            elseif ((event == "key" and value == keys.c) or ui.hit(buttons.clear, touchX, touchY)) and #devices > 0 then
                config.deviceAliases[devices[selected].name] = nil
                saveConfig()
            elseif ((event == "key" and value == keys.e) or ui.hit(buttons.edit, touchX, touchY)) and #devices > 0 then
                ui.prepare()
                print("Peripheral: " .. devices[selected].name)
                print("Enter a custom name (blank cancels):")
                write("> ")
                local alias = read()
                alias = alias:gsub("^%s+", ""):gsub("%s+$", "")
                if alias ~= "" then
                    config.deviceAliases[devices[selected].name] = alias
                    saveConfig()
                end
                restoreTimersAfterTextInput()
            elseif event == "rednet_message" then
                handleNetwork(value, message, protocol)
            elseif event == "peripheral" or event == "peripheral_detach" then
                if maintenance or config.discovery.defaultMode == "manual" then registryStale = true else rescan() end
            elseif event == "timer" then
                if maintenance and value == maintenanceTimer then
                    stopMaintenance()
                elseif maintenance and value == countdownTimer then
                    countdownTimer = os.startTimer(1)
                elseif value == reactorTimer then
                    pollReactors()
                    broadcastSnapshots()
                    reactorTimer = os.startTimer(1)
                end
            end
        end
    end

    local function powerSettings()
        local units = { "FE", "RF", "J", "EU" }
        local buttons = {}
        while true do
            ui.header("POWER DISPLAY", "Global energy formatting")
            ui.status("Display unit", config.power.unit, colors.cyan)
            ui.status("Conversion", ("1 FE = %g %s"):format(config.power.ratios[config.power.unit], config.power.unit))
            ui.status("Number format", string.upper(config.power.numberFormat))
            ui.status("Compact precision", config.power.decimals .. " decimal" .. (config.power.decimals == 1 and "" or "s"))
            ui.status("Example", powerFormat.power(2347819624112, config.power, true), colors.lime)
            print("")
            buttons.unit = ui.button("CHANGE UNIT", colors.cyan)
            buttons.format = ui.button("COMPACT / FULL", colors.cyan)
            buttons.precision = ui.button("CHANGE PRECISION", colors.cyan)
            buttons.ratio = ui.button("SET RATIO (keyboard)", colors.cyan)
            buttons.back = ui.button("BACK", colors.cyan)

            local event, value, message, protocol = os.pullEvent()
            local touchX, touchY = ui.eventPoint(event, value, message, protocol)
            if (event == "key" and value == keys.b) or ui.hit(buttons.back, touchX, touchY) then
                return
            elseif (event == "key" and value == keys.u) or ui.hit(buttons.unit, touchX, touchY) then
                local current = 1
                for index, unit in ipairs(units) do if unit == config.power.unit then current = index end end
                config.power.unit = units[(current % #units) + 1]
                saveConfig()
            elseif (event == "key" and value == keys.n) or ui.hit(buttons.format, touchX, touchY) then
                config.power.numberFormat = config.power.numberFormat == "compact" and "full" or "compact"
                saveConfig()
            elseif (event == "key" and value == keys.p) or ui.hit(buttons.precision, touchX, touchY) then
                config.power.decimals = config.power.decimals == 1 and 2 or 1
                saveConfig()
            elseif (event == "key" and value == keys.r) or ui.hit(buttons.ratio, touchX, touchY) then
                ui.prepare()
                print(("Current: 1 FE = %g %s"):format(config.power.ratios[config.power.unit], config.power.unit))
                print("Enter the new positive ratio (blank cancels):")
                write("> ")
                local answer = read()
                local ratio = tonumber(answer)
                if ratio and ratio > 0 then
                    config.power.ratios[config.power.unit] = ratio
                    saveConfig()
                end
                restoreTimersAfterTextInput()
            elseif event == "rednet_message" then
                handleNetwork(value, message, protocol)
            elseif event == "peripheral" or event == "peripheral_detach" then
                if maintenance or config.discovery.defaultMode == "manual" then registryStale = true else rescan() end
            elseif event == "timer" then
                if maintenance and value == maintenanceTimer then
                    stopMaintenance()
                elseif maintenance and value == countdownTimer then
                    countdownTimer = os.startTimer(1)
                elseif value == reactorTimer then
                    pollReactors()
                    broadcastSnapshots()
                    reactorTimer = os.startTimer(1)
                end
            end
        end
    end

    local function alarmSettings()
        local buttons = {}
        local function editNumber(label, current, minimum, maximum)
            ui.prepare()
            print(label .. ": " .. tostring(current))
            print(("Enter a value from %g to %g (blank cancels):"):format(minimum, maximum))
            write("> ")
            local answer = read()
            local value = tonumber(answer)
            if value and value >= minimum and value <= maximum then return value end
            return current
        end

        while true do
            ui.header("ALARM SETTINGS", "Audible safety notifications")
            ui.status("Audible alarms", config.alarms.enabled and "ENABLED" or "DISABLED",
                config.alarms.enabled and colors.lime or colors.gray)
            ui.status("Low fuel", config.alarms.lowFuel .. "%", colors.orange)
            ui.status("Critical fuel", config.alarms.criticalFuel .. "%", colors.red)
            ui.status("Confirmation", config.alarms.confirmSamples .. " readings")
            ui.status("Volume", config.alarms.volume)
            print("")
            buttons.enabled = ui.button("ENABLE / DISABLE", colors.cyan)
            buttons.low = ui.button("LOW FUEL (keyboard)", colors.orange)
            buttons.critical = ui.button("CRITICAL FUEL (keyboard)", colors.red)
            buttons.volume = ui.button("CHANGE VOLUME", colors.cyan)
            buttons.test = ui.button("TEST SPEAKER", colors.cyan)
            buttons.back = ui.button("BACK", colors.cyan)

            local event, value, message, protocol = os.pullEvent()
            local touchX, touchY = ui.eventPoint(event, value, message, protocol)
            if (event == "key" and value == keys.b) or ui.hit(buttons.back, touchX, touchY) then
                return
            elseif (event == "key" and value == keys.e) or ui.hit(buttons.enabled, touchX, touchY) then
                config.alarms.enabled = not config.alarms.enabled
                saveConfig()
            elseif (event == "key" and value == keys.l) or ui.hit(buttons.low, touchX, touchY) then
                config.alarms.lowFuel = editNumber("Low-fuel warning", config.alarms.lowFuel, 1, 99)
                if config.alarms.criticalFuel > config.alarms.lowFuel then
                    config.alarms.criticalFuel = config.alarms.lowFuel
                end
                saveConfig()
                restoreTimersAfterTextInput()
            elseif (event == "key" and value == keys.c) or ui.hit(buttons.critical, touchX, touchY) then
                config.alarms.criticalFuel = editNumber("Critical-fuel warning",
                    config.alarms.criticalFuel, 0, config.alarms.lowFuel)
                saveConfig()
                restoreTimersAfterTextInput()
            elseif (event == "key" and value == keys.v) or ui.hit(buttons.volume, touchX, touchY) then
                config.alarms.volume = config.alarms.volume + 0.5
                if config.alarms.volume > 3 then config.alarms.volume = 0.5 end
                saveConfig()
            elseif (event == "key" and value == keys.x) or ui.hit(buttons.test, touchX, touchY) then
                playSound("minecraft:block.note_block.bell", 0.8, true)
            elseif event == "rednet_message" then
                handleNetwork(value, message, protocol)
            elseif event == "peripheral" or event == "peripheral_detach" then
                modemCount = network.openAll()
                if maintenance or config.discovery.defaultMode == "manual" then registryStale = true else rescan() end
            elseif event == "timer" then
                if maintenance and value == maintenanceTimer then
                    stopMaintenance()
                elseif maintenance and value == countdownTimer then
                    countdownTimer = os.startTimer(1)
                elseif value == reactorTimer then
                    pollReactors()
                    broadcastSnapshots()
                    reactorTimer = os.startTimer(1)
                end
            end
        end
    end

    local function settings()
        local buttons = {}
        local function changeTimeout(direction)
            local currentIndex = 1
            for index, timeout in ipairs(timeoutChoices) do
                if timeout == config.discovery.maintenanceTimeout then
                    currentIndex = index
                    break
                end
            end
            local nextIndex = ((currentIndex - 1 + direction) % #timeoutChoices) + 1
            config.discovery.maintenanceTimeout = timeoutChoices[nextIndex]
            saveConfig()
            if maintenance then
                if maintenanceTimer then os.cancelTimer(maintenanceTimer) end
                startMaintenance()
            end
        end

        local function renderSettings()
            ui.header("SETTINGS", "System preferences")
            ui.status("Default mode", config.discovery.defaultMode == "event" and "AUTOMATIC" or "MANUAL", colors.cyan)
            ui.status("Maintenance timeout", math.floor(config.discovery.maintenanceTimeout / 60) .. " minutes")
            ui.status("Current mode", modeName(), maintenance and colors.orange or colors.white)
            ui.status("Peripheral names", config.ui.showPeripheralNames and "SHOWN" or "HIDDEN")
            ui.status("Power display", config.power.unit .. " / " .. string.upper(config.power.numberFormat))
            if registryStale then
                ui.status("Registry", "OUTDATED", colors.orange)
            end
            print("")
            buttons.defaultMode = ui.inlineButton("DEFAULT MODE", colors.cyan)
            write(" ")
            buttons.names = ui.inlineButton("SHOW/HIDE NAMES", colors.cyan)
            print("")
            buttons.timeoutPrevious = ui.inlineButton("< TIMEOUT", colors.cyan)
            write(" ")
            buttons.timeoutNext = ui.inlineButton("TIMEOUT >", colors.cyan)
            print("")
            if maintenance then
                buttons.maintenance = ui.button("FINISH MAINTENANCE", colors.orange)
            else
                buttons.maintenance = ui.button("BEGIN MAINTENANCE", colors.orange)
            end
            buttons.naming = ui.inlineButton("NAME DEVICES", colors.cyan)
            write(" ")
            buttons.power = ui.inlineButton("POWER DISPLAY", colors.cyan)
            print("")
            buttons.alarms = ui.inlineButton("ALARM SETTINGS", colors.cyan)
            write(" ")
            buttons.back = ui.inlineButton("BACK", colors.cyan)
            print("")
        end

        while true do
            renderSettings()
            local event, value, message, protocol = os.pullEvent()
            local touchX, touchY = ui.eventPoint(event, value, message, protocol)
            if (event == "key" and value == keys.b) or ui.hit(buttons.back, touchX, touchY) then
                return
            elseif (event == "key" and value == keys.d) or ui.hit(buttons.defaultMode, touchX, touchY) then
                config.discovery.defaultMode = config.discovery.defaultMode == "event" and "manual" or "event"
                saveConfig()
                if not maintenance and config.discovery.defaultMode == "event" and registryStale then
                    rescan(true)
                end
            elseif (event == "key" and value == keys.left) or ui.hit(buttons.timeoutPrevious, touchX, touchY) then
                changeTimeout(-1)
            elseif (event == "key" and value == keys.right) or ui.hit(buttons.timeoutNext, touchX, touchY) then
                changeTimeout(1)
            elseif ((event == "key" and value == keys.m) or ui.hit(buttons.maintenance, touchX, touchY)) and not maintenance then
                startMaintenance()
            elseif ((event == "key" and value == keys.f) or ui.hit(buttons.maintenance, touchX, touchY)) and maintenance then
                stopMaintenance()
            elseif (event == "key" and value == keys.h) or ui.hit(buttons.names, touchX, touchY) then
                config.ui.showPeripheralNames = not config.ui.showPeripheralNames
                saveConfig()
            elseif (event == "key" and value == keys.n) or ui.hit(buttons.naming, touchX, touchY) then
                namingSettings()
            elseif (event == "key" and value == keys.p) or ui.hit(buttons.power, touchX, touchY) then
                powerSettings()
            elseif (event == "key" and value == keys.a) or ui.hit(buttons.alarms, touchX, touchY) then
                alarmSettings()
            elseif event == "rednet_message" then
                handleNetwork(value, message, protocol)
            elseif event == "peripheral" or event == "peripheral_detach" then
                if maintenance or config.discovery.defaultMode == "manual" then
                    registryStale = true
                else
                    rescan()
                end
            elseif event == "timer" then
                if maintenance and value == maintenanceTimer then
                    stopMaintenance()
                elseif maintenance and value == countdownTimer then
                    countdownTimer = os.startTimer(1)
                elseif value == reactorTimer then
                    pollReactors()
                    broadcastSnapshots()
                    reactorTimer = os.startTimer(1)
                end
            end
        end
    end

    local function reactorView()
        local selected = 1
        local viewSilenceButton
        local previousButton
        local nextButton
        local backButton
        local calibrationButton
        local notice

        local function formatValue(value, suffix)
            if value == nil then return "N/A" end
            return ("%.1f%s"):format(value, suffix or "")
        end

        local function formatRodLayout(reactor, exposure)
            local minimum = tonumber(reactor.controlRodMinimum)
            local maximum = tonumber(reactor.controlRodMaximum)
            local range
            if minimum == nil or maximum == nil then
                range = "N/A"
            elseif math.abs(maximum - minimum) < 0.05 then
                range = ("%.0f%%"):format(minimum)
            else
                range = ("%.0f-%.0f%%"):format(minimum, maximum)
            end
            return ("%s / %s eq"):format(range,
                exposure ~= nil and ("%.2f"):format(exposure) or "N/A")
        end

        local function reactorByName(name)
            for _, candidate in ipairs(reactors) do
                if candidate.name == name then return candidate end
            end
        end

        local function serviceEvent(event, value, message, protocol)
            if event == "rednet_message" then
                handleNetwork(value, message, protocol)
            elseif event == "peripheral" or event == "peripheral_detach" then
                if maintenance or config.discovery.defaultMode == "manual" then
                    registryStale = true
                else
                    rescan()
                    updateAlarm()
                end
            elseif event == "timer" then
                if maintenance and value == maintenanceTimer then
                    stopMaintenance()
                elseif maintenance and value == countdownTimer then
                    countdownTimer = os.startTimer(1)
                elseif value == reactorTimer then
                    pollReactors()
                    broadcastSnapshots()
                    reactorTimer = os.startTimer(1)
                end
            end
        end

        local function confirm(title, lines, yesLabel, noLabel)
            local yesButton, noButton
            local function drawConfirm()
                ui.header(title, "Confirmation required")
                for _, line in ipairs(lines or {}) do print(line) end
                print("")
                yesButton = ui.inlineButton(yesLabel or "YES", colors.lime)
                write("   ")
                noButton = ui.inlineButton(noLabel or "NO", colors.orange)
                print("")
            end
            while true do
                drawConfirm()
                local event, value, message, protocol = os.pullEvent()
                local touchX, touchY = ui.eventPoint(event, value, message, protocol)
                if (event == "key" and value == keys.y) or
                   ui.hit(yesButton, touchX, touchY) then
                    return true
                elseif (event == "key" and (value == keys.n or value == keys.b)) or
                       ui.hit(noButton, touchX, touchY) then
                    return false
                else
                    serviceEvent(event, value, message, protocol)
                end
            end
        end

        local function calibrationView(reactorName, maintenanceEnabledHere)
            local buttons = {}
            local calibrationNotice

            local function formatUpdatedAt(value)
                value = tonumber(value)
                if not value or value <= 0 then return "UNKNOWN" end
                local ok, formatted = pcall(os.date, "!%Y-%m-%d %H:%M UTC", value)
                return ok and formatted or tostring(value)
            end

            local function drawCalibration()
                local reactor = reactorByName(reactorName)
                ui.header("REACTOR CALIBRATION", deviceName(reactorName))
                ui.status("Control mode", maintenance and "MAINTENANCE" or "AUTOMATIC",
                    maintenance and colors.orange or colors.lime)
                if not reactor then
                    ui.status("Status", "REACTOR NOT FOUND", colors.red)
                    buttons = { close = ui.button("CLOSE", colors.cyan) }
                    return
                end
                if reactor.mode ~= "steam" then
                    ui.status("Status", "POWER REACTOR / CALIBRATION NOT REQUIRED",
                        colors.orange)
                    print("")
                    buttons = { close = ui.button("CLOSE", colors.cyan) }
                    return
                end

                local plan = reactor.governor or {}
                local profile = (config.control.reactorProfiles or {})[reactorName]
                local phase = plan.calibrationPhase or
                    (profile and "LEARNED" or "NOT ACTIVE")
                local state = plan.state or "WAITING FOR GOVERNOR UPDATE"
                ui.status("Calibration", phase .. " / " .. state,
                    plan.recalibrating and colors.orange or colors.lime)
                ui.status("Target output", plan.targetSteam and
                    ("%.0f mB/t"):format(plan.targetSteam) or
                    "WAITING FOR TRUSTED DEMAND")
                local sampleCount = tonumber(plan.averageSteamSamples) or 0
                local sampleTarget = math.max(3,
                    math.floor(tonumber(config.control.reactorSteamAverageSamples) or 10))
                local responseCount = tonumber(plan.processStableSamples) or 0
                local responseTarget = math.max(3,
                    math.floor(tonumber(config.control.reactorLearningSamples) or 8))
                local output = plan.averageSteamProduction and
                    ("%.0f mB/t avg"):format(plan.averageSteamProduction) or
                    reactor.steamProduction and
                    ("%.0f mB/t raw"):format(reactor.steamProduction) or "N/A"
                ui.status("Output / progress", ("%s [%d/%d; %d/%d]"):format(
                    output, sampleCount, sampleTarget, responseCount, responseTarget))
                local commandTarget = math.max(2,
                    math.floor(tonumber(config.control.reactorCommandSamples) or 3))
                ui.status("Actuator", ("%s / %s [%d/%d]"):format(
                    tostring(plan.action or "HOLD"),
                    tostring(plan.actuatorState or "WAITING"),
                    tonumber(plan.actionSamples) or 0, commandTarget),
                    plan.actuatorState == "FAULT" and colors.red or colors.lightGray)
                ui.status("Current setting", formatRodLayout(reactor,
                    plan.currentRodExposure))
                ui.status("Saved calibration", profile and
                    (("%.2f eq / %.0f mB/t"):format(
                        tonumber(profile.exposure) or 0,
                        tonumber(profile.targetSteam) or 0)) or "NONE")
                ui.status("Last calibrated", profile and
                    formatUpdatedAt(profile.updatedAt) or "NEVER")
                if plan.reason then ui.status("Governor", plan.reason, colors.lightGray) end
                if calibrationNotice then
                    print("")
                    ui.status("Result", calibrationNotice.text, calibrationNotice.colour)
                end
                print("")
                -- Keep the four actions on two rows. A fourth full-width print
                -- could advance past the mirrored 19-row terminal, scroll the
                -- display, and leave every recorded touch target one row low.
                buttons.delete = ui.inlineButton("DELETE CALIBRATION DATA", colors.red)
                write(" ")
                buttons.recalibrate = ui.inlineButton("RECALIBRATE", colors.orange)
                print("")
                buttons.save = ui.inlineButton("SAVE CURRENT REACTOR SETUP", colors.lime)
                write(" ")
                buttons.close = ui.inlineButton("CLOSE", colors.cyan)
            end

            pollReactors()
            while true do
                drawCalibration()
                local event, value, message, protocol = os.pullEvent()
                local touchX, touchY = ui.eventPoint(event, value, message, protocol)
                local reactor = reactorByName(reactorName)
                if (event == "key" and value == keys.b) or
                   ui.hit(buttons.close, touchX, touchY) then
                    if maintenanceEnabledHere and maintenance and confirm(
                        "MAINTENANCE MODE",
                        { "Disable Maintenance Mode and", "return control to HELIOS?" },
                        "YES", "NO") then
                        stopMaintenance()
                    end
                    return
                elseif reactor and reactor.mode == "steam" and
                       ui.hit(buttons.delete, touchX, touchY) then
                    if confirm("DELETE CALIBRATION",
                        { "Delete the saved calibration for", deviceName(reactorName) .. "?",
                          "Rod positions will not change immediately." },
                        "DELETE", "CANCEL") then
                        reactorGovernor.deleteCalibration(reactorGovernorMemory,
                            config.control, reactorName)
                        saveConfig()
                        calibrationNotice = { text = "CALIBRATION DATA DELETED", colour = colors.orange }
                    end
                elseif reactor and reactor.mode == "steam" and
                       ui.hit(buttons.recalibrate, touchX, touchY) then
                    if confirm("RECALIBRATE REACTOR",
                        { "Close all rods and relearn this", "reactor from zero exposure?",
                          "HELIOS will resume automatic control." },
                        "RECALIBRATE", "CANCEL") then
                        reactorGovernor.beginRecalibration(reactorGovernorMemory,
                            config.control, reactorName)
                        saveConfig()
                        if maintenance then stopMaintenance() end
                        maintenanceEnabledHere = false
                        pollReactors()
                        calibrationNotice = { text = "RECALIBRATION STARTED", colour = colors.orange }
                    end
                elseif reactor and reactor.mode == "steam" and
                       ui.hit(buttons.save, touchX, touchY) then
                    if confirm("SAVE CURRENT SETUP",
                        { "Save the reactor's current rod layout", "as its learned calibration?" },
                        "SAVE", "CANCEL") then
                        local ok, reason = reactorGovernor.saveCurrentCalibration(
                            reactorGovernorMemory, config.control, reactor,
                            { now = os.epoch("utc") / 1000 })
                        if ok then
                            saveConfig()
                            calibrationNotice = { text = "CURRENT SETUP SAVED", colour = colors.lime }
                        else
                            calibrationNotice = { text = tostring(reason), colour = colors.red }
                        end
                    end
                else
                    serviceEvent(event, value, message, protocol)
                end
            end
        end

        local function draw()
            ui.header("REACTORS", "Live telemetry and steam governor")
            if #reactors == 0 then
                ui.status("Status", "NO REACTORS FOUND", colors.orange)
                print("")
                previousButton, nextButton, viewSilenceButton, calibrationButton = nil, nil, nil, nil
                backButton = ui.button("BACK", colors.cyan)
                return
            end
            if selected > #reactors then selected = #reactors end
            local reactor = reactors[selected]
            ui.status("Reactor", ("%d/%d %s"):format(selected, #reactors, deviceName(reactor.name)), colors.cyan)
            ui.status("Mode", string.upper(reactor.mode or "unknown"), reactor.mode == "unknown" and colors.orange or colors.lime)
            if reactor.error then
                ui.status("Telemetry", reactor.error, colors.red)
            else
                ui.status("State", reactor.active == true and "ACTIVE" or reactor.active == false and "OFFLINE" or "UNKNOWN",
                    reactor.active == true and colors.lime or colors.orange)
                ui.status("Fuel / use", ("%s / %s"):format(
                    formatValue(reactor.fuelPercent, "%"),
                    formatValue(reactor.fuelUse, " mB/t")))
                ui.status("Temps fuel/case", ("%s / %s"):format(
                    formatValue(reactor.fuelTemperature, " C"),
                    formatValue(reactor.casingTemperature, " C")))
                if reactor.mode == "steam" then
                    local plan = reactor.governor or {}
                    ui.status("Steam avg/target", ("%s / %s"):format(
                        formatValue(plan.averageSteamProduction or
                            reactor.steamProduction, ""),
                        formatValue(plan.targetSteam, " mB/t")), colors.cyan)
                    ui.status("Coolant / hot", ("%s / %s"):format(
                        formatValue(reactor.coolantPercent, "%"),
                        formatValue(reactor.hotFluidPercent, "%")))
                    ui.status("Rods range / exposed",
                        formatRodLayout(reactor, plan.currentRodExposure))
                    ui.status("Governor", (plan.state or "WAITING") .. " / " ..
                        (plan.actuatorState or "WAITING"),
                        (plan.trusted == false or plan.actuatorState == "FAULT") and
                            colors.red or
                        ((plan.state == "STEAM DEFICIT" or
                          plan.state == "STEAM SURPLUS") and colors.orange or colors.lime))
                else
                    ui.status("Power output", powerFormat.power(reactor.energyProduction, config.power, true), colors.cyan)
                    ui.status("Energy buffer", formatValue(reactor.energyPercent, "%"))
                end
            end
            print("")
            if currentAlarm then
                term.setTextColor(alarmColour())
                print("!! " .. currentAlarm.message)
                term.setTextColor(colors.white)
                local _, row = term.getCursorPos()
                print("[ SILENCE ALARM ]")
                viewSilenceButton = { y = row, x1 = 1, x2 = 17 }
            else
                viewSilenceButton = nil
            end
            previousButton = ui.inlineButton("< PREVIOUS", colors.cyan)
            write(" ")
            nextButton = ui.inlineButton("NEXT >", colors.cyan)
            write(" ")
            backButton = ui.inlineButton("BACK", colors.cyan)
            print("")
            local selectedReactor = reactors[selected]
            calibrationButton = selectedReactor and ui.button("CALIBRATION STATUS",
                selectedReactor.mode == "steam" and colors.lime or colors.gray) or nil
            if notice then ui.status("Result", notice, colors.orange) end
        end

        while true do
            draw()
            local event, value, x, y = os.pullEvent()
            if event == "key" and value == keys.b then
                return
            elseif event == "key" and value == keys.left and #reactors > 0 then
                selected = ((selected - 2) % #reactors) + 1
            elseif event == "key" and value == keys.right and #reactors > 0 then
                selected = (selected % #reactors) + 1
            elseif (event == "mouse_click" or event == "monitor_touch") and ui.hit(viewSilenceButton, x, y) then
                silenceCurrentAlarm()
            elseif (event == "mouse_click" or event == "monitor_touch") and ui.hit(previousButton, x, y) and #reactors > 0 then
                selected = ((selected - 2) % #reactors) + 1
            elseif (event == "mouse_click" or event == "monitor_touch") and ui.hit(nextButton, x, y) and #reactors > 0 then
                selected = (selected % #reactors) + 1
            elseif (event == "mouse_click" or event == "monitor_touch") and ui.hit(backButton, x, y) then
                return
            elseif (event == "mouse_click" or event == "monitor_touch") and
                   ui.hit(calibrationButton, x, y) and #reactors > 0 then
                local reactor = reactors[selected]
                local enabledHere = false
                if reactor.mode == "steam" and not maintenance then
                    enabledHere = confirm("CALIBRATION STATUS",
                        { "Enable Maintenance Mode?", "",
                          "This prevents HELIOS from changing", "the reactor while settings are reviewed." },
                        "YES", "NO")
                    if enabledHere then startMaintenance() end
                end
                calibrationView(reactor.name, enabledHere)
            elseif event == "rednet_message" then
                handleNetwork(value, x, y)
            elseif event == "peripheral" or event == "peripheral_detach" then
                if maintenance or config.discovery.defaultMode == "manual" then
                    registryStale = true
                else
                    rescan()
                    updateAlarm()
                end
            elseif event == "timer" then
                if maintenance and value == maintenanceTimer then
                    stopMaintenance()
                elseif maintenance and value == countdownTimer then
                    countdownTimer = os.startTimer(1)
                elseif value == reactorTimer then
                    pollReactors()
                    broadcastSnapshots()
                    reactorTimer = os.startTimer(1)
                end
            end
        end
    end

    local function turbineView()
        local selected = 1
        local previousButton, nextButton, backButton

        local function formatValue(value, suffix)
            if value == nil then return "N/A" end
            return ("%.1f%s"):format(value, suffix or "")
        end

        local function draw()
            ui.header("TURBINES", "Live telemetry and governor plan")
            if #turbines == 0 then
                ui.status("Status", "NO TURBINES FOUND", colors.orange)
                print("")
                previousButton, nextButton = nil, nil
                backButton = ui.button("BACK", colors.cyan)
                return
            end
            if selected > #turbines then selected = #turbines end
            local turbine = turbines[selected]
            ui.status("Turbine", ("%d/%d %s"):format(selected, #turbines, deviceName(turbine.name)), colors.cyan)
            if turbine.error then
                ui.status("Telemetry", turbine.error, colors.red)
            else
                ui.status("State", turbine.active == true and "ACTIVE" or turbine.active == false and "OFFLINE" or "UNKNOWN",
                    turbine.active == true and colors.lime or colors.orange)
                ui.status("Rotor speed", formatValue(turbine.rotorSpeed, " RPM"), colors.cyan)
                local plan = turbine.governor or {}
                ui.status("Governor", (plan.state or "WAITING") .. " / " ..
                    (plan.actuatorState or "WAITING"),
                    (plan.trusted == false or plan.actuatorState == "FAULT" or
                        plan.state == "CALIBRATION FAILED") and colors.red or colors.lime)
                ui.status("Power output", powerFormat.power(turbine.energyProduction, config.power, true), colors.cyan)
                ui.status("Energy buffer", formatValue(turbine.energyPercent, "%"))
                if plan.currentFlow ~= nil and plan.recommendedFlow ~= nil then
                    ui.status("Flow actual/set/plan", ("%s / %.0f -> %.0f"):format(
                        plan.actualFlow and ("%.0f"):format(plan.actualFlow) or "N/A",
                        plan.currentFlow, plan.recommendedFlow), colors.cyan)
                else
                    ui.status("Flow actual/set/plan", "N/A / HOLD", colors.gray)
                end
                ui.status("Tanks in / out", formatValue(turbine.inputPercent, "%") .. " / " ..
                    formatValue(turbine.outputPercent, "%"))
                ui.status("Inductor", turbine.inductorEngaged == true and "ENGAGED" or turbine.inductorEngaged == false and "DISENGAGED" or "N/A")
            end
            print("")
            previousButton = ui.inlineButton("< PREVIOUS", colors.cyan)
            write(" ")
            nextButton = ui.inlineButton("NEXT >", colors.cyan)
            write(" ")
            backButton = ui.inlineButton("BACK", colors.cyan)
            print("")
        end

        while true do
            draw()
            local event, value, message, protocol = os.pullEvent()
            local touchX, touchY = ui.eventPoint(event, value, message, protocol)
            if event == "key" and value == keys.b then
                return
            elseif event == "key" and value == keys.left and #turbines > 0 then
                selected = ((selected - 2) % #turbines) + 1
            elseif event == "key" and value == keys.right and #turbines > 0 then
                selected = (selected % #turbines) + 1
            elseif ui.hit(previousButton, touchX, touchY) and #turbines > 0 then
                selected = ((selected - 2) % #turbines) + 1
            elseif ui.hit(nextButton, touchX, touchY) and #turbines > 0 then
                selected = (selected % #turbines) + 1
            elseif ui.hit(backButton, touchX, touchY) then
                return
            elseif event == "rednet_message" then
                handleNetwork(value, message, protocol)
            elseif event == "peripheral" or event == "peripheral_detach" then
                if maintenance or config.discovery.defaultMode == "manual" then registryStale = true else rescan() end
            elseif event == "timer" then
                if maintenance and value == maintenanceTimer then
                    stopMaintenance()
                elseif maintenance and value == countdownTimer then
                    countdownTimer = os.startTimer(1)
                elseif value == reactorTimer then
                    pollReactors()
                    broadcastSnapshots()
                    reactorTimer = os.startTimer(1)
                end
            end
        end
    end

    local function storageView()
        local selected = 1
        local previousButton, nextButton, backButton

        local function formatPercent(value)
            if value == nil then return "N/A" end
            return ("%.1f%%"):format(value)
        end

        local function signedPower(value)
            if value == nil then return "N/A" end
            local formatted = powerFormat.power(value, config.power, true)
            if value > 0 then return "+" .. formatted end
            return formatted
        end

        local function draw()
            ui.header("ENERGY STORAGE", "Universal read-only telemetry")
            if #storages == 0 then
                ui.status("Status", "NO SUPPORTED STORAGE FOUND", colors.orange)
                print("")
                print("Generic support requires stored + capacity methods.")
                previousButton, nextButton = nil, nil
                backButton = ui.button("BACK", colors.cyan)
                return
            end
            if selected > #storages then selected = #storages end
            local storage = storages[selected]
            ui.status("Storage", ("%d/%d %s"):format(selected, #storages, deviceName(storage.name)), colors.cyan)
            ui.status("Driver", storage.adapterName or "UNKNOWN", storage.fallback and colors.orange or colors.lime)
            if storage.error then
                ui.status("Telemetry", storage.error, colors.red)
            else
                ui.status("Charge", formatPercent(storage.percent), colors.cyan)
                ui.status("Stored", powerFormat.power(storage.stored, config.power, false) .. " / " .. powerFormat.power(storage.capacity, config.power, false))
                ui.status("Input", powerFormat.power(storage.input, config.power, true))
                ui.status("Output", powerFormat.power(storage.output, config.power, true))
                ui.status("Net", signedPower(storage.net), storage.net and (storage.net > 0 and colors.lime or storage.net < 0 and colors.orange or colors.white) or colors.gray)
                ui.status("State", storage.state or "UNKNOWN", storage.state == "CHARGING" and colors.lime or storage.state == "DRAINING" and colors.orange or colors.white)
                if storage.state == "CHARGING" then
                    ui.status("Full in", storageAdapter.formatETA(storage))
                elseif storage.state == "DRAINING" then
                    ui.status("Empty in", storageAdapter.formatETA(storage))
                end
                local details = storage.details or {}
                if details.transferCap ~= nil then
                    ui.status("Max I/O", powerFormat.power(details.transferCap, config.power, true))
                end
                if details.cells ~= nil or details.providers ~= nil then
                    ui.status("Matrix", ("%s cells / %s providers"):format(tostring(details.cells or "?"), tostring(details.providers or "?")))
                end
            end
            print("")
            previousButton = ui.inlineButton("< PREVIOUS", colors.cyan)
            write(" ")
            nextButton = ui.inlineButton("NEXT >", colors.cyan)
            write(" ")
            backButton = ui.inlineButton("BACK", colors.cyan)
            print("")
        end

        while true do
            draw()
            local event, value, message, protocol = os.pullEvent()
            local touchX, touchY = ui.eventPoint(event, value, message, protocol)
            if event == "key" and value == keys.b then
                return
            elseif event == "key" and value == keys.left and #storages > 0 then
                selected = ((selected - 2) % #storages) + 1
            elseif event == "key" and value == keys.right and #storages > 0 then
                selected = (selected % #storages) + 1
            elseif ui.hit(previousButton, touchX, touchY) and #storages > 0 then
                selected = ((selected - 2) % #storages) + 1
            elseif ui.hit(nextButton, touchX, touchY) and #storages > 0 then
                selected = (selected % #storages) + 1
            elseif ui.hit(backButton, touchX, touchY) then
                return
            elseif event == "rednet_message" then
                handleNetwork(value, message, protocol)
            elseif event == "peripheral" or event == "peripheral_detach" then
                if maintenance or config.discovery.defaultMode == "manual" then registryStale = true else rescan() end
            elseif event == "timer" then
                if maintenance and value == maintenanceTimer then
                    stopMaintenance()
                elseif maintenance and value == countdownTimer then
                    countdownTimer = os.startTimer(1)
                elseif value == reactorTimer then
                    pollReactors()
                    broadcastSnapshots()
                    reactorTimer = os.startTimer(1)
                end
            end
        end
    end

    rescan(true)
    pollReactors()
    reactorTimer = os.startTimer(1)
    render()
    while true do
        local event, value, x, y = os.pullEvent()
        if event == "key" and value == keys.q then
            ui.prepare()
            display.stop()
            return
        elseif event == "key" and value == keys.r then
            rescan(true)
            render()
        elseif event == "key" and value == keys.s then
            settings()
            render()
        elseif event == "key" and value == keys.v then
            reactorView()
            render()
        elseif event == "key" and value == keys.g then
            turbineView()
            render()
        elseif event == "key" and value == keys.e then
            storageView()
            render()
        elseif event == "key" and value == keys.c then
            controlView()
            render()
        elseif event == "monitor_touch" or event == "mouse_click" then
            local touchX, touchY = x, y
            if silenceButton and ui.hit(silenceButton, touchX, touchY) then
                silenceCurrentAlarm()
            elseif ui.hit(dashboardButtons.reactors, touchX, touchY) then reactorView()
            elseif ui.hit(dashboardButtons.turbines, touchX, touchY) then turbineView()
            elseif ui.hit(dashboardButtons.storage, touchX, touchY) then storageView()
            elseif ui.hit(dashboardButtons.control, touchX, touchY) then controlView()
            elseif ui.hit(dashboardButtons.rescan, touchX, touchY) then rescan(true)
            elseif ui.hit(dashboardButtons.settings, touchX, touchY) then settings()
            end
            render()
        elseif event == "rednet_message" then
            handleNetwork(value, x, y)
            render()
        elseif event == "peripheral" or event == "peripheral_detach" then
            if maintenance or config.discovery.defaultMode == "manual" then
                registryStale = true
            else
                rescan()
            end
            render()
        elseif event == "timer" then
            if maintenance and value == maintenanceTimer then
                stopMaintenance()
                render()
            elseif maintenance and value == countdownTimer then
                countdownTimer = os.startTimer(1)
                render()
            elseif value == reactorTimer then
                pollReactors()
                broadcastSnapshots()
                reactorTimer = os.startTimer(1)
                render()
            end
        elseif event == "term_resize" then
            render()
        end
    end
end

return mainframe
]=],

    ["mainframe/reactor_adapter.lua"] = [=[
local adapter = {}

local function readAny(name, availableMethods, candidates)
    for _, method in ipairs(candidates) do
        if availableMethods[method] then
            local ok, value = pcall(peripheral.call, name, method)
            if ok and value ~= nil then return value, method end
        end
    end
    return nil, nil
end

local function number(value)
    value = tonumber(value)
    if value ~= value then return nil end
    return value
end

local function percent(amount, maximum)
    amount, maximum = number(amount), number(maximum)
    if not amount or not maximum or maximum <= 0 then return nil end
    return math.max(0, math.min(100, amount / maximum * 100))
end

local function availableMethods(name)
    local methods = {}
    for _, method in ipairs(peripheral.getMethods(name) or {}) do
        methods[method] = true
    end
    return methods
end

local function rodLevels(name, methods, count)
    local levels
    if methods.getControlRodLevel and count and count > 0 then
        levels = {}
        for index = 0, count - 1 do
            local ok, value = pcall(peripheral.call, name, "getControlRodLevel", index)
            if not ok or tonumber(value) == nil then return nil end
            levels[index] = tonumber(value)
        end
    end
    if not levels and methods.getControlRodsLevels then
        local ok, values = pcall(peripheral.call, name, "getControlRodsLevels")
        if ok and type(values) == "table" then
            levels = {}
            local zeroBased = values[0] ~= nil
            for index = 0, (count or #values) - 1 do
                levels[index] = tonumber(values[zeroBased and index or (index + 1)])
                if levels[index] == nil then return nil end
            end
        end
    end
    return levels
end

local function rodSummary(levels)
    if type(levels) ~= "table" then return nil, nil, nil end
    local total, count, minimum, maximum = 0, 0
    for _, value in pairs(levels) do
        value = number(value)
        if value then
            total, count = total + value, count + 1
            minimum = minimum and math.min(minimum, value) or value
            maximum = maximum and math.max(maximum, value) or value
        end
    end
    if count == 0 then return nil, nil, nil end
    return total / count, minimum, maximum
end

function adapter.read(device)
    local name = device.name
    local reactor = { name = name, available = peripheral.isPresent(name) }
    if not reactor.available then
        reactor.error = "Peripheral unavailable"
        return reactor
    end

    local availableMethods = availableMethods(name)

    reactor.connected = readAny(name, availableMethods, { "getConnected", "isConnected", "mbIsConnected", "mbIsAssembled", "connected" })
    reactor.active = readAny(name, availableMethods, { "getActive", "isActive", "active" })
    reactor.activelyCooled = readAny(name, availableMethods, { "isActivelyCooled" })
    reactor.fuel = number(readAny(name, availableMethods, { "getFuelAmount", "fuelAmount" }))
    reactor.fuelMax = number(readAny(name, availableMethods, { "getFuelAmountMax", "getFuelCapacity", "fuelAmountMax" }))
    reactor.waste = number(readAny(name, availableMethods, { "getWasteAmount", "wasteAmount" }))
    reactor.fuelUse = number(readAny(name, availableMethods, { "getFuelConsumedLastTick", "getFuelConsumptionRate", "fuelConsumedLastTick" }))
    reactor.fuelTemperature = number(readAny(name, availableMethods, { "getFuelTemperature", "fuelTemperature" }))
    reactor.casingTemperature = number(readAny(name, availableMethods, { "getCasingTemperature", "casingTemperature" }))
    reactor.energy = number(readAny(name, availableMethods, { "getEnergyStored", "getEnergy", "energyStored" }))
    reactor.energyMax = number(readAny(name, availableMethods, { "getEnergyCapacity", "getMaxEnergyStored", "energyCapacity" }))
    reactor.energyProduction = number(readAny(name, availableMethods, { "getEnergyProducedLastTick", "getEnergyProductionRate", "energyProducedLastTick" }))
    reactor.coolant = number(readAny(name, availableMethods, { "getCoolantAmount", "coolantAmount" }))
    reactor.coolantMax = number(readAny(name, availableMethods, { "getCoolantAmountMax", "getCoolantCapacity", "coolantAmountMax" }))
    reactor.hotFluid = number(readAny(name, availableMethods, { "getHotFluidAmount", "hotFluidAmount" }))
    reactor.hotFluidMax = number(readAny(name, availableMethods, { "getHotFluidAmountMax", "getHotFluidCapacity", "hotFluidAmountMax" }))
    reactor.steamProduction = number(readAny(name, availableMethods, { "getHotFluidProducedLastTick", "getSteamProducedLastTick", "hotFluidProducedLastTick" }))
    reactor.controlRods = number(readAny(name, availableMethods, { "getNumberOfControlRods", "getControlRodCount" }))
    reactor.controlRodLevels = rodLevels(name, availableMethods, reactor.controlRods)
    reactor.controlRodLevel, reactor.controlRodMinimum, reactor.controlRodMaximum =
        rodSummary(reactor.controlRodLevels)
    if reactor.controlRodLevel and reactor.controlRods then
        reactor.controlRodExposure = reactor.controlRods *
            (100 - reactor.controlRodLevel) / 100
    end

    reactor.fuelPercent = percent(reactor.fuel, reactor.fuelMax)
    reactor.energyPercent = percent(reactor.energy, reactor.energyMax)
    reactor.coolantPercent = percent(reactor.coolant, reactor.coolantMax)
    reactor.hotFluidPercent = percent(reactor.hotFluid, reactor.hotFluidMax)

    if reactor.activelyCooled == true then
        reactor.mode = "steam"
    elseif reactor.activelyCooled == false then
        reactor.mode = "power"
    elseif (reactor.coolantMax and reactor.coolantMax > 0) or
       (reactor.hotFluidMax and reactor.hotFluidMax > 0) then
        reactor.mode = "steam"
    elseif reactor.energyMax or reactor.energyProduction then
        reactor.mode = "power"
    else
        reactor.mode = "unknown"
    end

    local useful = reactor.active ~= nil or reactor.fuel ~= nil or
        reactor.energyProduction ~= nil or reactor.steamProduction ~= nil
    if reactor.connected == false then
        reactor.error = "Reactor is not connected"
    elseif not useful then
        reactor.error = "No supported telemetry methods"
    end
    return reactor
end

function adapter.setAllControlRodLevels(reactor, requested)
    if type(reactor) ~= "table" or type(reactor.name) ~= "string" then
        return false, nil, "Invalid reactor identity"
    end
    if not peripheral.isPresent(reactor.name) then
        return false, nil, "Peripheral unavailable"
    end

    local methods = availableMethods(reactor.name)
    if not methods.setAllControlRodLevels or
       (not methods.getControlRodsLevels and not methods.getControlRodLevel) then
        return false, nil, "Verified control-rod control is unavailable"
    end

    requested = tonumber(requested)
    if not requested then return false, nil, "Invalid control-rod level" end
    requested = math.max(0, math.min(100, math.floor(requested + 0.5)))

    local ok, reason = pcall(peripheral.call, reactor.name,
        "setAllControlRodLevels", requested)
    if not ok then return false, nil, tostring(reason) end

    local count = tonumber(reactor.controlRods)
    if not count and methods.getNumberOfControlRods then
        local countOk, value = pcall(peripheral.call, reactor.name,
            "getNumberOfControlRods")
        if countOk then count = tonumber(value) end
    end
    local levels = rodLevels(reactor.name, methods, count)
    local average, minimum, maximum = rodSummary(levels)
    if average == nil then return false, nil, "Control-rod verification failed" end
    if minimum ~= requested or maximum ~= requested then
        return false, average, ("Requested %d%%; reactor reports %.0f-%.0f%%"):format(
            requested, minimum, maximum)
    end
    return true, average
end

function adapter.setActive(reactor, requested)
    if type(reactor) ~= "table" or type(reactor.name) ~= "string" then
        return false, nil, "Invalid reactor identity"
    end
    if not peripheral.isPresent(reactor.name) then
        return false, nil, "Peripheral unavailable"
    end

    local methods = availableMethods(reactor.name)
    if not methods.setActive then
        return false, nil, "Verified reactor activation control is unavailable"
    end
    local readMethod
    for _, candidate in ipairs({ "getActive", "isActive", "active" }) do
        if methods[candidate] then readMethod = candidate break end
    end
    if not readMethod then
        return false, nil, "Reactor active-state read-back is unavailable"
    end

    requested = requested == true
    local ok, reason = pcall(peripheral.call, reactor.name, "setActive", requested)
    if not ok then return false, nil, tostring(reason) end

    local readOk, actual = pcall(peripheral.call, reactor.name, readMethod)
    if not readOk or type(actual) ~= "boolean" then
        return false, nil, "Reactor activation verification failed"
    end
    if actual ~= requested then
        return false, actual, ("Requested reactor %s; reactor reports %s"):format(
            requested and "active" or "inactive",
            actual and "active" or "inactive")
    end
    return true, actual
end

local function exposureLevels(count, exposure)
    count = math.max(0, math.floor(tonumber(count) or 0))
    exposure = math.max(0, math.min(count, tonumber(exposure) or 0))
    if count < 1 then return {} end
    local exposurePoints = math.floor(exposure * 100 + 0.5)
    local pointsPerRod = math.floor(exposurePoints / count)
    local remainder = exposurePoints % count
    local levels = {}
    for index = 0, count - 1 do
        local exposedPercent = pointsPerRod + (index < remainder and 1 or 0)
        levels[index] = 100 - exposedPercent
    end
    return levels
end

local function exposureFromLevels(levels, count)
    local exposure = 0
    for index = 0, count - 1 do
        local level = tonumber(levels and levels[index])
        if level == nil then return nil end
        exposure = exposure + (100 - math.max(0, math.min(100, level))) / 100
    end
    return exposure
end

function adapter.setControlRodExposure(reactor, requestedExposure)
    if type(reactor) ~= "table" or type(reactor.name) ~= "string" then
        return false, nil, "Invalid reactor identity"
    end
    if not peripheral.isPresent(reactor.name) then
        return false, nil, "Peripheral unavailable"
    end

    local methods = availableMethods(reactor.name)
    if not methods.setControlRodLevel or not methods.getControlRodLevel then
        return false, nil, "Verified individual control-rod control is unavailable"
    end
    local count = math.floor(tonumber(reactor.controlRods) or 0)
    if count < 1 then return false, nil, "Control-rod count is unavailable" end

    local current = rodLevels(reactor.name, methods, count)
    if not current then return false, nil, "Control-rod read failed" end
    local wanted = exposureLevels(count, requestedExposure)

    -- Insert rods first, then withdraw rods. A partial failure therefore reduces
    -- reactor output instead of briefly exposing more fuel than requested.
    for pass = 1, 2 do
        for index = 0, count - 1 do
            local before, after = tonumber(current[index]), wanted[index]
            local safer = pass == 1 and after > before
            local stronger = pass == 2 and after < before
            if safer or stronger then
                local ok, reason = pcall(peripheral.call, reactor.name,
                    "setControlRodLevel", index, after)
                if not ok then
                    return false, exposureFromLevels(current, count), tostring(reason)
                end
                current[index] = after
            end
        end
    end

    local reported = rodLevels(reactor.name, methods, count)
    if not reported then return false, nil, "Control-rod verification failed" end
    for index = 0, count - 1 do
        if tonumber(reported[index]) ~= wanted[index] then
            return false, exposureFromLevels(reported, count),
                ("Rod %d requested %d%%; reactor reports %s%%"):format(
                    index, wanted[index], tostring(reported[index]))
        end
    end
    return true, exposureFromLevels(reported, count), wanted
end

function adapter.readAll(devices)
    local reactors = {}
    for _, device in ipairs(devices or {}) do
        if device.category == "reactor" then
            reactors[#reactors + 1] = adapter.read(device)
        end
    end
    return reactors
end

local function value(numberValue, suffix)
    if numberValue == nil then return "N/A" end
    return ("%.1f%s"):format(numberValue, suffix or "")
end

function adapter.printReport(reactors, config, formatter)
    print("HELIOS reactor telemetry")
    print("Reactors found: " .. #reactors)
    print("")
    for _, reactor in ipairs(reactors) do
        local alias = config.deviceAliases[reactor.name]
        local displayName = alias or reactor.name
        print(("[%s] %s"):format(string.upper(reactor.mode or "unknown"), displayName))
        if config.ui.showPeripheralNames and alias then print("  Peripheral: " .. reactor.name) end
        if reactor.error then
            print("  ERROR: " .. reactor.error)
        else
            print("  State: " .. (reactor.active == true and "ACTIVE" or reactor.active == false and "OFFLINE" or "UNKNOWN"))
            print("  Fuel: " .. value(reactor.fuelPercent, "%"))
            print("  Fuel use: " .. value(reactor.fuelUse, " mB/t"))
            print("  Fuel temp: " .. value(reactor.fuelTemperature, " C"))
            print("  Casing temp: " .. value(reactor.casingTemperature, " C"))
            if reactor.mode == "steam" then
                print("  Steam: " .. value(reactor.steamProduction, " mB/t"))
                print("  Coolant: " .. value(reactor.coolantPercent, "%"))
                print("  Hot fluid: " .. value(reactor.hotFluidPercent, "%"))
                print("  Rod insertion: " .. value(reactor.controlRodLevel, "%"))
                print("  Rod exposure: " .. value(reactor.controlRodExposure, " equivalents"))
            else
                print("  Power: " .. formatter.power(reactor.energyProduction, config.power, true))
                print("  Buffer: " .. value(reactor.energyPercent, "%"))
            end
        end
        print("")
    end
end

return adapter
]=],

    ["mainframe/reactor_governor.lua"] = [=[
local governor = {}
local clearCooldown
local saveProfile

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
    local total = 0
    for _, sample in ipairs(samples) do total = total + sample end
    return total / #samples, #samples, #samples >= wanted
end

function governor.new()
    return { reactors = {}, profileDirty = false }
end

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
    }
end

clearCooldown = function(previous)
    previous.cooldownStartedAt = nil
    previous.cooldownReferenceAt = nil
    previous.cooldownReferenceSteam = nil
    previous.cooldownReferenceTemperature = nil
    previous.cooldownLastProgressAt = nil
end

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

local function observeResponse(previous, reactor, control, context, production)
    local now = tonumber(context and context.now) or 0
    local temperature = tonumber(reactor.casingTemperature)
    local buffer = tonumber(reactor.hotFluidPercent)
    local prior = previous.observation
    local steamDelta = math.max(1, tonumber(control.reactorLearningSteamDelta) or 10)
    local temperatureDelta = math.max(0.01,
        tonumber(control.reactorLearningTemperatureDelta) or 0.1)
    local bufferDelta = math.max(0.01,
        tonumber(control.reactorLearningBufferDelta) or 0.1)
    local minimumResponse = math.max(5,
        tonumber(control.reactorMinimumResponseTime) or 15)
    local processMoving, temperatureMoving = false, false

    if prior then
        processMoving = math.abs(production - prior.production) > steamDelta
        if buffer and prior.buffer then
            processMoving = processMoving or
                math.abs(buffer - prior.buffer) > bufferDelta
        end
        if temperature and prior.temperature then
            temperatureMoving =
                math.abs(temperature - prior.temperature) > temperatureDelta
        end
    end
    local waiting = previous.lastAppliedAt and now - previous.lastAppliedAt < minimumResponse
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
        buffer = buffer,
    }
    return not processMoving and not temperatureMoving and not waiting,
        processMoving or temperatureMoving or waiting, {
            waiting = waiting == true,
            processMoving = processMoving,
            temperatureMoving = temperatureMoving,
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

saveProfile = function(memory, control, name, exposure, production, target, context)
    control.reactorProfiles = control.reactorProfiles or {}
    local old = control.reactorProfiles[name]
    if not old or math.abs((tonumber(old.exposure) or -1) - exposure) >= 0.01 or
       math.abs((tonumber(old.targetSteam) or -1) - target) >= 1 then
        control.reactorProfiles[name] = {
            exposure = round(exposure, 2),
            steam = round(production, 1),
            targetSteam = round(target, 1),
            updatedAt = tonumber(context and context.now) or 0,
        }
        memory.profileDirty = true
    end
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
            tonumber(control.reactorSteamReserveMargin) or 0.025))
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
                clearCooldown(previous)
            end
            previous.observedRodExposure = exposure
            local production, averageSamples, averageReady = rollingSteam(previous,
                rawProduction, control)
            local requestedSteam = math.max(0, tonumber(targetSteam))
            local reserveMargin = math.max(0, math.min(0.25,
                tonumber(control.reactorSteamReserveMargin) or 0.025))
            local target = requestedSteam > 0 and
                requestedSteam * (1 + reserveMargin) or 0
            local hotFluid = tonumber(reactor.hotFluidPercent)
            local highBuffer = tonumber(control.reactorHotFluidHigh) or 85
            local lowBuffer = tonumber(control.reactorHotFluidLow) or 15
            local deadband = math.max(tonumber(control.reactorSteamDeadbandMin) or 25,
                target * (tonumber(control.reactorSteamDeadband) or 0.01))
            local maxStep = math.max(0.01, math.min(1,
                tonumber(control.maxRodEquivalentStep) or 0.25))
            local stableRequired = math.max(3,
                math.floor(tonumber(control.reactorLearningSamples) or 8))
            local profile = (control.reactorProfiles or {})[name]
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
                context, production)
            local stable = (previous.stableSamples or 0) >= stableRequired
            -- During an explicit recalibration test, steam output and hot-fluid
            -- response are sufficient to advance after the normal post-write
            -- delay. A massive casing may keep drifting long after production
            -- has settled, so temperature motion remains diagnostic but cannot
            -- hold a bounded calibration step forever.
            local calibrationStable = calibrationPhase == "ADJUSTING" and
                averageReady and not response.waiting and
                (previous.processStableSamples or 0) >= stableRequired
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
            elseif exposure <= 0.005 and production < requestedSteam - deadband and
                   type(profile) == "table" and tonumber(profile.exposure) and
                   tonumber(profile.exposure) > 0 then
                local estimate = learnedExposure(previous, profile, exposure,
                    production, target, rodCount)
                proposed = math.min(maxStep, math.max(0.01, estimate))
                state, action = "RECOVERING", "INCREASE EXPOSURE"
                reason = ("Steam is below demand; restore learned %.2f rod-equivalents"):
                    format(tonumber(profile.exposure))
            elseif (responding or not stable) and not calibrationStable then
                state = "RESPONDING"
                reason = "Waiting for steam, buffer, and casing temperature to settle"
            else
                clearCooldown(previous)
                local bufferUsable = hotFluid == nil or
                    (hotFluid > lowBuffer and hotFluid < highBuffer)
                if bufferUsable then addLearningPoint(previous, exposure, production) end

                if hotFluid and hotFluid >= highBuffer then
                    proposed = math.max(0, exposure - maxStep)
                    state, action = "BUFFER HIGH", "REDUCE EXPOSURE"
                    reason = ("Hot-fluid buffer is %.1f%%; reduce exposed fuel"):
                        format(hotFluid)
                elseif production < target - deadband then
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
                elseif production > target + deadband then
                    local estimate = learnedExposure(previous, profile, exposure,
                        production, target, rodCount)
                    proposed = math.max(exposure - maxStep,
                        math.min(exposure - 0.01, estimate))
                    state, action = "STEAM HIGH", "REDUCE EXPOSURE"
                    reason = ("Formula estimate %.2f rod-equivalents; reduce gradually"):
                        format(estimate)
                elseif bufferUsable then
                    saveProfile(memory, control, name, exposure, production, target,
                        context)
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
                steamProduction = rawProduction,
                averageSteamProduction = round(production, 1),
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
                temperatureMoving = response.temperatureMoving == true,
                hotFluidPercent = hotFluid,
                learnedProfile = profile,
                recalibrating = previous.recalibrating == true,
                calibrationPhase = previous.calibrationPhase,
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

function governor.evaluateAll(memory, reactors, turbines, control, context)
    local demand, activeTurbines, demandError = governor.steamDemand(turbines, control)
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
        reactor.governor = governor.evaluate(memory, reactor, control, reactorContext,
            demand, activeTurbines)
    end
    for name in pairs(memory.reactors or {}) do
        if not present[name] then memory.reactors[name] = nil end
    end
    return reactors, demand, activeTurbines, demandError
end

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
            if needsActive then
                previous.lastAppliedActive = applied == true
                plan.appliedActive = previous.lastAppliedActive
            else
                previous.lastAppliedRodExposure = tonumber(applied) or proposed
                plan.appliedRodExposure = previous.lastAppliedRodExposure
            end
            previous.lastError = nil
            previous.stableSamples = 0
            previous.processStableSamples = 0
            previous.productionSamples = {}
            previous.observation = nil
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
]=],

    ["mainframe/storage_adapter.lua"] = [=[
local adapter = {}
local previousSamples = {}

local function contains(value, fragment)
    return string.find(string.lower(value or ""), fragment, 1, true) ~= nil
end

local function methodSet(methods)
    local set = {}
    for _, method in ipairs(methods or {}) do set[method] = true end
    return set
end

local function number(value)
    if type(value) == "number" then return value end
    if type(value) == "string" then return tonumber(value) end
    if type(value) == "table" then
        return tonumber(value.value or value.amount or value.energy or value.stored)
    end
    return nil
end

local function readAny(name, available, candidates)
    for _, method in ipairs(candidates) do
        if available[method] then
            local ok, result = pcall(peripheral.call, name, method)
            if ok and result ~= nil then return result, method end
        end
    end
    return nil, nil
end

local function hasPair(available, storedMethods, capacityMethods)
    local stored, capacity = false, false
    for _, method in ipairs(storedMethods) do stored = stored or available[method] == true end
    for _, method in ipairs(capacityMethods) do capacity = capacity or available[method] == true end
    return stored and capacity
end

local STORED_METHODS = { "getEnergyStored", "getEnergy", "getStoredEnergy", "getStored", "getEnergyStorage" }
local CAPACITY_METHODS = { "getMaxEnergyStored", "getMaxEnergy", "getEnergyCapacity", "getCapacity", "getMaxStored" }
local INPUT_METHODS = { "getLastInput", "getEnergyInput", "getInputRate", "getInput" }
local OUTPUT_METHODS = { "getLastOutput", "getEnergyOutput", "getOutputRate", "getOutput" }

local function inductionIdentity(device)
    if contains(device.name, "inductionport") or contains(device.name, "induction_port") then return true end
    for _, peripheralType in ipairs(device.types or {}) do
        if contains(peripheralType, "inductionport") or contains(peripheralType, "induction_port") then return true end
    end
    return false
end

local function genericSupported(available)
    return hasPair(available, STORED_METHODS, CAPACITY_METHODS)
end

local function mekanismSupported(device, available)
    if not inductionIdentity(device) then return false end
    if not (available.getEnergy and available.getMaxEnergy) then return false end
    return available.getLastInput or available.getLastOutput or available.getTransferCap or
        available.getInstalledCells or available.getInstalledProviders
end

local function toBaseFE(value, nativeUnit, powerConfig)
    value = number(value)
    if value == nil then return nil end
    if nativeUnit == "J" then
        local joulesPerFE = tonumber(((powerConfig or {}).ratios or {}).J) or 2.5
        if joulesPerFE > 0 then return value / joulesPerFE end
    end
    return value
end

local function percentage(stored, capacity, reported)
    reported = number(reported)
    if reported ~= nil then
        if reported >= 0 and reported <= 1 then return reported * 100 end
        return reported
    end
    if stored ~= nil and capacity and capacity > 0 then return stored / capacity * 100 end
    return nil
end

local function readGeneric(device, available, powerConfig)
    local stored = number(readAny(device.name, available, STORED_METHODS))
    local capacity = number(readAny(device.name, available, CAPACITY_METHODS))
    if stored == nil or capacity == nil then return nil end
    return {
        name = device.name,
        adapter = "generic",
        adapterName = "GENERIC",
        stored = toBaseFE(stored, "FE", powerConfig),
        capacity = toBaseFE(capacity, "FE", powerConfig),
        input = toBaseFE(readAny(device.name, available, INPUT_METHODS), "FE", powerConfig),
        output = toBaseFE(readAny(device.name, available, OUTPUT_METHODS), "FE", powerConfig),
        nativeUnit = "FE",
        telemetryOk = true,
        details = {},
    }
end

local function readMekanism(device, available, powerConfig)
    local formed = readAny(device.name, available, { "isFormed" })
    if formed == false then
        return {
            name = device.name,
            adapter = "mekanism_induction",
            adapterName = "MEKANISM MATRIX",
            nativeUnit = "J",
            telemetryOk = false,
            error = "Induction Matrix is not formed",
            details = {},
        }
    end

    local stored = toBaseFE(readAny(device.name, available, { "getEnergy" }), "J", powerConfig)
    local capacity = toBaseFE(readAny(device.name, available, { "getMaxEnergy" }), "J", powerConfig)
    if stored == nil or capacity == nil then return nil end

    local result = {
        name = device.name,
        adapter = "mekanism_induction",
        adapterName = "MEKANISM MATRIX",
        stored = stored,
        capacity = capacity,
        input = toBaseFE(readAny(device.name, available, { "getLastInput" }), "J", powerConfig),
        output = toBaseFE(readAny(device.name, available, { "getLastOutput" }), "J", powerConfig),
        nativeUnit = "J",
        telemetryOk = true,
        details = {
            transferCap = toBaseFE(readAny(device.name, available, { "getTransferCap" }), "J", powerConfig),
            cells = number(readAny(device.name, available, { "getInstalledCells" })),
            providers = number(readAny(device.name, available, { "getInstalledProviders" })),
            formed = formed,
        },
    }
    result.reportedPercent = number(readAny(device.name, available, { "getEnergyFilledPercentage" }))
    return result
end

local function finalize(storage)
    storage.percent = percentage(storage.stored, storage.capacity, storage.reportedPercent)
    storage.reportedPercent = nil

    if storage.input ~= nil and storage.output ~= nil then
        storage.net = storage.input - storage.output
    else
        local now = os.epoch("utc") / 1000
        local previous = previousSamples[storage.name]
        if previous and now > previous.time and storage.stored ~= nil then
            local elapsedSeconds = now - previous.time
            storage.net = (storage.stored - previous.stored) / (elapsedSeconds * 20)
        end
        if storage.stored ~= nil then
            previousSamples[storage.name] = { stored = storage.stored, time = now }
        end
    end

    local epsilon = 0.5
    if storage.capacity and storage.capacity > 0 and storage.stored and storage.stored >= storage.capacity then
        storage.state = "FULL"
    elseif storage.stored and storage.stored <= 0 then
        storage.state = "EMPTY"
    elseif storage.net and storage.net > epsilon then
        storage.state = "CHARGING"
    elseif storage.net and storage.net < -epsilon then
        storage.state = "DRAINING"
    elseif storage.net ~= nil then
        storage.state = "STABLE"
    else
        storage.state = "UNKNOWN"
    end

    if storage.net and storage.capacity and storage.stored then
        if storage.net > epsilon then
            storage.etaSeconds = math.max(0, (storage.capacity - storage.stored) / (storage.net * 20))
        elseif storage.net < -epsilon then
            storage.etaSeconds = math.max(0, storage.stored / (-storage.net * 20))
        end
    end
    return storage
end

function adapter.read(device, powerConfig)
    if not peripheral.isPresent(device.name) then
        return { name = device.name, adapterName = "UNKNOWN", telemetryOk = false, error = "Peripheral unavailable", details = {} }
    end
    local methods = peripheral.getMethods(device.name) or device.methods or {}
    local available = methodSet(methods)
    local storage

    if mekanismSupported(device, available) then
        local ok, specialized = pcall(readMekanism, device, available, powerConfig)
        if ok then storage = specialized end
        if not storage then
            storage = readGeneric(device, available, powerConfig)
            if storage then
                storage.fallback = true
                storage.adapterName = "GENERIC (FALLBACK)"
            end
        end
    elseif genericSupported(available) then
        storage = readGeneric(device, available, powerConfig)
    end

    if not storage then return nil end
    return finalize(storage)
end

function adapter.readAll(devices, powerConfig)
    local storages = {}
    local present = {}
    for _, device in ipairs(devices or {}) do
        if device.category ~= "reactor" and device.category ~= "turbine" and
           device.category ~= "monitor" and device.category ~= "modem" then
            local ok, storage = pcall(adapter.read, device, powerConfig)
            if ok and storage then
                storages[#storages + 1] = storage
                present[storage.name] = true
            elseif not ok and device.category == "battery" then
                storages[#storages + 1] = {
                    name = device.name,
                    adapterName = "UNKNOWN",
                    telemetryOk = false,
                    error = "Storage adapter failed",
                    details = {},
                }
            end
        end
    end
    for name in pairs(previousSamples) do
        if not present[name] then previousSamples[name] = nil end
    end
    table.sort(storages, function(a, b) return a.name < b.name end)
    return storages
end

local function eta(value)
    if value == nil or value ~= value or value == math.huge then return "N/A" end
    value = math.max(0, math.floor(value + 0.5))
    local days = math.floor(value / 86400)
    local hours = math.floor((value % 86400) / 3600)
    local minutes = math.floor((value % 3600) / 60)
    local seconds = value % 60
    if days > 0 then return ("%dd %dh"):format(days, hours) end
    if hours > 0 then return ("%dh %dm"):format(hours, minutes) end
    if minutes > 0 then return ("%dm %ds"):format(minutes, seconds) end
    return seconds .. "s"
end

function adapter.formatETA(storage)
    return eta(storage and storage.etaSeconds)
end

function adapter.printReport(storages, config, formatter)
    print("HELIOS energy-storage telemetry")
    print("Storage devices found: " .. #storages)
    print("")
    for _, storage in ipairs(storages) do
        local alias = config.deviceAliases[storage.name]
        print("[" .. storage.adapterName .. "] " .. (alias or storage.name))
        if config.ui.showPeripheralNames and alias then print("  Peripheral: " .. storage.name) end
        if storage.error then
            print("  ERROR: " .. storage.error)
        else
            print("  Stored: " .. formatter.power(storage.stored, config.power, false) .. " / " .. formatter.power(storage.capacity, config.power, false))
            print("  Charge: " .. (storage.percent and ("%.1f%%"):format(storage.percent) or "N/A"))
            print("  Input: " .. formatter.power(storage.input, config.power, true))
            print("  Output: " .. formatter.power(storage.output, config.power, true))
            print("  Net: " .. formatter.power(storage.net, config.power, true))
            print("  State: " .. storage.state)
            if storage.state == "CHARGING" then print("  Full in: " .. eta(storage.etaSeconds)) end
            if storage.state == "DRAINING" then print("  Empty in: " .. eta(storage.etaSeconds)) end
        end
        print("")
    end
end

return adapter
]=],

    ["mainframe/turbine_adapter.lua"] = [=[
local adapter = {}

local function readAny(name, availableMethods, candidates)
    for _, method in ipairs(candidates) do
        if availableMethods[method] then
            local ok, value = pcall(peripheral.call, name, method)
            if ok and value ~= nil then return value, method end
        end
    end
    return nil, nil
end

local function number(value)
    value = tonumber(value)
    if value ~= value then return nil end
    return value
end

local function percent(amount, maximum)
    amount, maximum = number(amount), number(maximum)
    if not amount or not maximum or maximum <= 0 then return nil end
    return math.max(0, math.min(100, amount / maximum * 100))
end

local function availableMethods(name)
    local methods = {}
    for _, method in ipairs(peripheral.getMethods(name) or {}) do
        methods[method] = true
    end
    return methods
end

function adapter.read(device)
    local name = device.name
    local turbine = { name = name, available = peripheral.isPresent(name) }
    if not turbine.available then
        turbine.error = "Peripheral unavailable"
        return turbine
    end

    local availableMethods = availableMethods(name)

    turbine.connected = readAny(name, availableMethods, { "getConnected", "isConnected", "mbIsConnected", "mbIsAssembled", "connected" })
    turbine.active = readAny(name, availableMethods, { "getActive", "isActive", "active" })
    turbine.rotorSpeed = number(readAny(name, availableMethods, { "getRotorSpeed", "getRotorRPM", "rotorSpeed" }))
    turbine.energyProduction = number(readAny(name, availableMethods, { "getEnergyProducedLastTick", "getEnergyProductionRate", "energyProducedLastTick" }))
    turbine.energy = number(readAny(name, availableMethods, { "getEnergyStored", "getEnergy", "energyStored" }))
    turbine.energyMax = number(readAny(name, availableMethods, { "getEnergyCapacity", "getMaxEnergyStored", "energyCapacity" }))
    turbine.flowRate = number(readAny(name, availableMethods, { "getFluidFlowRate", "getFluidFlowRateLastTick", "getInputFlowRate", "fluidFlowRate" }))
    turbine.flowRateMax = number(readAny(name, availableMethods, { "getFluidFlowRateMax", "getMaxFluidFlowRate", "getMaxIntakeRate", "fluidFlowRateMax" }))
    turbine.flowRateLimit = number(readAny(name, availableMethods, { "getFluidFlowRateMaxMax", "getFluidFlowRateLimit", "getMaxPermittedFlow", "flowRateLimit" }))
    turbine.inputAmount = number(readAny(name, availableMethods, { "getInputAmount", "getInputFluidAmount", "inputAmount" }))
    turbine.inputMax = number(readAny(name, availableMethods, { "getInputAmountMax", "getInputCapacity", "inputAmountMax" }))
    turbine.outputAmount = number(readAny(name, availableMethods, { "getOutputAmount", "getOutputFluidAmount", "outputAmount" }))
    turbine.outputMax = number(readAny(name, availableMethods, { "getOutputAmountMax", "getOutputCapacity", "outputAmountMax" }))
    turbine.inductorEngaged = readAny(name, availableMethods, { "getInductorEngaged", "isInductorEngaged", "inductorEngaged" })
    turbine.ventMode = readAny(name, availableMethods, { "getVentMode", "ventMode" })
    turbine.bladeCount = number(readAny(name, availableMethods, { "getBladeCount", "getNumberOfBlades", "bladeCount" }))
    turbine.coilCount = number(readAny(name, availableMethods, { "getCoilSize", "getCoilCount", "coilSize" }))
    turbine.efficiency = number(readAny(name, availableMethods, { "getRotorEfficiencyLastTick", "getEfficiency", "rotorEfficiencyLastTick" }))

    turbine.energyPercent = percent(turbine.energy, turbine.energyMax)
    turbine.inputPercent = percent(turbine.inputAmount, turbine.inputMax)
    turbine.outputPercent = percent(turbine.outputAmount, turbine.outputMax)

    local useful = turbine.active ~= nil or turbine.rotorSpeed ~= nil or turbine.energyProduction ~= nil
    if turbine.connected == false then
        turbine.error = "Turbine is not connected"
    elseif not useful then
        turbine.error = "No supported telemetry methods"
    end
    return turbine
end

function adapter.setFlowLimit(turbine, requested)
    if type(turbine) ~= "table" or type(turbine.name) ~= "string" then
        return false, nil, "Invalid turbine identity"
    end
    if not peripheral.isPresent(turbine.name) then
        return false, nil, "Peripheral unavailable"
    end

    local methods = availableMethods(turbine.name)
    if not methods.setFluidFlowRateMax or not methods.getFluidFlowRateMax then
        return false, nil, "Verified flow-limit control is unavailable"
    end

    requested = tonumber(requested)
    if not requested then return false, nil, "Invalid flow limit" end
    local hardLimit = tonumber(turbine.flowRateLimit)
    if hardLimit then requested = math.min(requested, hardLimit) end
    requested = math.max(0, math.floor(requested + 0.5))

    local ok, reason = pcall(peripheral.call, turbine.name, "setFluidFlowRateMax", requested)
    if not ok then return false, nil, tostring(reason) end

    local readOk, actual = pcall(peripheral.call, turbine.name, "getFluidFlowRateMax")
    actual = tonumber(actual)
    if not readOk or actual == nil then
        return false, nil, "Flow-limit verification failed"
    end
    local verified = math.floor(actual + 0.5)
    if verified ~= requested then
        return false, verified, ("Requested %d mB/t; turbine reports %d mB/t"):format(
            requested, verified)
    end
    return true, verified
end

function adapter.setInductor(turbine, engaged)
    if type(turbine) ~= "table" or type(turbine.name) ~= "string" then
        return false, nil, "Invalid turbine identity"
    end
    if not peripheral.isPresent(turbine.name) then
        return false, nil, "Peripheral unavailable"
    end

    local methods = availableMethods(turbine.name)
    if not methods.setInductorEngaged or not methods.getInductorEngaged then
        return false, nil, "Verified inductor control is unavailable"
    end

    engaged = engaged == true
    local ok, reason = pcall(peripheral.call, turbine.name, "setInductorEngaged", engaged)
    if not ok then return false, nil, tostring(reason) end

    local readOk, actual = pcall(peripheral.call, turbine.name, "getInductorEngaged")
    if not readOk or type(actual) ~= "boolean" then
        return false, nil, "Inductor verification failed"
    end
    if actual ~= engaged then
        return false, actual, ("Requested inductor %s; turbine reports %s"):format(
            engaged and "engaged" or "disengaged", actual and "engaged" or "disengaged")
    end
    return true, actual
end

function adapter.readAll(devices)
    local turbines = {}
    for _, device in ipairs(devices or {}) do
        local lowerName = string.lower(device.name or "")
        if device.category == "turbine" or string.find(lowerName, "turbine", 1, true) then
            turbines[#turbines + 1] = adapter.read(device)
        end
    end
    return turbines
end

local function value(numberValue, suffix)
    if numberValue == nil then return "N/A" end
    return ("%.1f%s"):format(numberValue, suffix or "")
end

function adapter.printReport(turbines, config, formatter)
    print("HELIOS turbine telemetry")
    print("Turbines found: " .. #turbines)
    print("")
    for _, turbine in ipairs(turbines) do
        local alias = config.deviceAliases[turbine.name]
        local displayName = alias or turbine.name
        print("[TURBINE] " .. displayName)
        if config.ui.showPeripheralNames and alias then print("  Peripheral: " .. turbine.name) end
        if turbine.error then
            print("  ERROR: " .. turbine.error)
        else
            print("  State: " .. (turbine.active == true and "ACTIVE" or turbine.active == false and "OFFLINE" or "UNKNOWN"))
            print("  Rotor: " .. value(turbine.rotorSpeed, " RPM"))
            print("  Power: " .. formatter.power(turbine.energyProduction, config.power, true))
            print("  Buffer: " .. value(turbine.energyPercent, "%"))
            print("  Flow: " .. value(turbine.flowRate, " mB/t"))
            print("  Flow setting: " .. value(turbine.flowRateMax, " mB/t"))
            print("  Flow limit: " .. value(turbine.flowRateLimit, " mB/t"))
            print("  Inductor: " .. (turbine.inductorEngaged == true and "ENGAGED" or turbine.inductorEngaged == false and "DISENGAGED" or "N/A"))
        end
        print("")
    end
end

return adapter
]=],

    ["mainframe/turbine_governor.lua"] = [=[
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
]=],

    ["terminal/main.lua"] = [=[
local terminal = {}

function terminal.run(config)
    local display = dofile("/helios/core/display.lua")
    display.start(config)
    local ui = dofile("/helios/core/ui.lua")
    ui.setVersion(config.version)
    local configStore = dofile("/helios/core/config.lua")
    local network = dofile("/helios/core/network.lua")
    local powerFormat = dofile("/helios/core/power_format.lua")
    local modemCount = network.openAll()
    local snapshot
    local lastSnapshotAt
    local mainframeId = tonumber(config.mainframeId)
    local selected = 1
    local localSilenced
    local lastAlarmSound = 0
    local heartbeatTimer
    local lastHelloAt = 0
    local sessionId = network.sessionId("terminal")
    local idConflicts = {}
    local previousButton, nextButton, silenceButton, testButton

    local function nameOf(rawName, state)
        local aliases = state.aliases or {}
        local alias = aliases[rawName]
        if alias and alias ~= "" then
            if state.showPeripheralNames then return alias .. " [" .. rawName .. "]" end
            return alias
        end
        return rawName or "UNKNOWN"
    end

    local function playSound(sound, pitch, volume)
        for _, name in ipairs(peripheral.getNames()) do
            if peripheral.hasType(name, "speaker") then
                pcall(peripheral.call, name, "playSound", sound, volume or 1.5, pitch)
            end
        end
    end

    local function alarmSignature(alarm)
        return alarm and (tostring(alarm.level) .. ":" .. tostring(alarm.key)) or nil
    end

    local function updateAlarmSound()
        local alarm = snapshot and snapshot.alarm
        local signature = alarmSignature(alarm)
        if not signature then
            localSilenced = nil
            return
        end
        if snapshot.alarmSilenced or localSilenced == signature then return end
        local now = network.now()
        local repeatAfter = alarm.level >= 3 and 5 or 30
        if now - lastAlarmSound >= repeatAfter then
            playSound(alarm.level >= 3 and "minecraft:block.note_block.bell" or
                "minecraft:block.note_block.pling", alarm.level >= 3 and 0.6 or 1.0,
                tonumber(snapshot.alarmVolume) or 1.5)
            lastAlarmSound = now
        end
    end

    local function sendHello()
        network.broadcast({
            helios = true,
            kind = "hello",
            computerId = os.getComputerID(),
            display = config.display or "all",
            version = config.version,
            sessionId = sessionId,
        })
        lastHelloAt = network.now()
    end

    local function linkOnline()
        return lastSnapshotAt and network.now() - lastSnapshotAt <= 5
    end

    local function conflictingId(id)
        id = tonumber(id)
        for _, conflict in ipairs(idConflicts) do
            if tonumber(conflict) == id then return true end
        end
        return false
    end

    local function statusLine()
        if modemCount == 0 then return "NO MODEM", colors.red end
        if conflictingId(os.getComputerID()) or (mainframeId and conflictingId(mainframeId)) then
            return "ID CONFLICT - TELEMETRY UNTRUSTED", colors.red
        end
        if not snapshot then return "SEARCHING", colors.orange end
        if not linkOnline() then return "LINK LOST - DATA STALE", colors.red end
        return "ONLINE", colors.lime
    end

    local function alarmLine()
        silenceButton = nil
        if not snapshot or not snapshot.alarm then return end
        term.setTextColor(snapshot.alarm.level >= 3 and colors.red or colors.orange)
        print("!! " .. tostring(snapshot.alarm.message))
        if snapshot.alarmSilenced then
            print("Alarm silenced at mainframe")
        elseif localSilenced == alarmSignature(snapshot.alarm) then
            print("Local speaker silenced")
        else
            silenceButton = ui.button("SILENCE LOCAL", colors.orange)
        end
        term.setTextColor(colors.white)
    end

    local function renderList(title, list, state, drawItem)
        ui.header("REMOTE " .. title, "Read-only mainframe telemetry")
        local link, colour = statusLine()
        ui.status("Mainframe link", link, colour)
        if not list or #list == 0 then
            ui.status("Status", "NO DEVICES REPORTED", colors.orange)
            alarmLine()
            return
        end
        if selected > #list then selected = #list end
        local item = list[selected]
        local singular = ({ REACTORS = "Reactor", TURBINES = "Turbine", STORAGE = "Storage" })[title] or "Device"
        ui.status(singular, ("%d/%d %s"):format(selected, #list, nameOf(item.name, state)), colors.cyan)
        drawItem(item, state)
        print("")
        alarmLine()
        previousButton = ui.inlineButton("< PREVIOUS", colors.cyan)
        write(" ")
        nextButton = ui.inlineButton("NEXT >", colors.cyan)
        print("")
        testButton = ui.button("TEST SPEAKER", colors.cyan)
    end

    local function formatValue(value, suffix)
        if value == nil then return "N/A" end
        return ("%.1f%s"):format(value, suffix or "")
    end

    local function formatRodLayout(reactor, exposure)
        local minimum = tonumber(reactor.controlRodMinimum)
        local maximum = tonumber(reactor.controlRodMaximum)
        local range
        if minimum == nil or maximum == nil then
            range = "N/A"
        elseif math.abs(maximum - minimum) < 0.05 then
            range = ("%.0f%%"):format(minimum)
        else
            range = ("%.0f-%.0f%%"):format(minimum, maximum)
        end
        return ("%s / %s eq"):format(range,
            exposure ~= nil and ("%.2f"):format(exposure) or "N/A")
    end

    local function renderReactors(state)
        renderList("REACTORS", state.reactors, state, function(item)
            ui.status("Mode", string.upper(item.mode or "unknown"))
            if item.error then ui.status("Telemetry", item.error, colors.red) return end
            ui.status("State", item.active == true and "ACTIVE" or item.active == false and "OFFLINE" or "UNKNOWN")
            ui.status("Fuel / use", ("%s / %s"):format(
                formatValue(item.fuelPercent, "%"),
                formatValue(item.fuelUse, " mB/t")))
            ui.status("Temps fuel/case", ("%s / %s"):format(
                formatValue(item.fuelTemperature, " C"),
                formatValue(item.casingTemperature, " C")))
            if item.mode == "steam" then
                local plan = item.governor or {}
                ui.status("Steam avg/target", ("%s / %s"):format(
                    formatValue(plan.averageSteamProduction or
                        item.steamProduction, ""),
                    formatValue(plan.targetSteam, " mB/t")), colors.cyan)
                ui.status("Coolant / hot", ("%s / %s"):format(
                    formatValue(item.coolantPercent, "%"),
                    formatValue(item.hotFluidPercent, "%")))
                ui.status("Rods range / exposed",
                    formatRodLayout(item, plan.currentRodExposure))
                ui.status("Governor", (plan.state or "WAITING") .. " / " ..
                    (plan.actuatorState or "WAITING"),
                    (plan.trusted == false or plan.actuatorState == "FAULT") and
                        colors.red or
                    ((plan.state == "STEAM DEFICIT" or
                      plan.state == "STEAM SURPLUS") and colors.orange or colors.lime))
            else
                ui.status("Power output", powerFormat.power(item.energyProduction, state.power, true), colors.cyan)
                ui.status("Energy buffer", formatValue(item.energyPercent, "%"))
            end
        end)
    end

    local function renderTurbines(state)
        renderList("TURBINES", state.turbines, state, function(item)
            if item.error then ui.status("Telemetry", item.error, colors.red) return end
            ui.status("State", item.active == true and "ACTIVE" or item.active == false and "OFFLINE" or "UNKNOWN")
            ui.status("Rotor speed", formatValue(item.rotorSpeed, " RPM"), colors.cyan)
            local plan = item.governor or {}
            ui.status("Governor", (plan.state or "WAITING") .. " / " ..
                (plan.actuatorState or "WAITING"),
                (plan.trusted == false or plan.actuatorState == "FAULT") and colors.red or colors.lime)
            ui.status("Power output", powerFormat.power(item.energyProduction, state.power, true), colors.cyan)
            ui.status("Energy buffer", formatValue(item.energyPercent, "%"))
            if plan.currentFlow ~= nil and plan.recommendedFlow ~= nil then
                ui.status("Flow actual/set/plan", ("%s / %.0f -> %.0f"):format(
                    plan.actualFlow and ("%.0f"):format(plan.actualFlow) or "N/A",
                    plan.currentFlow, plan.recommendedFlow), colors.cyan)
            else
                ui.status("Flow actual/set/plan", "N/A / HOLD", colors.gray)
            end
            ui.status("Inductor", item.inductorEngaged == true and "ENGAGED" or item.inductorEngaged == false and "DISENGAGED" or "N/A")
        end)
    end

    local function renderStorage(state)
        renderList("STORAGE", state.storages, state, function(item)
            ui.status("Driver", item.adapterName or "UNKNOWN", item.fallback and colors.orange or colors.lime)
            if item.error then ui.status("Telemetry", item.error, colors.red) return end
            ui.status("Charge", formatValue(item.percent, "%"), colors.cyan)
            ui.status("Stored", powerFormat.power(item.stored, state.power, false) .. " / " .. powerFormat.power(item.capacity, state.power, false))
            ui.status("Input", powerFormat.power(item.input, state.power, true))
            ui.status("Output", powerFormat.power(item.output, state.power, true))
            ui.status("Net", powerFormat.power(item.net, state.power, true))
            ui.status("State", item.state or "UNKNOWN")
        end)
    end

    local function renderOverview(state)
        ui.header("REMOTE OVERVIEW", "Read-only mainframe telemetry")
        local link, colour = statusLine()
        ui.status("Mainframe link", link, colour)
        ui.status("Reactors", #(state.reactors or {}), colors.cyan)
        ui.status("Turbines", #(state.turbines or {}), colors.cyan)
        ui.status("Storage", #(state.storages or {}), colors.cyan)
        local production = 0
        for _, reactor in ipairs(state.reactors or {}) do production = production + (tonumber(reactor.energyProduction) or 0) end
        for _, turbine in ipairs(state.turbines or {}) do production = production + (tonumber(turbine.energyProduction) or 0) end
        local stored, capacity = 0, 0
        for _, storage in ipairs(state.storages or {}) do
            stored = stored + (tonumber(storage.stored) or 0)
            capacity = capacity + (tonumber(storage.capacity) or 0)
        end
        ui.status("Generation", powerFormat.power(production, state.power, true), colors.lime)
        ui.status("Stored", powerFormat.power(stored, state.power, false))
        if capacity > 0 then ui.status("Combined charge", ("%.1f%%"):format(stored / capacity * 100)) end
        print("")
        alarmLine()
        testButton = ui.button("TEST SPEAKER", colors.cyan)
        print("Q exits on the terminal keyboard")
    end

    local function render()
        previousButton, nextButton, silenceButton, testButton = nil, nil, nil, nil
        ui.setIdConflicts(idConflicts)
        if not snapshot then
            ui.header("REMOTE TERMINAL", "Mainframe-restricted display")
            ui.status("System", "ONLINE", colors.lime)
            ui.status("Computer ID", config.computerId)
            ui.status("Display assignment", string.upper(config.display or "all"), colors.cyan)
            local link, colour = statusLine()
            ui.status("Mainframe link", link, colour)
            print("")
            print("This terminal has no device-control authority.")
            print("X tests the local speaker.")
            print("Press Q to exit HELIOS.")
            return
        end
        local assignment = snapshot.assignment or config.display or "all"
        if assignment == "reactor" then renderReactors(snapshot)
        elseif assignment == "turbine" then renderTurbines(snapshot)
        elseif assignment == "battery" then renderStorage(snapshot)
        else renderOverview(snapshot) end
    end

    sendHello()
    heartbeatTimer = os.startTimer(1)
    render()
    while true do
        local event, value, message, protocol = os.pullEvent()
        if event == "key" and value == keys.q then
            ui.prepare()
            display.stop()
            return
        elseif event == "key" and value == keys.left then
            selected = math.max(1, selected - 1)
            render()
        elseif event == "key" and value == keys.right then
            selected = selected + 1
            render()
        elseif event == "key" and value == keys.s and snapshot and snapshot.alarm then
            localSilenced = alarmSignature(snapshot.alarm)
            render()
        elseif event == "key" and value == keys.x then
            playSound("minecraft:block.note_block.bell", 0.8, 1.5)
        elseif event == "monitor_touch" then
            local x, y = message, protocol
            if ui.hit(previousButton, x, y) then selected = math.max(1, selected - 1)
            elseif ui.hit(nextButton, x, y) then selected = selected + 1
            elseif ui.hit(silenceButton, x, y) and snapshot and snapshot.alarm then
                localSilenced = alarmSignature(snapshot.alarm)
            elseif ui.hit(testButton, x, y) then
                playSound("minecraft:block.note_block.bell", 0.8, 1.5)
            end
            render()
        elseif event == "rednet_message" and protocol == network.protocol and
               network.valid(message, "integrity") then
            idConflicts = type(message.idConflicts) == "table" and message.idConflicts or {}
            render()
        elseif event == "rednet_message" and protocol == network.protocol and
               network.valid(message, "snapshot") and (not mainframeId or value == mainframeId) then
            if not mainframeId then
                mainframeId = value
                config.mainframeId = value
                configStore.save(config)
            end
            local oldSignature = snapshot and alarmSignature(snapshot.alarm)
            snapshot = message
            idConflicts = type(snapshot.idConflicts) == "table" and snapshot.idConflicts or idConflicts
            lastSnapshotAt = network.now()
            local newSignature = alarmSignature(snapshot.alarm)
            if oldSignature and not newSignature then
                playSound("minecraft:block.note_block.pling", 1.5, tonumber(snapshot.alarmVolume) or 1.5)
            end
            if newSignature ~= oldSignature then
                localSilenced = nil
                lastAlarmSound = 0
            end
            updateAlarmSound()
            render()
        elseif event == "timer" and value == heartbeatTimer then
            modemCount = network.openAll()
            if network.now() - lastHelloAt >= 3 then sendHello() end
            updateAlarmSound()
            heartbeatTimer = os.startTimer(1)
            render()
        elseif event == "peripheral" or event == "peripheral_detach" or
               event == "term_resize" or event == "monitor_resize" then
            modemCount = network.openAll()
            render()
        end
    end
end

return terminal
]=],
}

local function installStartup()
    if fs.exists("/startup") and not fs.isDir("/startup") then
        print("An existing /startup program was found.")
        print("HELIOS can preserve it as /startup/00-user.lua.")
        if not confirm("Convert startup to a startup directory?") then
            return false, "Autostart was skipped; run 'helios' manually."
        end
        local oldStartup = "/.helios-existing-startup.lua"
        if fs.exists(oldStartup) then fs.delete(oldStartup) end
        fs.move("/startup", oldStartup)
        fs.makeDir("/startup")
        fs.move(oldStartup, "/startup/00-user.lua")
    elseif not fs.exists("/startup") then
        fs.makeDir("/startup")
    end

    writeFile("/startup/99-helios.lua", [=[
if fs.exists("/helios/helios.lua") then
    shell.run("/helios/helios.lua")
end
]=])
    return true
end

local function buildConfig(role, display, existing)
    existing = type(existing) == "table" and existing or {}
    local discovery = type(existing.discovery) == "table" and existing.discovery or {}
    local alarms = type(existing.alarms) == "table" and existing.alarms or {}
    local uiSettings = type(existing.ui) == "table" and existing.ui or {}
    local power = type(existing.power) == "table" and existing.power or {}
    local ratios = type(power.ratios) == "table" and power.ratios or {}
    local control = type(existing.control) == "table" and existing.control or {}
    local aliases = type(existing.deviceAliases) == "table" and existing.deviceAliases or {}
    local merged = {
        version = VERSION,
        role = role,
        display = display,
        computerId = os.getComputerID(),
        mainframeId = tonumber(existing.mainframeId),
        discovery = {
            defaultMode = discovery.defaultMode == "manual" and "manual" or "event",
            maintenanceTimeout = tonumber(discovery.maintenanceTimeout) or 1800,
        },
        alarms = {
            enabled = alarms.enabled ~= false,
            lowFuel = tonumber(alarms.lowFuel) or 20,
            criticalFuel = tonumber(alarms.criticalFuel) or 5,
            volume = tonumber(alarms.volume) or 1.5,
            confirmSamples = math.max(1, math.floor(tonumber(alarms.confirmSamples) or 3)),
            warningRepeat = math.max(5, math.floor(tonumber(alarms.warningRepeat) or 30)),
            criticalRepeat = math.max(2, math.floor(tonumber(alarms.criticalRepeat) or 5)),
        },
        ui = {
            showPeripheralNames = uiSettings.showPeripheralNames == true,
            monitorTextScale = tonumber(uiSettings.monitorTextScale) or 0.5,
        },
        power = {
            unit = ({ FE = true, RF = true, J = true, EU = true })[power.unit] and power.unit or "FE",
            numberFormat = power.numberFormat == "full" and "full" or "compact",
            decimals = math.max(1, math.min(2, math.floor(tonumber(power.decimals) or 1))),
            ratios = {
                FE = tonumber(ratios.FE) or 1,
                RF = tonumber(ratios.RF) or 1,
                J = tonumber(ratios.J) or 2.5,
                EU = tonumber(ratios.EU) or 0.25,
            },
        },
        control = {
            mode = "automatic",
            actuatorsEnabled = role == "mainframe",
            targetRpm = tonumber(control.targetRpm) or 1800,
            rpmDeadband = math.max(1, tonumber(control.rpmDeadband) or 25),
            overspeedRpm = math.max((tonumber(control.targetRpm) or 1800) +
                math.max(1, tonumber(control.rpmDeadband) or 25),
                tonumber(control.overspeedRpm) or 2000),
            overspeedSamples = math.max(1,
                math.floor(tonumber(control.overspeedSamples) or 3)),
            storageLow = tonumber(control.storageLow) or 25,
            storageHigh = tonumber(control.storageHigh) or 85,
            maxRodStep = tonumber(control.maxRodStep) or 5,
            reactorAdjustmentInterval = math.max(2,
                tonumber(control.reactorAdjustmentInterval) or 5),
            reactorCommandSamples = math.max(2,
                math.floor(tonumber(control.reactorCommandSamples) or 3)),
            reactorSteamDeadband = math.max(0.005, math.min(0.25,
                tonumber(control.reactorSteamDeadband) or 0.01)),
            reactorSteamDeadbandMin = math.max(1,
                tonumber(control.reactorSteamDeadbandMin) or 25),
            reactorSteamReserveMargin = math.max(0, math.min(0.25,
                tonumber(control.reactorSteamReserveMargin) or 0.025)),
            reactorSteamAverageSamples = math.max(3,
                math.floor(tonumber(control.reactorSteamAverageSamples) or 10)),
            reactorHotFluidHigh = math.max(50, math.min(99,
                tonumber(control.reactorHotFluidHigh) or 85)),
            reactorHotFluidLow = math.max(1, math.min(84,
                tonumber(control.reactorHotFluidLow) or 15)),
            maxRodEquivalentStep = math.max(0.01, math.min(1,
                tonumber(control.maxRodEquivalentStep) or 0.25)),
            reactorLearningSamples = math.max(3,
                math.floor(tonumber(control.reactorLearningSamples) or 8)),
            reactorLearningSteamDelta = math.max(1,
                tonumber(control.reactorLearningSteamDelta) or 10),
            reactorLearningTemperatureDelta = math.max(0.01,
                tonumber(control.reactorLearningTemperatureDelta) or 0.1),
            reactorLearningBufferDelta = math.max(0.01,
                tonumber(control.reactorLearningBufferDelta) or 0.1),
            reactorMinimumResponseTime = math.max(5,
                tonumber(control.reactorMinimumResponseTime) or 15),
            reactorCooldownWindow = math.max(5,
                tonumber(control.reactorCooldownWindow) or 10),
            reactorCooldownStallTimeout = math.max(60,
                tonumber(control.reactorCooldownStallTimeout) or 180),
            reactorCooldownSteamDelta = math.max(0.1,
                tonumber(control.reactorCooldownSteamDelta) or 2),
            reactorCooldownTemperatureDelta = math.max(0.01,
                tonumber(control.reactorCooldownTemperatureDelta) or 0.05),
            reactorCalibrationMaxTemperature = math.max(50,
                tonumber(control.reactorCalibrationMaxTemperature) or 150),
            reactorProfiles = type(control.reactorProfiles) == "table" and
                control.reactorProfiles or {},
            maxFlowStep = tonumber(control.maxFlowStep) or 100,
            adjustmentInterval = tonumber(control.adjustmentInterval) or 2,
            commandSamples = math.max(1,
                math.floor(tonumber(control.commandSamples) or 2)),
            lowBandRpm = tonumber(control.lowBandRpm) or 900,
            highBandRpm = tonumber(control.highBandRpm) or 1800,
            calibrationLowEscapeRpm = math.max(
                (tonumber(control.lowBandRpm) or 900) +
                    math.max(1, tonumber(control.rpmDeadband) or 25),
                tonumber(control.calibrationLowEscapeRpm) or
                    ((tonumber(control.lowBandRpm) or 900) + 100)),
            coldStartRpm = math.max(0, tonumber(control.coldStartRpm) or 100),
            calibrationSettleDelta = math.max(0.1,
                tonumber(control.calibrationSettleDelta) or 2),
            calibrationSettleSamples = math.max(3,
                math.floor(tonumber(control.calibrationSettleSamples) or 8)),
            calibrationMinimumRpm = math.max(0,
                tonumber(control.calibrationMinimumRpm) or 850),
            calibrationSteamRatio = math.max(0.1, math.min(1,
                tonumber(control.calibrationSteamRatio) or 0.98)),
            calibrationSteamSamples = math.max(3,
                math.floor(tonumber(control.calibrationSteamSamples) or 5)),
            calibrationFailureSamples = math.max(3,
                math.floor(tonumber(control.calibrationFailureSamples) or 10)),
            calibrationSpoolFailureSamples = math.max(1,
                math.floor(tonumber(control.calibrationSpoolFailureSamples) or 2)),
            calibrationBandEscapeSamples = math.max(2,
                math.floor(tonumber(control.calibrationBandEscapeSamples) or 3)),
            calibrationStallTimeout = math.max(30,
                tonumber(control.calibrationStallTimeout) or 180),
            overspeedMargin = math.max(25,
                tonumber(control.overspeedMargin) or 200),
            turbineProfiles = type(control.turbineProfiles) == "table" and
                control.turbineProfiles or {},
        },
        deviceAliases = aliases,
    }
    return "return " .. textutils.serialize(merged)
end

local function runInstaller()
    local existingConfig
    if fs.exists(INSTALL_DIR .. "/config.lua") then
        local ok, loaded = pcall(dofile, INSTALL_DIR .. "/config.lua")
        if ok and type(loaded) == "table" then existingConfig = loaded end
    end
    title("Installer " .. VERSION)
    local role = choose("Select this computer's role:", {
        { label = "Mainframe", value = "mainframe" },
        { label = "Remote Terminal", value = "terminal" },
    })

    local display
    if role == "terminal" then
        title("Remote Terminal Configuration")
        display = choose("Select the information this terminal will request:", {
            { label = "Reactor", value = "reactor" },
            { label = "Turbine", value = "turbine" },
            { label = "Battery", value = "battery" },
            { label = "All systems overview", value = "all" },
        })
    end

    title("Ready to Install")
    print("Role: " .. role)
    if display then print("Display: " .. display) end
    print("Location: " .. INSTALL_DIR)
    print("")
    if not confirm("Install HELIOS?") then
        print("Installation cancelled.")
        return
    end

    if fs.exists(STAGE_DIR) then fs.delete(STAGE_DIR) end
    removeOldBackups()
    fs.makeDir(STAGE_DIR)
    for relativePath, contents in pairs(FILES) do
        writeFile(fs.combine(STAGE_DIR, relativePath), contents)
    end
    writeFile(fs.combine(STAGE_DIR, "config.lua"), buildConfig(role, display, existingConfig))

    local previousInstall
    if fs.exists(INSTALL_DIR) then
        previousInstall = "/helios.previous"
        local backupNumber = 2
        while fs.exists(previousInstall) do
            previousInstall = "/helios.previous." .. backupNumber
            backupNumber = backupNumber + 1
        end
        fs.move(INSTALL_DIR, previousInstall)
    end

    local ok, reason = pcall(function()
        fs.move(STAGE_DIR, INSTALL_DIR)
        writeFile("/helios.lua", [=[
shell.run("/helios/helios.lua", ...)
]=])
    end)
    if not ok then
        if fs.exists(INSTALL_DIR) then fs.delete(INSTALL_DIR) end
        if previousInstall and fs.exists(previousInstall) then fs.move(previousInstall, INSTALL_DIR) end
        error("Installation failed and the previous install was restored: " .. tostring(reason), 0)
    end

    local autoStarted, startupNote = installStartup()

    title("Installation Complete")
    term.setTextColor(colors.lime)
    print("HELIOS " .. VERSION .. " installed successfully.")
    term.setTextColor(colors.white)
    print("Role: " .. role)
    if display then print("Display: " .. display) end
    if previousInstall then print("Previous version: " .. previousInstall) end
    if autoStarted then
        print("HELIOS will start automatically after reboot.")
    else
        print(startupNote)
    end
    print("")
    print("Run now with: helios")
    print("Check setup with: helios status")
end

local ok, reason = pcall(runInstaller)
if not ok then
    term.setTextColor(colors.red)
    print("")
    print("HELIOS installation failed:")
    print(tostring(reason))
    term.setTextColor(colors.white)
end
