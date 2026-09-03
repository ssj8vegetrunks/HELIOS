-- HELIOS single-file installer
-- Manual-control alpha: guarded direct plant authority.

local VERSION = "1.6.0-alpha.4"
local INSTALL_DIR = "/helios"
local STAGE_DIR = "/.helios-install"
local MODULE_PACK_BASE_URL = "https://raw.githubusercontent.com/ssj8vegetrunks/HELIOS/testing/public-alpha/module-pack"

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

local function findExistingMainframe(timeout)
    local opened = {}
    for _, name in ipairs(peripheral.getNames()) do
        local isModem = false
        for _, peripheralType in ipairs({ peripheral.getType(name) }) do
            if peripheralType == "modem" then isModem = true break end
        end
        if isModem and not rednet.isOpen(name) then
            local ok = pcall(rednet.open, name)
            if ok then opened[#opened + 1] = name end
        end
    end

    local timer = os.startTimer(timeout or 3)
    local found
    while not found do
        local event, sender, message, protocol = os.pullEvent()
        if event == "timer" and sender == timer then break end
        if event == "rednet_message" and protocol == "helios.v1" and
           sender ~= os.getComputerID() and type(message) == "table" and
           message.helios == true and message.kind == "mainframe_presence" then
            found = sender
        end
    end
    if found then pcall(os.cancelTimer, timer) end
    for _, name in ipairs(opened) do pcall(rednet.close, name) end
    return found
end

local function writeFile(path, contents)
    local parent = fs.getDir(path)
    if parent ~= "" and not fs.exists(parent) then
        fs.makeDir(parent)
    end
    local handle, reason = fs.open(path, "w")
    if not handle then error("Could not write " .. path .. ": " .. tostring(reason), 0) end
    local wrote, writeReason = pcall(handle.write, contents)
    local closed, closeReason = pcall(handle.close)
    if not wrote or not closed then
        if fs.exists(path) then pcall(fs.delete, path) end
        error("Could not write " .. path .. ": " ..
            tostring(wrote and closeReason or writeReason), 0)
    end
end

local function fetchText(url)
    if not http or not http.get then
        error("CC:Tweaked HTTP is disabled; the HELIOS Module Pack cannot be downloaded.", 0)
    end
    local handle, reason = http.get(url)
    if not handle then error("Could not download " .. url .. ": " .. tostring(reason), 0) end
    local contents = handle.readAll()
    handle.close()
    return contents
end

local function safeModulePath(path)
    return type(path) == "string" and path ~= "" and
        string.sub(path, 1, 1) ~= "/" and
        not string.find(path, "..", 1, true) and
        not string.find(path, "\\", 1, true)
end

local function validateModuleManifest(manifest)
    if type(manifest) ~= "table" or manifest.schema_version ~= 1 or
       type(manifest.pack) ~= "table" or type(manifest.pack.version) ~= "string" or
       type(manifest.compatible_core_versions) ~= "table" or
       type(manifest.modules) ~= "table" then
        return false, "The downloaded HELIOS Module Pack manifest is invalid."
    end
    local moduleIds, capabilities = {}, {}
    for _, module in ipairs(manifest.modules) do
        if type(module) ~= "table" or type(module.id) ~= "string" or module.id == "" or
           type(module.name) ~= "string" or type(module.version) ~= "string" or
           type(module.provides) ~= "table" then
            return false, "The Module Pack contains invalid module metadata."
        end
        if moduleIds[module.id] then
            return false, "The Module Pack duplicates module id " .. module.id .. "."
        end
        moduleIds[module.id] = true
        for _, provider in ipairs(module.provides) do
            if type(provider) ~= "table" or type(provider.capability) ~= "string" or
               provider.capability == "" or not safeModulePath(provider.path) then
                return false, "The Module Pack contains an invalid capability provider."
            end
            if capabilities[provider.capability] then
                return false, "The Module Pack duplicates capability " .. provider.capability .. "."
            end
            capabilities[provider.capability] = true
        end
    end
    return true
end

local function installModulePack(stageDir)
    local encoded = fetchText(MODULE_PACK_BASE_URL .. "/manifest.json")
    local ok, manifest = pcall(textutils.unserializeJSON, encoded)
    if not ok or type(manifest) ~= "table" then
        error("The downloaded HELIOS Module Pack manifest is invalid.", 0)
    end
    local valid, validationReason = validateModuleManifest(manifest)
    if not valid then error(validationReason, 0) end
    local compatible = false
    for _, version in ipairs(manifest.compatible_core_versions or {}) do
        if version == VERSION then compatible = true break end
    end
    if not compatible then
        error("Module Pack " .. tostring(manifest.pack.version or "unknown") ..
            " is not compatible with HELIOS Core " .. VERSION .. ".", 0)
    end

    local downloaded = {}
    for _, module in ipairs(manifest.modules) do
        for _, provider in ipairs(module.provides or {}) do
            local path = provider.path
            if not safeModulePath(path) then
                error("Module Pack contains an unsafe path: " .. tostring(path), 0)
            end
            if not downloaded[path] then
                writeFile(fs.combine(fs.combine(stageDir, "modules"), path),
                    fetchText(MODULE_PACK_BASE_URL .. "/" .. path))
                downloaded[path] = true
            end
        end
    end
    writeFile(fs.combine(fs.combine(stageDir, "modules"), "manifest.json"), encoded)
    return manifest.pack.version
end

local function removeOldBackups()
    for _, name in ipairs(fs.list("/")) do
        if name == "helios.previous" or string.match(name, "^helios%.previous%.%d+$") then
            fs.delete("/" .. name)
        end
    end
end

local FILES

local function embeddedInstallBytes(configText, role)
    local bytes = #configText
    for _, contents in pairs(FILES) do
        bytes = bytes + #contents
    end
    -- A staged upgrade temporarily coexists with the installed copy. CC's
    -- filesystem bookkeeping, the HTTP response, and the external module pack
    -- need substantially more headroom than their raw file sizes suggest on a
    -- 1 MB computer. If this reserve is unavailable, use the data-preserving
    -- in-place upgrade path instead of failing near the end of installation.
    if role == "mainframe" then bytes = bytes + (256 * 1024) end
    return bytes
end

local function removeReplaceableInstallFiles()
    if not fs.exists(INSTALL_DIR) then return end
    for _, name in ipairs({ "core", "draconic", "gui", "mainframe", "terminal", "modules", "helios.lua" }) do
        local path = fs.combine(INSTALL_DIR, name)
        if fs.exists(path) then fs.delete(path) end
    end
end

local function installStageInPlace()
    if not fs.exists(INSTALL_DIR) then fs.makeDir(INSTALL_DIR) end
    for _, name in ipairs(fs.list(STAGE_DIR)) do
        local source = fs.combine(STAGE_DIR, name)
        local destination = fs.combine(INSTALL_DIR, name)
        if fs.exists(destination) then fs.delete(destination) end
        fs.move(source, destination)
    end
    fs.delete(STAGE_DIR)
end

FILES = {
    ["core/config.lua"] = [=[
local config = {}

-- @section CONFIGURATION DEFAULTS AND MIGRATION
function config.load()
    if not fs.exists("/helios/config.lua") then
        error("HELIOS configuration is missing. Run the installer again.", 0)
    end
    local loaded = dofile("/helios/config.lua")
    if type(loaded) ~= "table" then
        error("HELIOS configuration is invalid.", 0)
    end
    if loaded.role ~= "mainframe" and loaded.role ~= "terminal" and
       loaded.role ~= "guardian" and loaded.role ~= "profiler" then
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
    loaded.ui.renderer = type(loaded.ui.renderer) == "string" and loaded.ui.renderer or "default"
    loaded.control = loaded.control or {}
    -- Manual authority is deliberately never restored after a reboot.
    loaded.control.mode = "automatic"
    loaded.control.manualSafetyReserve = math.max(0.5, math.min(25,
        tonumber(loaded.control.manualSafetyReserve) or 2))
    loaded.control.actuatorsEnabled = loaded.role == "mainframe"
    if loaded.control.mainframeAuthority ~= "control" and
       loaded.control.mainframeAuthority ~= "monitor" then
        loaded.control.mainframeAuthority = "auto"
    end
    loaded.control.targetRpm = tonumber(loaded.control.targetRpm) or 1800
    loaded.control.rpmDeadband = math.max(1, tonumber(loaded.control.rpmDeadband) or 25)
    loaded.control.overspeedRpm = math.max(loaded.control.targetRpm + loaded.control.rpmDeadband,
        tonumber(loaded.control.overspeedRpm) or 2000)
    loaded.control.overspeedSamples = math.max(1,
        math.floor(tonumber(loaded.control.overspeedSamples) or 3))
    loaded.control.storageLow = tonumber(loaded.control.storageLow) or 25
    loaded.control.storageHigh = tonumber(loaded.control.storageHigh) or 85
    loaded.control.assistedIdleRpmRatio = math.max(0.25, math.min(0.95,
        tonumber(loaded.control.assistedIdleRpmRatio) or 0.75))
    loaded.control.assistedIdleFlow = math.max(1,
        tonumber(loaded.control.assistedIdleFlow) or 250)
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
        tonumber(loaded.control.reactorSteamReserveMargin) or 0.15))
    loaded.control.reactorSteamPrimeMargin = math.max(
        loaded.control.reactorSteamReserveMargin, math.min(2,
            tonumber(loaded.control.reactorSteamPrimeMargin) or 0.90))
    loaded.control.reactorSteamAverageSamples = math.max(3,
        math.floor(tonumber(loaded.control.reactorSteamAverageSamples) or 10))
    loaded.control.reactorHotFluidHigh = math.max(50, math.min(99,
        tonumber(loaded.control.reactorHotFluidHigh) or 85))
    loaded.control.calibrationBufferReady = math.max(50, math.min(
        loaded.control.reactorHotFluidHigh,
        tonumber(loaded.control.calibrationBufferReady) or 85))
    loaded.control.reactorHotFluidLow = math.max(1, math.min(
        loaded.control.reactorHotFluidHigh - 1,
        tonumber(loaded.control.reactorHotFluidLow) or 15))
    loaded.control.maxRodEquivalentStep = math.max(0.01, math.min(1,
        tonumber(loaded.control.maxRodEquivalentStep) or 0.25))
    loaded.control.reactorLearningSamples = math.max(3,
        math.floor(tonumber(loaded.control.reactorLearningSamples) or 8))
    loaded.control.reactorLearningSteamDelta = math.max(1,
        tonumber(loaded.control.reactorLearningSteamDelta) or 10)
    loaded.control.reactorLearningSteamTolerance = math.max(0.005, math.min(0.25,
        tonumber(loaded.control.reactorLearningSteamTolerance) or 0.05))
    loaded.control.reactorLearningTemperatureDelta = math.max(0.01,
        tonumber(loaded.control.reactorLearningTemperatureDelta) or 0.1)
    loaded.control.reactorLearningBufferDelta = math.max(0.01,
        tonumber(loaded.control.reactorLearningBufferDelta) or 0.1)
    loaded.control.reactorMinimumResponseTime = math.max(5,
        tonumber(loaded.control.reactorMinimumResponseTime) or 15)
    loaded.control.reactorSettleTimeout = math.max(
        loaded.control.reactorMinimumResponseTime + 5,
        tonumber(loaded.control.reactorSettleTimeout) or 90)
    loaded.control.reactorProfiles = loaded.control.reactorProfiles or {}
    loaded.control.powerReactorProfiles = loaded.control.powerReactorProfiles or {}
    loaded.control.powerReactorCalibrationSamples = math.max(3,
        math.floor(tonumber(loaded.control.powerReactorCalibrationSamples) or 10))
    loaded.control.reactorCommissioningSteamTarget = math.max(1,
        tonumber(loaded.control.reactorCommissioningSteamTarget) or 1000)
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
    loaded.network = loaded.network or {}
    loaded.network.siteId = type(loaded.network.siteId) == "string" and
        loaded.network.siteId ~= "" and loaded.network.siteId or "default"
    return loaded
end

-- @section CONFIGURATION STORAGE
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

-- @section MONITOR DISCOVERY AND MIRRORING
local native = term.current()
local monitors = {}
local proxy
local monitorProxy
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

local function monitorMirror(method, ...)
    for _, monitor in ipairs(monitors) do pcall(monitor[method], ...) end
end

local function monitorValue(method, fallback, ...)
    local monitor = monitors[1]
    if monitor then
        local ok, a, b = pcall(monitor[method], ...)
        if ok then return a, b end
    end
    return fallback[method](...)
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
    target.getSize = function(...)
        local width, height = native.getSize(...)
        for _, monitor in ipairs(monitors) do
            local ok, monitorWidth, monitorHeight = pcall(monitor.getSize)
            if ok then
                width = math.min(width, monitorWidth)
                height = math.min(height, monitorHeight)
            end
        end
        return width, height
    end
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


local function buildMonitorProxy()
    local target = {}
    target.write = function(...) return monitorMirror("write", ...) end
    target.blit = function(...) return monitorMirror("blit", ...) end
    target.clear = function(...) refreshMonitors(); return monitorMirror("clear", ...) end
    target.clearLine = function(...) return monitorMirror("clearLine", ...) end
    target.getCursorPos = function(...) return monitorValue("getCursorPos", native, ...) end
    target.setCursorPos = function(...) return monitorMirror("setCursorPos", ...) end
    target.setCursorBlink = function(...) return monitorMirror("setCursorBlink", ...) end
    target.getCursorBlink = function(...) return monitorValue("getCursorBlink", native, ...) end
    target.isColor = function(...) return monitorValue("isColor", native, ...) end
    target.getSize = function(...)
        local width, height
        for _, monitor in ipairs(monitors) do
            local ok, monitorWidth, monitorHeight = pcall(monitor.getSize)
            if ok then
                width = width and math.min(width, monitorWidth) or monitorWidth
                height = height and math.min(height, monitorHeight) or monitorHeight
            end
        end
        if not width then return native.getSize(...) end
        return width, height
    end
    target.scroll = function(...) return monitorMirror("scroll", ...) end
    target.setTextColor = function(...) return monitorMirror("setTextColor", ...) end
    target.getTextColor = function(...) return monitorValue("getTextColor", native, ...) end
    target.setTextColour = target.setTextColor
    target.getTextColour = target.getTextColor
    target.setBackgroundColor = function(...) return monitorMirror("setBackgroundColor", ...) end
    target.getBackgroundColor = function(...) return monitorValue("getBackgroundColor", native, ...) end
    target.setBackgroundColour = target.setBackgroundColor
    target.getBackgroundColour = target.getBackgroundColor
    target.isColour = target.isColor
    target.setPaletteColor = function(...) return monitorMirror("setPaletteColor", ...) end
    target.getPaletteColor = function(...) return monitorValue("getPaletteColor", native, ...) end
    target.setPaletteColour = target.setPaletteColor
    target.getPaletteColour = target.getPaletteColor
    return target
end

-- @section DISPLAY LIFECYCLE
function display.start(config)
    if active then return end
    textScale = tonumber(config and config.ui and config.ui.monitorTextScale) or 0.5
    textScale = math.max(0.5, math.min(5, textScale))
    refreshMonitors()
    proxy = buildProxy()
    monitorProxy = buildMonitorProxy()
    term.redirect(proxy)
    active = true
end

function display.useNative()
    term.redirect(native)
end

function display.useMonitors()
    refreshMonitors()
    term.redirect(monitorProxy)
end

function display.useMirrored()
    refreshMonitors()
    term.redirect(proxy)
end

function display.monitorSize()
    refreshMonitors()
    if #monitors == 0 then return nil end
    return monitorProxy.getSize()
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

    ["core/facility_protocol.lua"] = [=[
local protocol = {}

protocol.name = "helios.facility"
protocol.version = 1
protocol.rednetProtocol = "helios.facility.v1"

local kinds = {
    hello = true,
    collector_presence = true,
    welcome = true,
    heartbeat = true,
    telemetry = true,
    emergency_command = true,
    ui_offer = true,
    ui_request = true,
    acknowledgement = true,
    status = true,
    error = true,
}

local roles = {
    guardian = true,
    facility = true,
    mainframe = true,
    overseer = true,
}

local function finite(value)
    return type(value) == "number" and value == value and
        value ~= math.huge and value ~= -math.huge
end

local function copySafe(value, state, depth)
    local kind = type(value)
    if kind == "nil" or kind == "boolean" or kind == "string" then return value end
    if kind == "number" then return finite(value) and value or nil end
    if kind ~= "table" then return nil end

    state = state or { seen = {}, entries = 0 }
    depth = depth or 0
    if depth >= 8 then state.invalid = "Payload nesting exceeds 8 levels" return nil end
    if state.seen[value] then state.invalid = "Payload contains a cycle" return nil end
    state.seen[value] = true

    local result = {}
    for key, item in pairs(value) do
        state.entries = state.entries + 1
        if state.entries > 512 then
            state.invalid = "Payload exceeds 512 entries"
            return nil
        end
        local keyType = type(key)
        local safeKey = (keyType == "string" or keyType == "boolean" or
            (keyType == "number" and finite(key))) and key or nil
        local safeValue = copySafe(item, state, depth + 1)
        if safeKey ~= nil and safeValue ~= nil then result[safeKey] = safeValue end
    end
    state.seen[value] = nil
    return result
end

local function sanitize(value)
    local state = { seen = {}, entries = 0 }
    local result = copySafe(value, state, 0)
    if state.invalid then return nil, state.invalid end
    return result
end

local function nonempty(value, limit)
    return type(value) == "string" and value ~= "" and #value <= (limit or 96)
end

local function validSequence(value)
    return finite(value) and value >= 0 and value % 1 == 0
end

local function validateSource(source)
    if type(source) ~= "table" then return nil, "Message source is required" end
    if not finite(source.computerId) or source.computerId < 0 or source.computerId % 1 ~= 0 then
        return nil, "Source computerId must be a non-negative integer"
    end
    if not nonempty(source.nodeId) then return nil, "Source nodeId is required" end
    if not nonempty(source.sessionId, 160) then return nil, "Source sessionId is required" end
    if not roles[source.role] then return nil, "Unsupported source role" end
    return {
        computerId = source.computerId,
        nodeId = source.nodeId,
        sessionId = source.sessionId,
        role = source.role,
        software = nonempty(source.software) and source.software or nil,
        softwareVersion = nonempty(source.softwareVersion) and source.softwareVersion or nil,
    }
end

function protocol.identity(fields)
    fields = fields or {}
    local source, reason = validateSource({
        computerId = fields.computerId == nil and os.getComputerID() or fields.computerId,
        nodeId = fields.nodeId,
        sessionId = fields.sessionId,
        role = fields.role,
        software = fields.software,
        softwareVersion = fields.softwareVersion,
    })
    if not source then return nil, reason end
    return source
end

function protocol.messageId(message)
    if type(message) ~= "table" or type(message.source) ~= "table" or
       not nonempty(message.source.sessionId, 160) or not validSequence(message.sequence) then
        return nil
    end
    return message.source.sessionId .. ":" .. tostring(message.sequence)
end

function protocol.make(kind, source, sequence, payload, sentAt)
    if not kinds[kind] then return nil, "Unsupported facility message kind" end
    local cleanSource, sourceError = validateSource(source)
    if not cleanSource then return nil, sourceError end
    if not validSequence(sequence) then return nil, "Sequence must be a non-negative integer" end
    local cleanPayload, payloadError = sanitize(payload or {})
    if cleanPayload == nil then return nil, payloadError or "Payload is not safely serializable" end
    sentAt = sentAt == nil and (os.epoch("utc") / 1000) or sentAt
    if not finite(sentAt) or sentAt < 0 then return nil, "sentAt must be a valid timestamp" end

    local message = {
        helios = true,
        contract = protocol.name,
        contractVersion = protocol.version,
        kind = kind,
        source = cleanSource,
        sequence = sequence,
        sentAt = sentAt,
        payload = cleanPayload,
    }
    message.messageId = protocol.messageId(message)
    return message
end

function protocol.validate(message, expectedKind)
    if type(message) ~= "table" or message.helios ~= true then
        return nil, "Not a HELIOS facility message"
    end
    if message.contract ~= protocol.name or message.contractVersion ~= protocol.version then
        return nil, "Unsupported facility contract"
    end
    if not kinds[message.kind] or (expectedKind and message.kind ~= expectedKind) then
        return nil, "Unexpected facility message kind"
    end
    local source, sourceError = validateSource(message.source)
    if not source then return nil, sourceError end
    if not validSequence(message.sequence) then return nil, "Invalid facility sequence" end
    if not finite(message.sentAt) or message.sentAt < 0 then
        return nil, "Invalid facility timestamp"
    end
    local payload, payloadError = sanitize(message.payload or {})
    if payload == nil then return nil, payloadError or "Unsafe facility payload" end

    local clean = {
        helios = true,
        contract = protocol.name,
        contractVersion = protocol.version,
        kind = message.kind,
        source = source,
        sequence = message.sequence,
        sentAt = message.sentAt,
        payload = payload,
    }
    clean.messageId = protocol.messageId(clean)
    if message.messageId ~= nil and message.messageId ~= clean.messageId then
        return nil, "Facility messageId does not match its source and sequence"
    end
    return clean
end

function protocol.acknowledge(message, source, sequence, status, detail, sentAt)
    local original, reason = protocol.validate(message)
    if not original then return nil, reason end
    status = status or "accepted"
    if status ~= "accepted" and status ~= "rejected" and status ~= "duplicate" then
        return nil, "Unsupported acknowledgement status"
    end
    return protocol.make("acknowledgement", source, sequence, {
        messageId = original.messageId,
        status = status,
        detail = detail and tostring(detail) or nil,
    }, sentAt)
end

function protocol.newSequenceTracker()
    return { sessions = {} }
end

function protocol.acceptSequence(tracker, message)
    if type(tracker) ~= "table" or type(tracker.sessions) ~= "table" then
        return false, "Invalid sequence tracker"
    end
    local clean, reason = protocol.validate(message)
    if not clean then return false, reason end
    local key = tostring(clean.source.computerId) .. ":" .. clean.source.sessionId
    local previous = tracker.sessions[key]
    if previous ~= nil and clean.sequence <= previous then
        return false, clean.sequence == previous and "duplicate" or "stale"
    end
    tracker.sessions[key] = clean.sequence
    return true, clean
end

function protocol.describe()
    local supported = {}
    for kind in pairs(kinds) do supported[#supported + 1] = kind end
    table.sort(supported)
    return {
        name = protocol.name,
        version = protocol.version,
        rednetProtocol = protocol.rednetProtocol,
        messageKinds = supported,
        remoteCommands = false,
        emergencyCommands = true,
    }
end

return protocol
]=],

    ["core/gui.lua"] = [=[
local gui = {}

local function clamp(value, low, high)
    value = tonumber(value) or 0
    return math.max(low, math.min(high, value))
end

function gui.prepare()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
end

function gui.text(x, y, value, foreground, background, width)
    local screenWidth, screenHeight = term.getSize()
    if y < 1 or y > screenHeight or x > screenWidth then return end
    x = math.max(1, x)
    local text = tostring(value or "")
    width = math.max(0, math.min(tonumber(width) or #text, screenWidth - x + 1))
    text = string.sub(text, 1, width)
    if #text < width then text = text .. string.rep(" ", width - #text) end
    term.setCursorPos(x, y)
    term.setBackgroundColor(background or colors.black)
    term.setTextColor(foreground or colors.white)
    term.write(text)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
end

function gui.button(x, y, label, foreground, background)
    local text = "[" .. tostring(label) .. "]"
    gui.text(x, y, text, foreground, background)
    return { x1 = x, x2 = x + #text - 1, y = y }
end

function gui.hit(button, x, y)
    return button and x and y and y == button.y and x >= button.x1 and x <= button.x2
end

function gui.progress(x, y, width, percent, foreground, background)
    width = math.max(1, math.floor(tonumber(width) or 1))
    percent = clamp(percent, 0, 100)
    local filled = math.floor(width * percent / 100 + 0.5)
    gui.text(x, y, string.rep(" ", filled), colors.white, foreground or colors.lime)
    gui.text(x + filled, y, string.rep(" ", width - filled), colors.white,
        background or colors.gray)
    return filled
end

function gui.rpmGauge(x, y, width, rpm)
    width = math.max(10, math.floor(tonumber(width) or 10))
    local zones = {
        { limit = 800, colour = colors.orange },
        { limit = 1000, colour = colors.lime },
        { limit = 1700, colour = colors.orange },
        { limit = 1900, colour = colors.lime },
        { limit = 2100, colour = colors.red },
    }
    local previous, used = 0, 0
    for index, zone in ipairs(zones) do
        local segment
        if index == #zones then
            segment = width - used
        else
            segment = math.max(1, math.floor(width * (zone.limit - previous) / 2100))
        end
        gui.text(x + used, y, string.rep(" ", segment), colors.white, zone.colour)
        used = used + segment
        previous = zone.limit
    end
    local marker = math.floor(clamp(rpm, 0, 2100) / 2100 * (width - 1))
    gui.text(x + marker, y, "^", colors.white, colors.black)
    return marker
end

return gui
]=],

    ["core/gui_loader.lua"] = [=[
local loader = {}
local ROOT = "/helios/gui"

local function compatible(manifest, coreVersion)
    for _, version in ipairs(manifest.compatibleCoreVersions or {}) do
        if version == coreVersion or version == "*" then return true end
    end
    return false
end

local function inspect(id, coreVersion)
    if type(id) ~= "string" or id == "" or string.find(id, "[^%w_%-]") then
        return nil, "Invalid GUI module id"
    end
    local root = ROOT .. "/" .. id
    local manifestPath = root .. "/manifest.lua"
    if not fs.exists(manifestPath) then return nil, "Missing " .. manifestPath end
    local ok, manifest = pcall(dofile, manifestPath)
    if not ok or type(manifest) ~= "table" then return nil, "Invalid GUI manifest: " .. tostring(manifest) end
    if manifest.id ~= id or type(manifest.name) ~= "string" or
       tonumber(manifest.apiVersion) ~= 1 or type(manifest.entry) ~= "string" or
       string.find(manifest.entry, "..", 1, true) or string.find(manifest.entry, "[/\\]") then
        return nil, "GUI manifest contains invalid metadata"
    end
    if not compatible(manifest, coreVersion) then
        return nil, "GUI module is not compatible with HELIOS " .. tostring(coreVersion)
    end
    manifest.path = root .. "/" .. manifest.entry
    manifest.minimumWidth = math.max(1, math.floor(tonumber(manifest.minimumWidth) or 1))
    manifest.minimumHeight = math.max(1, math.floor(tonumber(manifest.minimumHeight) or 1))
    if not fs.exists(manifest.path) then return nil, "GUI renderer is missing: " .. manifest.path end
    return manifest
end

function loader.scan(coreVersion)
    local modules = {{ id = "default", name = "Built-in Default", apiVersion = 1,
        minimumWidth = 1, minimumHeight = 1, builtin = true }}
    if not fs.exists(ROOT) then return modules end
    for _, id in ipairs(fs.list(ROOT)) do
        if fs.isDir(ROOT .. "/" .. id) then
            local manifest = inspect(id, coreVersion)
            if manifest then modules[#modules + 1] = manifest end
        end
    end
    table.sort(modules, function(a, b)
        if a.builtin then return true end
        if b.builtin then return false end
        return a.name < b.name
    end)
    return modules
end

function loader.resolve(id, coreVersion)
    if id == nil or id == "default" then
        return { id = "default", name = "Built-in Default", builtin = true,
            minimumWidth = 1, minimumHeight = 1 }
    end
    return inspect(id, coreVersion)
end

function loader.load(id, coreVersion, width, height)
    local manifest, reason = loader.resolve(id, coreVersion)
    if not manifest then return nil, reason end
    if manifest.builtin then return nil, "Built-in renderer selected" end
    if width < manifest.minimumWidth or height < manifest.minimumHeight then
        return nil, ("%s requires at least %dx%d characters; this display is %dx%d"):
            format(manifest.name, manifest.minimumWidth, manifest.minimumHeight, width, height)
    end
    local ok, renderer = pcall(dofile, manifest.path)
    if not ok or type(renderer) ~= "table" or type(renderer.render) ~= "function" or
       type(renderer.handle) ~= "function" then
        return nil, "GUI renderer failed to load: " .. tostring(renderer)
    end
    return renderer, manifest
end

function loader.install(baseUrl, coreVersion)
    if not http or not http.get or type(baseUrl) ~= "string" then
        return nil, "HTTP is unavailable or the module URL is invalid"
    end
    baseUrl = string.gsub(baseUrl, "/+$", "")
    local function fetch(url)
        local handle, reason = http.get(url)
        if not handle then return nil, reason end
        local body = handle.readAll()
        handle.close()
        return body
    end
    local manifestText, reason = fetch(baseUrl .. "/manifest.lua")
    if not manifestText then return nil, "Could not download GUI manifest: " .. tostring(reason) end
    local fn, parseReason = load(manifestText, "gui manifest", "t", {})
    if not fn then return nil, "GUI manifest is invalid: " .. tostring(parseReason) end
    local ok, manifest = pcall(fn)
    if not ok or type(manifest) ~= "table" or type(manifest.id) ~= "string" or
       string.find(manifest.id, "[^%w_%-]") or type(manifest.entry) ~= "string" or
       string.find(manifest.entry, "[/\\]") or string.find(manifest.entry, "..", 1, true) then
        return nil, "GUI manifest contains unsafe metadata"
    end
    local rendererText, rendererReason = fetch(baseUrl .. "/" .. manifest.entry)
    if not rendererText then return nil, "Could not download GUI renderer: " .. tostring(rendererReason) end
    local root = ROOT .. "/" .. manifest.id
    if not fs.exists(ROOT) then fs.makeDir(ROOT) end
    if not fs.exists(root) then fs.makeDir(root) end
    local function write(path, body)
        local handle, openReason = fs.open(path, "w")
        if not handle then return false, openReason end
        handle.write(body); handle.close(); return true
    end
    local wrote, writeReason = write(root .. "/manifest.lua", manifestText)
    if not wrote then return nil, writeReason end
    wrote, writeReason = write(root .. "/" .. manifest.entry, rendererText)
    if not wrote then return nil, writeReason end
    local installed, validationReason = inspect(manifest.id, coreVersion)
    if not installed then return nil, validationReason end
    return installed
end

return loader
]=],

    ["core/mainframe_authority.lua"] = [=[
local authority = {}

local function normalise(mode)
    if mode == "control" or mode == "monitor" then return mode end
    return "auto"
end

function authority.new(mode, localId)
    return { mode = normalise(mode), localId = tonumber(localId), peers = {} }
end

function authority.observe(state, sender, message, now)
    if type(message) ~= "table" or message.kind ~= "mainframe_presence" then return false end
    local id = tonumber(sender)
    if not id or id == state.localId then return false end
    state.peers[tostring(id)] = {
        id = id,
        mode = normalise(message.authority),
        lastSeen = tonumber(now) or 0,
    }
    local previous = state.mode
    if message.authority == "control" and
       (state.mode == "auto" or (state.mode == "control" and id < state.localId)) then
        state.mode = "monitor"
    end
    return state.mode ~= previous
end

function authority.expire(state, now, timeout)
    local changed = false
    for key, peer in pairs(state.peers) do
        if (tonumber(now) or 0) - (tonumber(peer.lastSeen) or 0) > (timeout or 5) then
            state.peers[key] = nil
            changed = true
        end
    end
    return changed
end

function authority.select(state, mode)
    state.mode = normalise(mode)
    if state.mode == "control" then
        for _, peer in pairs(state.peers) do
            if peer.mode == "control" and peer.id < state.localId then
                state.mode = "monitor"
                break
            end
        end
    end
    return state.mode
end

function authority.peerCount(state)
    local count = 0
    for _ in pairs(state.peers) do count = count + 1 end
    return count
end

function authority.controllingPeer(state)
    for _, peer in pairs(state.peers) do
        if peer.mode == "control" then return peer end
    end
end

function authority.needsSelection(state)
    return state.mode == "auto" and authority.peerCount(state) > 0
end

function authority.canControl(state)
    return state.mode == "control" or
        (state.mode == "auto" and authority.peerCount(state) == 0)
end

return authority
]=],

    ["core/module_loader.lua"] = [=[
-- @section MODULE PACK MANIFEST
local loader = {}
local ROOT = "/helios/modules"
local MANIFEST_PATH = ROOT .. "/manifest.json"

local manifestCache

local function readFile(path)
    local handle, reason = fs.open(path, "r")
    if not handle then return nil, reason end
    local contents = handle.readAll()
    handle.close()
    return contents
end

local function safeRelativePath(path)
    return type(path) == "string" and path ~= "" and
        string.sub(path, 1, 1) ~= "/" and
        not string.find(path, "..", 1, true) and
        not string.find(path, "\\", 1, true)
end

local function validateManifest(manifest)
    if type(manifest) ~= "table" or manifest.schema_version ~= 1 or
       type(manifest.pack) ~= "table" or type(manifest.pack.version) ~= "string" or
       type(manifest.compatible_core_versions) ~= "table" or
       type(manifest.modules) ~= "table" then
        return false, "Module manifest uses an unsupported schema"
    end
    local moduleIds, capabilities = {}, {}
    for _, module in ipairs(manifest.modules) do
        if type(module) ~= "table" or type(module.id) ~= "string" or module.id == "" or
           type(module.name) ~= "string" or type(module.version) ~= "string" or
           type(module.provides) ~= "table" then
            return false, "Module manifest contains invalid module metadata"
        end
        if moduleIds[module.id] then
            return false, "Module manifest duplicates module id " .. module.id
        end
        moduleIds[module.id] = true
        for _, provider in ipairs(module.provides) do
            if type(provider) ~= "table" or type(provider.capability) ~= "string" or
               provider.capability == "" or not safeRelativePath(provider.path) then
                return false, "Module manifest contains an invalid capability provider"
            end
            if capabilities[provider.capability] then
                return false, "Module manifest duplicates capability " .. provider.capability
            end
            capabilities[provider.capability] = true
        end
    end
    return true
end

local function coreCompatible(manifest, coreVersion)
    if not coreVersion then return true end
    for _, version in ipairs(manifest.compatible_core_versions or {}) do
        if version == coreVersion then return true end
    end
    return false
end

function loader.manifest(coreVersion)
    if not manifestCache then
        local encoded, reason = readFile(MANIFEST_PATH)
        if not encoded then return nil, "Module manifest unavailable: " .. tostring(reason) end
        local ok, decoded = pcall(textutils.unserializeJSON, encoded)
        if not ok or type(decoded) ~= "table" then
            return nil, "Module manifest is invalid JSON"
        end
        local valid, validationReason = validateManifest(decoded)
        if not valid then return nil, validationReason end
        manifestCache = decoded
    end
    if not coreCompatible(manifestCache, coreVersion) then
        return nil, "Module Pack " .. tostring((manifestCache.pack or {}).version or "unknown") ..
            " is not compatible with HELIOS Core " .. tostring(coreVersion)
    end
    return manifestCache
end

-- @section MODULE RESOLUTION AND LOADING
function loader.resolve(capability, coreVersion)
    local manifest, reason = loader.manifest(coreVersion)
    if not manifest then return nil, reason end
    for _, module in ipairs(manifest.modules) do
        for _, provider in ipairs(module.provides or {}) do
            if provider.capability == capability then
                if not safeRelativePath(provider.path) then
                    return nil, "Module path is unsafe: " .. tostring(provider.path)
                end
                return {
                    path = ROOT .. "/" .. provider.path,
                    capability = capability,
                    moduleId = module.id,
                    moduleName = module.name,
                    moduleVersion = module.version,
                    packVersion = manifest.pack.version,
                }
            end
        end
    end
    return nil, "No installed HELIOS module provides " .. tostring(capability)
end

function loader.load(capability, coreVersion)
    local resolved, reason = loader.resolve(capability, coreVersion)
    if not resolved then return nil, reason end
    if not fs.exists(resolved.path) then
        return nil, "Module file is missing: " .. resolved.path
    end
    local ok, implementation = pcall(dofile, resolved.path)
    if not ok then return nil, "Module failed to load: " .. tostring(implementation) end
    if type(implementation) ~= "table" then
        return nil, "Module did not return an adapter table: " .. resolved.path
    end
    return implementation, resolved
end

function loader.versions(coreVersion)
    local manifest, reason = loader.manifest(coreVersion)
    if not manifest then return nil, reason end
    local versions = {
        pack = manifest.pack.version,
        modules = {},
    }
    for _, module in ipairs(manifest.modules) do
        versions.modules[#versions.modules + 1] = {
            id = module.id,
            name = module.name,
            version = module.version,
        }
    end
    return versions
end

return loader
]=],

    ["core/module_manager.lua"] = [=[
-- @section MODULE PACK DOWNLOAD AND VALIDATION
local manager = {}
local BASE_URL = "https://raw.githubusercontent.com/ssj8vegetrunks/HELIOS/agent/ui-module-contract-alpha4/module-pack"
local MODULE_DIR = "/helios/modules"
local STAGE_DIR = "/.helios-module-update"
local BACKUP_DIR = "/helios/modules.previous"

local function fetchText(url)
    if not http or not http.get then
        return nil, "CC:Tweaked HTTP is disabled"
    end
    local handle, reason = http.get(url)
    if not handle then return nil, tostring(reason) end
    local contents = handle.readAll()
    handle.close()
    return contents
end

local function writeFile(path, contents)
    local parent = fs.getDir(path)
    if parent ~= "" and not fs.exists(parent) then fs.makeDir(parent) end
    local handle, reason = fs.open(path, "w")
    if not handle then return false, reason end
    local wrote, writeReason = pcall(handle.write, contents)
    local closed, closeReason = pcall(handle.close)
    if not wrote or not closed then
        if fs.exists(path) then pcall(fs.delete, path) end
        return false, tostring(wrote and closeReason or writeReason)
    end
    return true
end

local function safeRelativePath(path)
    return type(path) == "string" and path ~= "" and
        string.sub(path, 1, 1) ~= "/" and
        not string.find(path, "..", 1, true) and
        not string.find(path, "\\", 1, true)
end

local function validateManifest(manifest)
    if type(manifest) ~= "table" or manifest.schema_version ~= 1 or
       type(manifest.pack) ~= "table" or type(manifest.pack.version) ~= "string" or
       type(manifest.compatible_core_versions) ~= "table" or
       type(manifest.modules) ~= "table" then
        return false, "Downloaded Module Pack manifest is invalid"
    end
    local moduleIds, capabilities = {}, {}
    for _, module in ipairs(manifest.modules) do
        if type(module) ~= "table" or type(module.id) ~= "string" or module.id == "" or
           type(module.name) ~= "string" or type(module.version) ~= "string" or
           type(module.provides) ~= "table" then
            return false, "Downloaded Module Pack contains invalid module metadata"
        end
        if moduleIds[module.id] then
            return false, "Downloaded Module Pack duplicates module id " .. module.id
        end
        moduleIds[module.id] = true
        for _, provider in ipairs(module.provides) do
            if type(provider) ~= "table" or type(provider.capability) ~= "string" or
               provider.capability == "" or not safeRelativePath(provider.path) then
                return false, "Downloaded Module Pack contains an invalid capability provider"
            end
            if capabilities[provider.capability] then
                return false, "Downloaded Module Pack duplicates capability " .. provider.capability
            end
            capabilities[provider.capability] = true
        end
    end
    return true
end

local function compatible(manifest, coreVersion)
    for _, version in ipairs(manifest.compatible_core_versions or {}) do
        if version == coreVersion then return true end
    end
    return false
end

local function download(coreVersion)
    local encoded, reason = fetchText(BASE_URL .. "/manifest.json")
    if not encoded then return nil, "Could not download Module Pack manifest: " .. reason end
    local ok, manifest = pcall(textutils.unserializeJSON, encoded)
    if not ok or type(manifest) ~= "table" then
        return nil, "Downloaded Module Pack manifest is invalid"
    end
    local valid, validationReason = validateManifest(manifest)
    if not valid then return nil, validationReason end
    if not compatible(manifest, coreVersion) then
        return nil, "Module Pack " .. tostring(manifest.pack.version or "unknown") ..
            " is incompatible with HELIOS Core " .. tostring(coreVersion)
    end

    if fs.exists(STAGE_DIR) then fs.delete(STAGE_DIR) end
    fs.makeDir(STAGE_DIR)
    local downloaded = {}
    for _, module in ipairs(manifest.modules) do
        for _, provider in ipairs(module.provides or {}) do
            local path = provider.path
            if not safeRelativePath(path) then
                fs.delete(STAGE_DIR)
                return nil, "Module Pack contains an unsafe path: " .. tostring(path)
            end
            if not downloaded[path] then
                local contents, fileReason = fetchText(BASE_URL .. "/" .. path)
                if not contents then
                    fs.delete(STAGE_DIR)
                    return nil, "Could not download " .. path .. ": " .. tostring(fileReason)
                end
                local wrote, writeReason = writeFile(fs.combine(STAGE_DIR, path), contents)
                if not wrote then
                    fs.delete(STAGE_DIR)
                    return nil, "Could not stage " .. path .. ": " .. tostring(writeReason)
                end
                downloaded[path] = true
            end
        end
    end
    local wrote, writeReason = writeFile(fs.combine(STAGE_DIR, "manifest.json"), encoded)
    if not wrote then
        fs.delete(STAGE_DIR)
        return nil, "Could not stage manifest: " .. tostring(writeReason)
    end
    return manifest
end

-- @section ATOMIC MODULE PACK UPDATE
function manager.update(coreVersion)
    local manifest, reason = download(coreVersion)
    if not manifest then return false, reason end
    if fs.exists(BACKUP_DIR) then fs.delete(BACKUP_DIR) end
    if fs.exists(MODULE_DIR) then fs.move(MODULE_DIR, BACKUP_DIR) end
    local ok, moveReason = pcall(fs.move, STAGE_DIR, MODULE_DIR)
    if not ok then
        if fs.exists(MODULE_DIR) then fs.delete(MODULE_DIR) end
        if fs.exists(BACKUP_DIR) then fs.move(BACKUP_DIR, MODULE_DIR) end
        return false, "Module Pack update rolled back: " .. tostring(moveReason)
    end
    if fs.exists(BACKUP_DIR) then fs.delete(BACKUP_DIR) end
    return true, manifest.pack.version
end

return manager
]=],

    ["core/network.lua"] = [=[
local network = {}

-- @section MODEM AND REDNET TRANSPORT
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

function network.sendOn(protocol, target, message)
    if type(protocol) ~= "string" or protocol == "" or
       type(target) ~= "number" or type(message) ~= "table" then return false end
    return rednet.send(target, message, protocol)
end

function network.broadcastOn(protocol, message)
    if type(protocol) ~= "string" or protocol == "" or type(message) ~= "table" then
        return false
    end
    rednet.broadcast(message, protocol)
    return true
end

function network.send(target, message)
    return network.sendOn(network.protocol, target, message)
end

function network.broadcast(message)
    return network.broadcastOn(network.protocol, message)
end

function network.valid(message, kind)
    return type(message) == "table" and message.helios == true and
        (kind == nil or message.kind == kind)
end

function network.now()
    return os.epoch("utc") / 1000
end

-- @section SESSION IDENTITY AND PEERS
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

-- @section POWER UNIT CONVERSION AND FORMATTING
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
-- @section UI STATE AND INPUT
local idConflicts = {}
local systemVersion
local criticalAlarm = false

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

function ui.setCriticalAlarm(active)
    criticalAlarm = active == true
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

-- @section RENDERING PRIMITIVES
function ui.prepare()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
end

function ui.line(value, colour)
    local width = select(1, term.getSize())
    term.setTextColor(colour or colors.white)
    print(string.sub(tostring(value or ""), 1, width))
    term.setTextColor(colors.white)
end

function ui.block(value, colour, maxRows)
    local width = select(1, term.getSize())
    local remaining = tostring(value or "")
    local rows = 0
    maxRows = math.max(1, math.floor(tonumber(maxRows) or 1))
    while #remaining > 0 and rows < maxRows do
        ui.line(string.sub(remaining, 1, width), colour)
        remaining = string.sub(remaining, width + 1)
        rows = rows + 1
    end
    return rows
end

function ui.header(role, subtitle, afterTitle)
    ui.prepare()
    if #idConflicts > 0 then
        local width = select(1, term.getSize())
        term.setBackgroundColor(colors.red)
        term.setTextColor(colors.white)
        local warning = " ID CONFLICT: " .. table.concat(idConflicts, ", ") .. " "
        print(string.sub(warning .. string.rep(" ", width), 1, width))
        term.setBackgroundColor(colors.black)
    end
    if criticalAlarm then
        local width = select(1, term.getSize())
        term.setBackgroundColor(colors.red)
        term.setTextColor(colors.white)
        print(string.sub(" [ ALARM ] CRITICAL CONDITION ACTIVE " .. string.rep(" ", width), 1, width))
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
    if type(afterTitle) == "function" then afterTitle() end
    term.setTextColor(colors.gray)
    print(string.rep("-", math.min(select(1, term.getSize()), 40)))
    term.setTextColor(colors.white)
end

function ui.status(label, value, colour)
    local width = select(1, term.getSize())
    local prefix = tostring(label) .. ": "
    term.setTextColor(colors.lightGray)
    write(string.sub(prefix, 1, width))
    term.setTextColor(colour or colors.white)
    local x = select(1, term.getCursorPos())
    print(string.sub(tostring(value), 1, math.max(0, width - x + 1)))
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

    ["core/ui_contract.lua"] = [=[
local contract = {}

contract.name = "helios.ui"
contract.version = 1

local commands = {
    ["navigate"] = { authority = "local", confirmation = false },
    ["alarm.silence"] = { authority = "operator", confirmation = false },
    ["control.set_authority"] = { authority = "operator", confirmation = true },
    ["reactor.set_active"] = { authority = "manual", confirmation = false },
    ["reactor.adjust_rods"] = { authority = "manual", confirmation = false },
    ["turbine.set_active"] = { authority = "manual", confirmation = false },
    ["turbine.adjust_flow"] = { authority = "manual", confirmation = false },
}

local function copySafe(value, seen)
    local kind = type(value)
    if kind == "nil" or kind == "boolean" or kind == "number" or kind == "string" then
        return value
    end
    if kind ~= "table" then return nil end
    seen = seen or {}
    if seen[value] then return nil end
    seen[value] = true
    local result = {}
    for key, item in pairs(value) do
        local safeKey = copySafe(key, seen)
        local safeValue = copySafe(item, seen)
        if safeKey ~= nil and safeValue ~= nil then result[safeKey] = safeValue end
    end
    seen[value] = nil
    return result
end

function contract.describe()
    return {
        name = contract.name,
        version = contract.version,
        commands = copySafe(commands),
        guarantees = {
            telemetryOnly = true,
            noHardwareHandles = true,
            guardedCommandDispatch = true,
            textFallback = true,
        },
    }
end

function contract.attach(snapshot)
    local safe = copySafe(snapshot or {})
    safe.uiContract = contract.describe()
    return safe
end

function contract.validateCommand(envelope)
    if type(envelope) ~= "table" then return nil, "Command envelope must be a table" end
    local name = tostring(envelope.name or "")
    local descriptor = commands[name]
    if not descriptor then return nil, "Unsupported UI command: " .. name end
    if envelope.target ~= nil and type(envelope.target) ~= "string" then
        return nil, "Command target must be a string"
    end
    if envelope.arguments ~= nil and type(envelope.arguments) ~= "table" then
        return nil, "Command arguments must be a table"
    end
    return {
        name = name,
        target = envelope.target,
        arguments = copySafe(envelope.arguments or {}),
        confirmed = envelope.confirmed == true,
        descriptor = copySafe(descriptor),
    }
end

function contract.authorize(command, context)
    context = context or {}
    local authority = command.descriptor.authority
    if authority == "local" then return true end
    if context.remote == true then return false, "Remote UI is read-only" end
    if context.idConflict == true then return false, "Computer ID conflict blocks commands" end
    if authority == "manual" and context.controlMode ~= "manual" then
        return false, "Manual authority is required"
    end
    if command.descriptor.confirmation and command.confirmed ~= true then
        return false, "Operator confirmation is required"
    end
    return true
end

function contract.dispatch(envelope, context, handlers)
    local command, validationError = contract.validateCommand(envelope)
    if not command then return false, validationError end
    local authorized, authorizationError = contract.authorize(command, context)
    if not authorized then return false, authorizationError end
    local handler = type(handlers) == "table" and handlers[command.name] or nil
    if type(handler) ~= "function" then return false, "No guarded handler is registered" end
    return handler(command.target, command.arguments, command)
end

return contract
]=],

    ["draconic/guardian.lua"] = [=[
-- HELIOS Draconic Guardian v0.1
-- This first release is deliberately telemetry-only.  It validates the local
-- installation contract and never calls an actuator method on a reactor or
-- flow gate.

local guardian = {}

local function contains(value, fragment)
    return string.find(string.lower(tostring(value or "")), fragment, 1, true) ~= nil
end

local function hasType(name, fragment)
    for _, peripheralType in ipairs({ peripheral.getType(name) }) do
        if contains(peripheralType, fragment) then return true end
    end
    return false
end

local function sortNames(names)
    table.sort(names, function(a, b) return tostring(a) < tostring(b) end)
    return names
end

local function localNames()
    local result = {}
    for _, side in ipairs(rs.getSides()) do
        if peripheral.isPresent(side) then result[side] = true end
    end
    return result
end

local function namesText(names)
    return #names > 0 and table.concat(names, ", ") or "none"
end

function guardian.inspect()
    local localPresent = localNames()
    local localReactors, localGates, localModems, localMonitors = {}, {}, {}, {}
    for side in pairs(localPresent) do
        if hasType(side, "draconic_reactor") then localReactors[#localReactors + 1] = side end
        if hasType(side, "flow_gate") then localGates[#localGates + 1] = side end
        if hasType(side, "modem") then localModems[#localModems + 1] = side end
        if hasType(side, "monitor") then localMonitors[#localMonitors + 1] = side end
    end
    sortNames(localReactors)
    sortNames(localGates)
    sortNames(localModems)
    sortNames(localMonitors)

    local remoteGates, remoteMonitors = {}, {}
    for _, name in ipairs(peripheral.getNames()) do
        if not localPresent[name] then
            if hasType(name, "flow_gate") then remoteGates[#remoteGates + 1] = name end
            if hasType(name, "monitor") then remoteMonitors[#remoteMonitors + 1] = name end
        end
    end
    sortNames(remoteGates)
    sortNames(remoteMonitors)

    local reasons = {}
    if #localReactors ~= 1 then
        reasons[#reasons + 1] = "Require exactly one local Draconic reactor-side component"
    end
    if #localGates ~= 1 then
        reasons[#reasons + 1] = "Require exactly one local output flow gate"
    end
    if #localModems < 1 then
        reasons[#reasons + 1] = "Require a local wired modem/peripheral hub"
    end
    if #remoteGates ~= 1 then
        reasons[#reasons + 1] = "Require exactly one remote field-input flow gate"
    end

    local reactorSide = localReactors[1]
    if reactorSide then
        local methods = peripheral.getMethods(reactorSide) or {}
        local readable = false
        for _, method in ipairs(methods) do
            if method == "getReactorInfo" then readable = true end
        end
        if not readable then reasons[#reasons + 1] = "Local reactor component lacks getReactorInfo" end
    end

    return {
        ready = #reasons == 0,
        reasons = reasons,
        reactorSide = reactorSide,
        outputGateSide = localGates[1],
        modemSide = localModems[1],
        inputGateName = remoteGates[1],
        monitorName = remoteMonitors[1] or localMonitors[1],
        localReactors = localReactors,
        localGates = localGates,
        remoteGates = remoteGates,
    }
end

function guardian.telemetry(binding)
    if not binding or not binding.ready then return nil, "Guardian setup is incomplete" end
    local ok, info = pcall(peripheral.call, binding.reactorSide, "getReactorInfo")
    if not ok or type(info) ~= "table" then
        return nil, "getReactorInfo failed: " .. tostring(info)
    end
    return info
end

local function printBinding(binding)
    print("HELIOS // DRACONIC GUARDIAN v0.1")
    print("MODE: READ-ONLY VALIDATION")
    print("")
    print("Local reactor component: " .. tostring(binding.reactorSide or "MISSING"))
    print("Local output gate:       " .. tostring(binding.outputGateSide or "MISSING"))
    print("Local modem:             " .. tostring(binding.modemSide or "MISSING"))
    print("Remote field-input gate: " .. tostring(binding.inputGateName or "MISSING"))
    print("Monitor:                 " .. tostring(binding.monitorName or "optional / none"))
    print("")
    if binding.ready then
        print("SETUP VALID: no control commands have been sent.")
    else
        print("SETUP INVALID:")
        for _, reason in ipairs(binding.reasons) do print("- " .. reason) end
    end
end

function guardian.run(action)
    local binding = guardian.inspect()
    if action ~= "check" and action ~= "telemetry" then
        error("Usage: helios draconic [check|telemetry]", 0)
    end
    printBinding(binding)
    if action == "telemetry" and binding.ready then
        local info, reason = guardian.telemetry(binding)
        if not info then
            print("Telemetry error: " .. tostring(reason))
            return
        end
        print("")
        print("Live reactor telemetry:")
        for _, key in ipairs({ "status", "generationRate", "temperature", "fieldStrength",
            "maxFieldStrength", "fieldDrainRate", "energySaturation", "maxEnergySaturation",
            "fuelConversion", "maxFuelConversion" }) do
            if info[key] ~= nil then print(key .. ": " .. tostring(info[key])) end
        end
    end
end

return guardian
]=],

    ["draconic/profiler.lua"] = [=[
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
]=],

    ["draconic/profiler_engine.lua"] = [=[
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
]=],

    ["gui/control-room/manifest.lua"] = [=[
return {
    id = "control-room",
    name = "HELIOS Control Room",
    version = "1.0.0",
    apiVersion = 1,
    compatibleCoreVersions = { "1.6.0-alpha.4" },
    entry = "renderer.lua",
    minimumWidth = 50,
    minimumHeight = 31,
    readOnly = true,
}
]=],

    ["gui/control-room/renderer.lua"] = [=[
local renderer = {}

local function sum(list, field)
    local total = 0
    for _, item in ipairs(list or {}) do total = total + (tonumber(item[field]) or 0) end
    return total
end

local function instrument(gui, x, y, width, title, percent, value, colour, targetPercent)
    width = math.max(12, width)
    gui.text(x, y, "+" .. string.rep("-", width - 2) .. "+", colors.gray)
    gui.text(x, y + 1, "| " .. title, colors.lightGray, colors.black, width)
    gui.text(x + width - 1, y + 1, "|", colors.gray)
    local gaugeWidth = width - 4
    gui.progress(x + 2, y + 3, gaugeWidth, percent, colour, colors.gray)
    if targetPercent then
        local target = math.floor(math.max(0, math.min(100, targetPercent)) / 100 *
            (gaugeWidth - 1))
        gui.text(x + 2 + target, y + 2, "v", colors.yellow, colors.black)
    end
    local marker = math.floor(math.max(0, math.min(100, percent or 0)) / 100 * (gaugeWidth - 1))
    gui.text(x + 2 + marker, y + 3, "^", colors.white, colors.black)
    gui.text(x + 2, y + 4, value, colors.white, colors.black, width - 4)
    gui.text(x, y + 5, "+" .. string.rep("-", width - 2) .. "+", colors.gray)
end

local function nameOf(name, snapshot)
    return (snapshot.aliases and snapshot.aliases[name]) or name or "UNKNOWN"
end

local function displayedReactors(snapshot)
    local result = {}
    for _, reactor in ipairs(snapshot.reactors or {}) do result[#result + 1] = reactor end
    for _, reactor in ipairs(snapshot.facilityReactors or {}) do result[#result + 1] = reactor end
    return result
end

local function percent(value, maximum)
    value, maximum = tonumber(value), tonumber(maximum)
    if not value or not maximum or maximum <= 0 then return nil end
    return math.max(0, math.min(100, value / maximum * 100))
end

function renderer.render(snapshot, state, services)
    local gui, formatter = services.gui, services.powerFormat
    local width, height = term.getSize()
    state.page = state.page or "home"
    state.selected = state.selected or { reactors = 1, turbines = 1, power = 1 }
    gui.prepare()
    gui.text(1, 1, "HELIOS // CONTROL ROOM", colors.yellow)
    gui.text(math.max(1, width - 15), 1, "GUI v1 / " .. tostring(snapshot.version), colors.yellow)
    local alarm = snapshot.alarm
    local alarmLevel = alarm and tonumber(alarm.level) or 0
    local status = alarm and (alarmLevel >= 3 and "FAULT" or "WARNING") or "SYSTEM READY"
    gui.text(1, 2, " " .. status .. " ", colors.black,
        alarm and (alarmLevel >= 3 and colors.red or colors.orange) or colors.lime)
    local buttons, x = {}, 1
    buttons.home = gui.button(x, 4, "HOME", colors.white, state.page == "home" and colors.gray or colors.black)
    x = buttons.home.x2 + 2
    buttons.reactors = gui.button(x, 4, "REACTORS", colors.red, state.page == "reactors" and colors.gray or colors.black)
    x = buttons.reactors.x2 + 2
    buttons.turbines = gui.button(x, 4, "TURBINES", colors.cyan, state.page == "turbines" and colors.gray or colors.black)
    x = buttons.turbines.x2 + 2
    buttons.power = gui.button(x, 4, "POWER", colors.yellow, state.page == "power" and colors.gray or colors.black)
    buttons.advanced = gui.button(1, height, "ADVANCED", colors.white, colors.gray)
    if services.allowEmergency and alarm and alarm.facilityNodeId then
        buttons.scram = gui.button(math.max(12, width - 8), height,
            "SCRAM", colors.white, colors.red)
    end
    local allReactors = displayedReactors(snapshot)

    if state.page == "home" then
        local left = math.max(22, math.floor(width * 0.42))
        local rightX, rightWidth = left + 2, width - left - 1
        local stored, capacity = sum(snapshot.storages, "stored"), sum(snapshot.storages, "capacity")
        local reserve = capacity > 0 and stored / capacity * 100 or 0
        local steam = sum(snapshot.reactors, "steamProduction")
        local demand = sum(snapshot.turbines, "flowRate")
        local steamMaximum, maximumKnown = 0, true
        local reactorProfiles = snapshot.control and snapshot.control.reactorProfiles or {}
        for _, reactor in ipairs(snapshot.reactors or {}) do
            if reactor.mode == "steam" then
                local profile = reactorProfiles[reactor.name] or
                    (reactor.governor and reactor.governor.learnedProfile) or {}
                local maximum = tonumber(profile.learnedMaximumSteam)
                if maximum then steamMaximum = steamMaximum + maximum else maximumKnown = false end
            end
        end
        local generation = sum(allReactors, "energyProduction") + sum(snapshot.turbines, "energyProduction")
        local fill, draw = sum(snapshot.storages, "input"), sum(snapshot.storages, "output")
        local net = fill - draw
        instrument(gui, 1, 6, left, "POWER STORAGE", reserve,
            ("%.1f%%  %s"):format(reserve, formatter.power(stored, snapshot.power, false)),
            reserve < 20 and colors.orange or colors.lime)
        local steamScale = maximumKnown and steamMaximum > 0 and steamMaximum or math.max(1, steam)
        local steamPercent = math.min(100, steam / steamScale * 100)
        local steamRatio = demand > 0 and steam / demand or 0
        local steamColour = demand > 0 and steamRatio >= 0.95 and steamRatio <= 1.10 and
            colors.cyan or colors.orange
        instrument(gui, 1, 12, left, "STEAM PRODUCTION", steamPercent,
            maximumKnown and ("%.0f / %.0f mB/t"):format(steam, steamMaximum) or
                (("%.0f / LEARNING"):format(steam)), steamColour,
            maximumKnown and steamMaximum > 0 and math.min(100, demand / steamMaximum * 100) or nil)
        instrument(gui, 1, 18, left, "POWER PRODUCTION", math.min(100, generation / math.max(1, generation + draw) * 100),
            formatter.power(generation, snapshot.power, true), colors.lime)
        instrument(gui, 1, 24, left, "NET POWER FLOW", net >= 0 and math.min(100, 50 + net / math.max(1, fill + draw) * 50) or math.max(0, 50 + net / math.max(1, fill + draw) * 50),
            (net >= 0 and "+" or "") .. formatter.power(net, snapshot.power, true), net >= 0 and colors.lime or colors.orange)
        gui.text(rightX, 6, "+" .. string.rep("-", rightWidth - 2) .. "+", colors.gray)
        gui.text(rightX + 2, 7, "HELIOS ACTIVITY", colors.cyan)
        local row = 9
        local function line(text, colour)
            if row < height - 1 then gui.text(rightX + 2, row, text, colour or colors.white, colors.black, rightWidth - 4); row = row + 1 end
        end
        if alarm then line("! " .. tostring(alarm.message), alarmLevel >= 3 and colors.red or colors.orange) end
        for _, reactor in ipairs(snapshot.reactors or {}) do
            local plan = reactor.governor or {}
            line("R " .. nameOf(reactor.name, snapshot) .. ": " .. tostring(plan.state or "MONITORING"), colors.orange)
            local dispatch = plan.dispatchRequested == true and "DISPATCHED" or
                (reactor.mode == "power" and "STANDBY" or nil)
            line("  " .. (dispatch and (dispatch .. " - ") or "") ..
                tostring(plan.reason or (reactor.active and "ONLINE" or "OFFLINE")), colors.lightGray)
        end
        for _, reactor in ipairs(snapshot.facilityReactors or {}) do
            line("F " .. nameOf(reactor.name, snapshot) .. ": " ..
                (reactor.online and string.upper(tostring(reactor.state or "ONLINE")) or "LINK STALE"),
                reactor.online and colors.magenta or colors.orange)
            line("  DRACONIC GUARDIAN - " ..
                tostring(reactor.guardianMessage or reactor.mode or "MONITORING"), colors.lightGray)
        end
        for _, turbine in ipairs(snapshot.turbines or {}) do
            local plan = turbine.governor or {}
            line("T " .. nameOf(turbine.name, snapshot) .. ": " .. tostring(plan.state or "MONITORING"), colors.cyan)
            line("  " .. tostring(plan.dispatchMode or turbine.dispatchMode or "UNKNOWN") ..
                " - " .. tostring(plan.reason or (turbine.active and "ONLINE" or "OFFLINE")), colors.lightGray)
        end
        line(("Storage reserve %.1f%%"):format(reserve), reserve < 20 and colors.orange or colors.lime)
        gui.text(rightX, height - 1, "+" .. string.rep("-", rightWidth - 2) .. "+", colors.gray)
    else
        local list = state.page == "reactors" and allReactors or
            state.page == "turbines" and (snapshot.turbines or {}) or (snapshot.storages or {})
        local key = state.page == "power" and "power" or state.page
        if #list == 0 then gui.text(1, 7, "NO DEVICES REPORTED", colors.orange) else
            state.selected[key] = math.max(1, math.min(state.selected[key] or 1, #list))
            local item = list[state.selected[key]]
            gui.text(1, 7, ("%d/%d  %s"):format(state.selected[key], #list, nameOf(item.name, snapshot)), colors.cyan)
            local row = 9
            if item.facility then
                local fieldPercent = percent(item.fieldStrength, item.maxFieldStrength)
                local saturationPercent = percent(item.energySaturation, item.maxEnergySaturation)
                local fuelPercent = percent(item.fuelConversion, item.maxFuelConversion)
                local details = {
                    {"TYPE", "DRACONIC / REMOTE GUARDIAN", colors.magenta},
                    {"LINK", item.online and "ONLINE" or "STALE", item.online and colors.lime or colors.orange},
                    {"STATE", string.upper(tostring(item.state or "UNKNOWN")), colors.white},
                    {"GENERATION", formatter.power(item.generationRate, snapshot.power, true), colors.cyan},
                    {"CORE", item.temperature and ("%.2f C"):format(item.temperature) or "N/A", colors.orange},
                    {"FIELD", fieldPercent and ("%.1f%%"):format(fieldPercent) or "N/A", colors.white},
                    {"SATURATION", saturationPercent and ("%.1f%%"):format(saturationPercent) or "N/A", colors.white},
                    {"FUEL CONVERSION", fuelPercent and ("%.1f%%"):format(fuelPercent) or "N/A", colors.white},
                    {"FIELD GATE", formatter.power(item.fieldGate, snapshot.power, true), colors.lime},
                    {"EXPORT GATE", formatter.power(item.exportGate, snapshot.power, true), colors.lime},
                    {"GUARDIAN", tostring(item.mode or "UNKNOWN") .. " / " .. tostring(item.request or "UNKNOWN"), colors.orange},
                    {"VERSION", tostring(item.softwareVersion or "UNKNOWN"), colors.lightGray},
                }
                for _, detail in ipairs(details) do
                    if row < height - 3 then
                        gui.text(1, row, detail[1] .. ": " .. detail[2], detail[3], colors.black, width)
                        row = row + 1
                    end
                end
                if item.guardianMessage and row < height - 3 then
                    gui.text(1, row, tostring(item.guardianMessage), colors.lightGray, colors.black, width)
                end
            else
                for _, field in ipairs({"active", "state", "dispatchMode", "powerDispatchRequested", "rotorSpeed", "steamProduction", "energyProduction", "fuelPercent", "waste", "percent", "input", "output", "stored", "capacity"}) do
                    if item[field] ~= nil then gui.text(1, row, string.upper(field) .. ": " .. tostring(item[field]), colors.white); row = row + 1 end
                end
            end
            local plan = item.governor or {}
            if plan.state then gui.text(1, row + 1, "GOVERNOR: " .. tostring(plan.state), colors.orange) end
            if plan.reason then gui.text(1, row + 2, tostring(plan.reason), colors.lightGray, colors.black, width) end
            buttons.previous = gui.button(1, height - 2, "< PREVIOUS", colors.cyan, colors.black)
            buttons.next = gui.button(16, height - 2, "NEXT >", colors.cyan, colors.black)
        end
    end
    return buttons
end

function renderer.handle(state, buttons, event, a, b, c, services)
    local x, y = services.eventPoint(event, a, b, c)
    if services.hit(buttons.scram, x, y) then return "scram" end
    if event == "key" and a == keys.a or services.hit(buttons.advanced, x, y) then return "advanced" end
    if event == "key" and a == keys.v then state.page = "reactors"
    elseif event == "key" and a == keys.g then state.page = "turbines"
    elseif event == "key" and a == keys.e then state.page = "power"
    elseif services.hit(buttons.home, x, y) then state.page = "home"
    elseif services.hit(buttons.reactors, x, y) then state.page = "reactors"
    elseif services.hit(buttons.turbines, x, y) then state.page = "turbines"
    elseif services.hit(buttons.power, x, y) then state.page = "power"
    elseif services.hit(buttons.previous, x, y) then
        local key = state.page == "power" and "power" or state.page
        state.selected[key] = math.max(1, (state.selected[key] or 1) - 1)
    elseif services.hit(buttons.next, x, y) then
        local key = state.page == "power" and "power" or state.page
        state.selected[key] = (state.selected[key] or 1) + 1
    end
end

return renderer
]=],

    ["helios.lua"] = [=[
-- @section PROGRAM ENTRYPOINT
local args = { ... }
local config = dofile("/helios/core/config.lua").load()

if config.role == "guardian" then
    dofile("/helios/draconic/controller.lua")
    return
end

if config.role == "profiler" then
    dofile("/helios/draconic/profiler.lua")
    return
end

if args[1] == "probe" then
    dofile("/helios/tools/discovery_probe.lua")
    return
end

if args[1] == "draconic" then
    local guardian = dofile("/helios/draconic/guardian.lua")
    guardian.run(args[2] or "check")
    return
end

if args[1] == "gui" then
    local loader = dofile("/helios/core/gui_loader.lua")
    local action = args[2] or "status"
    if action == "list" or action == "rescan" then
        for _, module in ipairs(loader.scan(config.version)) do
            local selected = module.id == config.ui.renderer and " *" or ""
            print(("%s - %s%s"):format(module.id, module.name, selected))
        end
    elseif action == "set" then
        local id = tostring(args[3] or "")
        local module, reason = loader.resolve(id, config.version)
        if not module then error(reason, 0) end
        config.ui.renderer = id
        local ok, saveReason = dofile("/helios/core/config.lua").save(config)
        if not ok then error(saveReason, 0) end
        print("Graphical interface set to " .. module.name .. ". Restart HELIOS to apply it.")
    elseif action == "install" then
        local module, reason = loader.install(args[3], config.version)
        if not module then error(reason, 0) end
        print("Installed GUI module " .. module.name .. ".")
        print("Select it with: helios gui set " .. module.id)
    elseif action == "status" then
        local module, reason = loader.resolve(config.ui.renderer, config.version)
        print("Selected GUI: " .. tostring(module and module.name or config.ui.renderer))
        if reason then print("Status: ERROR - " .. reason) end
    else
        error("Usage: helios gui [list|rescan|status|set <id>|install <url>]", 0)
    end
    return
end

if args[1] == "modules" and args[2] == "update" then
    if config.role ~= "mainframe" then
        error("Only a HELIOS mainframe installs peripheral modules.", 0)
    end
    print("Updating HELIOS Module Pack...")
    local ok, result = dofile("/helios/core/module_manager.lua").update(config.version)
    if not ok then error(result, 0) end
    print("Module Pack " .. tostring(result) .. " installed. Restart HELIOS to load it.")
    return
end

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
    print("HELIOS Core: " .. tostring(config.version))
    print("Role: " .. tostring(config.role))
    if config.role == "mainframe" then
        local moduleLoader = dofile("/helios/core/module_loader.lua")
        local versions, reason = moduleLoader.versions(config.version)
        if versions then
            print("Module Pack: " .. tostring(versions.pack))
            for _, module in ipairs(versions.modules) do
                print(("  %s: %s"):format(module.name or module.id, module.version or "unknown"))
            end
        else
            print("Module Pack: ERROR - " .. tostring(reason))
        end
    end
    if config.role == "terminal" then
        print("Display: " .. tostring(config.display))
        print("Mainframe ID: " .. tostring(config.mainframeId or "not paired"))
    end
    print("Computer ID: " .. tostring(config.computerId))
    return
end

if args[1] == "facilities" then
    if config.role ~= "mainframe" then
        error("Only the HELIOS mainframe maintains the facility registry.", 0)
    end
    local path = "/helios/data/facilities.lua"
    local facilities = fs.exists(path) and dofile(path) or {}
    local count = 0
    for nodeId, facility in pairs(facilities) do
        count = count + 1
        print(("%s  %s  %s %s  computer %s"):format(
            tostring(nodeId), tostring(facility.facilityType or "unknown"),
            tostring(facility.software or "unknown"),
            tostring(facility.softwareVersion or "unknown"),
            tostring(facility.id or "unknown")))
    end
    if count == 0 then print("No facilities have registered yet.") end
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
    local adapter, reason = dofile("/helios/core/module_loader.lua").load("reactor_adapter", config.version)
    if not adapter then error(reason, 0) end
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
    local adapter, reason = dofile("/helios/core/module_loader.lua").load("turbine_adapter", config.version)
    if not adapter then error(reason, 0) end
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
    local adapter, reason = dofile("/helios/core/module_loader.lua").load("storage_adapter", config.version)
    if not adapter then error(reason, 0) end
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
-- @section PERIPHERAL DISCOVERY AND REGISTRY
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
    -- A Draconic Evolution reactor must never enter the ordinary reactor
    -- adapter path.  Its controller and injector can both expose the same
    -- peripheral type through a modem, so the mainframe cannot safely infer
    -- which side is safe to operate.  Only the directly-wired Guardian may
    -- validate it; the mainframe receives telemetry from that Guardian later.
    for _, peripheralType in ipairs(types) do
        if contains(peripheralType, "draconic_reactor") then return "draconic" end
    end
    for _, peripheralType in ipairs(types) do
        if contains(peripheralType, "turbine") then return "turbine" end
    end
    if contains(name, "turbine") then return "turbine" end
    for _, peripheralType in ipairs(types) do
        if contains(peripheralType, "reactor") then return "reactor" end
    end
    if contains(name, "reactor") then return "reactor" end
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
        (available.getEnergy and available.getMaxEnergy) or
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
    local counts = { reactor = 0, turbine = 0, battery = 0, draconic = 0,
        monitor = 0, modem = 0, unknown = 0 }
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

-- @section STARTUP AND RUNTIME STATE
function mainframe.run(config)
    local display = dofile("/helios/core/display.lua")
    display.start(config)
    local ui = dofile("/helios/core/ui.lua")
    ui.setVersion(config.version)
    local gui = dofile("/helios/core/gui.lua")
    local guiLoader = dofile("/helios/core/gui_loader.lua")
    local uiContract = dofile("/helios/core/ui_contract.lua")
    local configStore = dofile("/helios/core/config.lua")
    local moduleLoader = dofile("/helios/core/module_loader.lua")
    local registry = dofile("/helios/mainframe/device_registry.lua")
    local reactorAdapter, reactorModuleError = moduleLoader.load("reactor_adapter", config.version)
    if not reactorAdapter then error(reactorModuleError, 0) end
    local reactorGovernor = dofile("/helios/mainframe/reactor_governor.lua")
    local manualControl = dofile("/helios/mainframe/manual_control.lua")
    local turbineAdapter, turbineModuleError = moduleLoader.load("turbine_adapter", config.version)
    if not turbineAdapter then error(turbineModuleError, 0) end
    local turbineGovernor = dofile("/helios/mainframe/turbine_governor.lua")
    local storageAdapter, storageModuleError = moduleLoader.load("storage_adapter", config.version)
    if not storageAdapter then error(storageModuleError, 0) end
    local powerFormat = dofile("/helios/core/power_format.lua")
    local network = dofile("/helios/core/network.lua")
    local facilityProtocol = dofile("/helios/core/facility_protocol.lua")
    local authority = dofile("/helios/core/mainframe_authority.lua")
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
    local alarmButton
    local scramButton
    local modemCount = network.openAll()
    local terminals = network.loadPeers()
    local missingDevices = {}
    local sessionId = network.sessionId("mainframe")
    local facilityIdentity = assert(facilityProtocol.identity({
        nodeId = "mainframe:" .. tostring(os.getComputerID()),
        sessionId = sessionId,
        role = "mainframe",
        software = "helios",
        softwareVersion = config.version,
    }))
    local facilitySequence = 0
    local facilityTracker = facilityProtocol.newSequenceTracker()
    local facilitySiteId = tostring((config.network or {}).siteId or "default")
    local overseerCollectorLeaseUntil = 0
    local facilityFile = "/helios/data/facilities.lua"
    local facilities = {}
    if fs.exists(facilityFile) then
        local loadedOk, loaded = pcall(dofile, facilityFile)
        if loadedOk and type(loaded) == "table" then facilities = loaded end
    end
    local authorityState = authority.new(config.control.mainframeAuthority,
        os.getComputerID())
    local identityClaims = {}
    local idConflicts = {}
    local dashboardButtons = {}
    local governorMemory = turbineGovernor.new()
    local reactorGovernorMemory = reactorGovernor.new()
    local plantRechargeActive
    local manualNotice
    local manualSafetyState = manualControl.newSafetyState()
    local minimumPowerReserve
    local returnToAutomatic

    local function planGeneration(powerReserve, powerDemand)
        local low = tonumber(config.control.storageLow) or 25
        local high = tonumber(config.control.storageHigh) or 85
        if powerReserve == nil then
            plantRechargeActive = false
        elseif plantRechargeActive == nil then
            plantRechargeActive = powerReserve < high
        elseif powerReserve >= high then
            plantRechargeActive = false
        elseif powerReserve < low then
            plantRechargeActive = true
        end

        local sources = {}
        for _, turbine in ipairs(turbines) do
            turbine.dispatchRequested = false
            turbine.dispatchMode = "COASTING"
            turbine.requestedSteam = 0
            local profile = (config.control.turbineProfiles or {})[tostring(turbine.name)]
            if type(profile) == "table" and profile.calibrated == true and
               turbine.error == nil then
                local observed = tonumber(turbine.energyProduction) or 0
                if observed > (tonumber(profile.maximumPower) or 0) then
                    profile.maximumPower = observed
                    governorMemory.profileDirty = true
                end
                local assisted = profile.assistedIdle == true
                local target = tonumber(profile.targetRpm) or config.control.highBandRpm
                local warm = (tonumber(turbine.rotorSpeed) or 0) >=
                    target * (tonumber(config.control.assistedIdleRpmRatio) or 0.75)
                sources[#sources + 1] = {
                    kind = "turbine", unit = turbine, profile = profile,
                    capacity = tonumber(profile.maximumPower) or 0,
                    -- Direct power reactors are the primary recharge plant.  A
                    -- turbine remains the fast-response path, but it must not
                    -- silently displace a calibrated power source while the
                    -- storage bank is below its recharge target.
                    priority = assisted and 3 or warm and 4 or 5,
                }
            end
        end
        for _, reactor in ipairs(reactors) do
            reactor.powerDispatchRequested = false
            reactor.powerDispatchTarget = 0
            local profile = (config.control.powerReactorProfiles or {})[tostring(reactor.name)]
            if reactor.mode == "power" and type(profile) == "table" and
               reactor.error == nil then
                sources[#sources + 1] = {
                    kind = "reactor", unit = reactor, profile = profile,
                    capacity = tonumber(profile.maximumPower) or 0,
                    priority = reactor.active == true and 1 or 2,
                }
            end
        end
        table.sort(sources, function(a, b)
            if a.priority ~= b.priority then return a.priority < b.priority end
            -- An unlearned source has no usable capacity estimate.  It is a
            -- fallback, never evidence that the requested generation has
            -- already been assigned.
            local aKnown = (tonumber(a.capacity) or 0) > 0
            local bKnown = (tonumber(b.capacity) or 0) > 0
            if aKnown ~= bKnown then return aKnown end
            if a.capacity ~= b.capacity then return a.capacity > b.capacity end
            return tostring(a.unit.name) < tostring(b.unit.name)
        end)

        local totalCapacity = 0
        for _, source in ipairs(sources) do
            totalCapacity = totalCapacity + math.max(0, tonumber(source.capacity) or 0)
        end
        local rechargeTarget = 0
        if plantRechargeActive and powerReserve ~= nil and totalCapacity > 0 then
            -- A near-empty grid needs decisive recharge, while a grid closer to
            -- the high threshold is replenished with progressively less capacity.
            local fraction = math.max(0.10, math.min(1,
                (high - powerReserve) / math.max(1, high - low)))
            rechargeTarget = totalCapacity * fraction
        end
        local remaining = plantRechargeActive and math.max(1,
            tonumber(powerDemand) or 0, rechargeTarget) or 0
        local unknownFallbackAssigned = false
        for _, source in ipairs(sources) do
            if remaining > 0 then
                local knownCapacity = (tonumber(source.capacity) or 0) > 0
                -- Select at most one unlearned fallback.  Crucially, do not
                -- consume the demand with it: later calibrated sources still
                -- need to be dispatched to satisfy the recharge target.
                local select = knownCapacity or not unknownFallbackAssigned
                local assigned = knownCapacity and
                    math.min(remaining, source.capacity) or remaining
                if not knownCapacity then unknownFallbackAssigned = true end
                if select then
                if source.kind == "turbine" then
                    source.unit.dispatchRequested = true
                    source.unit.dispatchMode = "GENERATING"
                    source.unit.requestedSteam = tonumber(source.profile.flowLimit) or 0
                else
                    source.unit.powerDispatchRequested = true
                    source.unit.powerDispatchTarget = assigned
                end
                end
                if knownCapacity then
                    remaining = math.max(0, remaining - source.capacity)
                end
            end
        end

        for _, turbine in ipairs(turbines) do
            local profile = (config.control.turbineProfiles or {})[tostring(turbine.name)]
            if turbine.dispatchRequested ~= true and type(profile) == "table" and
               profile.assistedIdle == true then
                local target = tonumber(profile.targetRpm) or config.control.highBandRpm
                local floor = target * (tonumber(config.control.assistedIdleRpmRatio) or 0.75)
                turbine.dispatchMode = "ASSISTED IDLE"
                if (tonumber(turbine.rotorSpeed) or 0) < floor then
                    turbine.requestedSteam = math.min(
                        tonumber(profile.flowLimit) or math.huge,
                        tonumber(config.control.assistedIdleFlow) or 250)
                end
            end
        end
        return plantRechargeActive == true
    end

    local timeoutChoices = { 300, 900, 1800, 3600 }

    local function saveAuthority()
        config.control.mainframeAuthority = authorityState.mode
        configStore.save(config)
    end

    local function advertiseMainframe()
        network.broadcast({
            helios = true,
            kind = "mainframe_presence",
            sourceId = os.getComputerID(),
            sessionId = sessionId,
            authority = authorityState.mode,
            version = config.version,
            sentAt = network.now(),
        })
    end

    local function isFacilityCollector()
        return authority.canControl(authorityState) and
            network.now() >= overseerCollectorLeaseUntil
    end

    local function advertiseFacilityCollector()
        if not isFacilityCollector() then return false end
        facilitySequence = facilitySequence + 1
        local message = facilityProtocol.make("collector_presence", facilityIdentity,
            facilitySequence, {
                siteId = facilitySiteId,
                collectorRole = "mainframe",
                collectorPriority = 50,
                leaseSeconds = 5,
            }, network.now())
        if not message then return false end
        return network.broadcastOn(facilityProtocol.rednetProtocol, message)
    end

    local function selectAuthority(mode)
        authority.select(authorityState, mode)
        saveAuthority()
        advertiseMainframe()
    end

    -- @section DISCOVERY AND NETWORK IDENTITY
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
        if config.control.mode == "manual" then return "MANUAL - GUARDED" end
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

    -- @section ALARMS
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
        local function add(level, key, message, metadata)
            activeKeys[key] = true
            conditionSamples[key] = (conditionSamples[key] or 0) + 1
            if conditionSamples[key] >= config.alarms.confirmSamples then
                candidates[#candidates + 1] = {
                    level = level, key = key, message = message,
                    facilityNodeId = metadata and metadata.facilityNodeId or nil,
                }
            end
        end
        local function addConfirmed(level, key, message, metadata)
            activeKeys[key] = true
            conditionSamples[key] = config.alarms.confirmSamples
            candidates[#candidates + 1] = {
                level = level, key = key, message = message,
                facilityNodeId = metadata and metadata.facilityNodeId or nil,
            }
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
            elseif reactor.governor and reactor.governor.state == "CALIBRATION FAILED" then
                addConfirmed(2, reactor.name .. ":calibration",
                    alarmName(reactor.name) .. " CALIBRATION FAILED: " ..
                    tostring(reactor.governor.reason or "invalid operating result"))
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
        local facilityNow = network.now()
        for nodeId, facility in pairs(facilities) do
            local telemetry = facility.telemetry
            local age = facilityNow - (tonumber(facility.lastSeen) or 0)
            if type(telemetry) == "table" and age <= 7 and
               tonumber(telemetry.alarmLevel) then
                local level = math.max(1, math.min(3, tonumber(telemetry.alarmLevel)))
                addConfirmed(level, nodeId .. ":" ..
                    tostring(telemetry.alarmCode or "facility-alarm"),
                    tostring(telemetry.alarmMessage or
                        (alarmName(nodeId) .. " FACILITY ALARM")),
                    { facilityNodeId = nodeId })
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
            ui.setCriticalAlarm(false)
            if previous then playSound("minecraft:block.note_block.pling", 1.5) end
            silencedAlarm = nil
            return
        end

        ui.setCriticalAlarm(currentAlarm.level >= 3)

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

    -- @section TELEMETRY AND GOVERNORS
    local function pollReactors()
        authority.expire(authorityState, network.now(), 5)
        advertiseMainframe()
        advertiseFacilityCollector()
        reactors = reactorAdapter.readAll(devices)
        turbines = turbineAdapter.readAll(devices)
        storages = storageAdapter.readAll(devices, config.power)
        if config.control.mode == "manual" then
            local failover, reserve = manualControl.shouldFailover(manualSafetyState,
                storages,
                config.control.manualSafetyReserve)
            if failover then
                returnToAutomatic(("Manual cancelled: reserve %.1f%% below %.1f%%"):
                    format(reserve, config.control.manualSafetyReserve), true)
            end
        end
        local manualAuthority = config.control.mode == "manual"
        local authorityPaused = not authority.canControl(authorityState)
        local now = os.epoch("utc") / 1000
        local steamPrimeRequested = turbineGovernor.needsSteamPrime(
            governorMemory, turbines)
        local powerDemand = 0
        local powerStored, powerCapacity = 0, 0
        for _, storage in ipairs(storages) do
            powerDemand = powerDemand + math.max(0, tonumber(storage.output) or 0)
            if storage.telemetryOk ~= false and tonumber(storage.stored) and
               tonumber(storage.capacity) and tonumber(storage.capacity) > 0 then
                powerStored = powerStored + tonumber(storage.stored)
                powerCapacity = powerCapacity + tonumber(storage.capacity)
            end
        end
        local combinedPowerReserve = powerCapacity > 0 and
            powerStored / powerCapacity * 100 or nil
        local generationNeeded = planGeneration(combinedPowerReserve, powerDemand)
        local _, steamDemand = reactorGovernor.evaluateAll(reactorGovernorMemory,
            reactors, turbines, config.control, {
                maintenance = maintenance or manualAuthority or authorityPaused,
                mainframeId = os.getComputerID(),
                idConflicts = idConflicts,
                now = now,
                steamPrimeRequested = steamPrimeRequested,
                powerReserve = combinedPowerReserve,
                powerDemand = powerDemand,
                plantDispatch = true,
                generationNeeded = generationNeeded,
            })
        for _, reactor in ipairs(reactors) do
            if reactor.governor and reactor.governor.calibrationCompleted == true then
                turbineGovernor.requestSteamPrime(governorMemory)
            end
        end
        if reactorGovernor.consumeProfileChanges(reactorGovernorMemory) then
            configStore.save(config)
        end
        reactorGovernor.applyAll(reactorGovernorMemory, reactors, config.control, {
            maintenance = maintenance or manualAuthority or authorityPaused,
            now = now,
        }, {
            setActive = reactorAdapter.setActive,
            setControlRodExposure = reactorAdapter.setControlRodExposure,
        })

        local steamSource = reactorGovernor.steamSourceStatus(reactors,
            steamDemand, config.control)
        turbineGovernor.evaluateAll(governorMemory, turbines, config.control, {
            maintenance = maintenance or manualAuthority or authorityPaused,
            mainframeId = os.getComputerID(),
            idConflicts = idConflicts,
            now = now,
            steamSourceManaged = steamSource.managed,
            steamSourceReady = steamSource.ready,
            steamSourceReason = steamSource.reason,
            steamSourceBufferPercent = steamSource.bufferPercent,
            generationNeeded = generationNeeded,
        })
        if turbineGovernor.consumeProfileChanges(governorMemory) then
            configStore.save(config)
        end
        turbineGovernor.applyAll(governorMemory, turbines, config.control, {
                maintenance = maintenance or manualAuthority or authorityPaused,
                now = now,
        }, {
            setActive = turbineAdapter.setActive,
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

    -- @section REMOTE TELEMETRY
    local function facilityReactorViews()
        local result = {}
        local now = network.now()
        for nodeId, facility in pairs(facilities) do
            if facility.facilityType == "draconic_reactor" then
                local telemetry = facility.telemetry or {}
                local age = math.max(0, now - (tonumber(facility.lastSeen) or 0))
                local state = tostring(telemetry.state or "unknown")
                result[#result + 1] = {
                    name = nodeId,
                    facility = true,
                    remote = true,
                    facilityType = facility.facilityType,
                    softwareVersion = facility.softwareVersion,
                    computerId = facility.id,
                    online = age <= 7,
                    telemetryAge = age,
                    active = state == "running" or state == "online",
                    state = state,
                    mode = telemetry.mode,
                    request = telemetry.request,
                    generationRate = telemetry.generationRate,
                    energyProduction = telemetry.generationRate,
                    temperature = telemetry.temperature,
                    fieldStrength = telemetry.fieldStrength,
                    maxFieldStrength = telemetry.maxFieldStrength,
                    energySaturation = telemetry.energySaturation,
                    maxEnergySaturation = telemetry.maxEnergySaturation,
                    fuelConversion = telemetry.fuelConversion,
                    maxFuelConversion = telemetry.maxFuelConversion,
                    fieldGate = telemetry.fieldGate,
                    exportGate = telemetry.exportGate,
                    guardianMessage = telemetry.guardianMessage,
                    alarmLevel = telemetry.alarmLevel,
                    alarmCode = telemetry.alarmCode,
                    alarmMessage = telemetry.alarmMessage,
                    localAuthority = telemetry.localAuthority,
                    commissioned = telemetry.commissioned,
                    ratedOutput = telemetry.ratedOutput,
                }
            end
        end
        table.sort(result, function(a, b) return tostring(a.name) < tostring(b.name) end)
        return result
    end

    local function snapshotFor(assignment)
        local includeAll = assignment == "all"
        return uiContract.attach({
            helios = true,
            kind = "snapshot",
            version = config.version,
            sentAt = network.now(),
            assignment = assignment,
            reactors = (includeAll or assignment == "reactor") and reactors or {},
            facilityReactors = (includeAll or assignment == "reactor") and
                facilityReactorViews() or {},
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
        })
    end

    local function sendSnapshot(id, assignment)
        network.send(id, snapshotFor(assignment or "all"))
    end

    local function broadcastSnapshots()
        for _, remote in pairs(terminals) do
            sendSnapshot(remote.id, remote.display)
        end
    end

    local function saveFacilities()
        if not fs.exists("/helios/data") then fs.makeDir("/helios/data") end
        local handle = fs.open(facilityFile, "w")
        if not handle then return false end
        local registrations = {}
        for nodeId, facility in pairs(facilities) do
            registrations[nodeId] = {
                id = facility.id,
                nodeId = facility.nodeId,
                role = facility.role,
                software = facility.software,
                softwareVersion = facility.softwareVersion,
                facilityType = facility.facilityType,
                capabilities = facility.capabilities,
                uiProfile = facility.uiProfile,
                lastSeen = facility.lastSeen,
            }
        end
        handle.write("return " .. textutils.serialize(registrations))
        handle.close()
        return true
    end

    local function sendFacility(kind, target, payload)
        facilitySequence = facilitySequence + 1
        local outgoing = facilityProtocol.make(kind, facilityIdentity,
            facilitySequence, payload, network.now())
        if outgoing then
            return network.sendOn(facilityProtocol.rednetProtocol, target, outgoing)
        end
        return false
    end

    local function scramFacility(nodeId)
        local facility = facilities[nodeId]
        if not facility or not facility.id then return false end
        return sendFacility("emergency_command", facility.id, {
            siteId = facilitySiteId,
            targetNodeId = nodeId,
            action = "scram",
            reason = "operator requested emergency shutdown from HELIOS",
        })
    end

    local function handleFacility(sender, message)
        local accepted, clean = facilityProtocol.acceptSequence(facilityTracker, message)
        if not accepted then return false end
        if clean.payload.siteId ~= facilitySiteId then return false end
        if clean.kind == "collector_presence" and clean.source.role == "overseer" then
            overseerCollectorLeaseUntil = network.now() + math.max(2,
                math.min(30, tonumber(clean.payload.leaseSeconds) or 5))
            return true
        end
        if not isFacilityCollector() then return false end
        if clean.source.role ~= "guardian" and clean.source.role ~= "facility" then
            return false
        end
        local nodeId = clean.source.nodeId
        local previous = facilities[nodeId] or {}
        facilities[nodeId] = {
            id = sender,
            nodeId = nodeId,
            role = clean.source.role,
            software = clean.source.software,
            softwareVersion = clean.source.softwareVersion,
            facilityType = clean.payload.facilityType or previous.facilityType,
            capabilities = clean.payload.capabilities or previous.capabilities,
            uiProfile = clean.payload.uiProfile or previous.uiProfile,
            telemetry = clean.kind == "telemetry" and clean.payload or previous.telemetry,
            lastSeen = network.now(),
        }
        -- Persist registration metadata, not the one-second telemetry stream.
        -- Live telemetry stays in memory to avoid needless disk churn.
        if clean.kind == "hello" then saveFacilities() end
        local acknowledgement = facilityProtocol.acknowledge(clean, facilityIdentity,
            facilitySequence + 1, "accepted", nil, network.now())
        if acknowledgement then
            facilitySequence = facilitySequence + 1
            network.sendOn(facilityProtocol.rednetProtocol, sender, acknowledgement)
        end
        if clean.kind == "hello" then
            sendFacility("welcome", sender, {
                siteId = facilitySiteId,
                acceptedContract = facilityProtocol.name,
                acceptedVersion = facilityProtocol.version,
                collectorRole = "mainframe",
                collectorPriority = 50,
                leaseSeconds = 5,
                telemetryOnly = true,
                remoteCommands = false,
            })
        end
        return true
    end

    local function handleNetwork(sender, message, protocol)
        if protocol == facilityProtocol.rednetProtocol then
            return handleFacility(sender, message)
        end
        if protocol ~= network.protocol or not network.valid(message) then return false end
        if message.kind == "mainframe_presence" then
            local changed = authority.observe(authorityState, sender, message, network.now())
            if changed then
                saveAuthority()
                advertiseMainframe()
            end
            return true
        end
        if message.kind ~= "hello" then return false end
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

    minimumPowerReserve = function()
        return manualControl.minimumReserve(storages)
    end

    returnToAutomatic = function(reason, recalibrate)
        config.control.mode = "automatic"
        manualSafetyState = manualControl.newSafetyState()
        manualNotice = reason
        if recalibrate then
            for _, turbine in ipairs(turbines) do
                turbineGovernor.resetCalibration(governorMemory, config.control,
                    turbine.name)
            end
            for _, reactor in ipairs(reactors) do
                if reactor.mode == "steam" then
                    local prepared, prepareReason = reactorAdapter.prepareRecalibration(reactor)
                    if prepared then
                        reactorGovernor.beginRecalibration(reactorGovernorMemory,
                            config.control, reactor.name)
                    else
                        manualNotice = tostring(reason) .. "; " ..
                            tostring(prepareReason or "reactor reset failed")
                    end
                end
            end
            configStore.save(config)
        end
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
        if config.control.mode == "manual" then
            local reserve = minimumPowerReserve()
            return reserve and ("MANUAL / LOWEST RESERVE %.1f%%"):format(reserve) or
                "MANUAL / RESERVE UNOBSERVED", colors.orange
        end
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
            if plan.actuatorState == "FAULT" or plan.state == "CALIBRATION FAILED" then
                return "CONTROL FAULT / ATTENTION REQUIRED", colors.red
            elseif plan.state == "QUEUED" or plan.state == "CALIBRATING" or
                   plan.state == "CALIBRATION COMPLETE" then
                return ("AUTOMATIC / COMMISSIONING %d OF %d"):format(
                    plan.commissioningIndex or 1, plan.commissioningTotal or 1), colors.orange
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

    -- @section MAIN DASHBOARD
    local function render()
        ui.setIdConflicts(idConflicts)
        dashboardButtons = {}
        ui.header("HELIOS", "Central power management", function()
            dashboardButtons.reactors = ui.inlineButton("REACTORS", colors.red)
            write(" ")
            dashboardButtons.turbines = ui.inlineButton("TURBINES", colors.blue)
            write(" ")
            dashboardButtons.storage = ui.inlineButton("POWER", colors.yellow)
            print("")
        end)
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
            ui.line("Registry may be outdated", colors.orange)
        elseif maintenance then
            ui.line(("Auto return in %d:%02d"):format(
                math.floor(remainingMaintenance() / 60), remainingMaintenance() % 60))
        end

        local counts = registry.countByCategory(devices)
        print(("R:%d T:%d B:%d M:%d"):format(
            counts.reactor, counts.turbine, counts.battery, counts.monitor
        ))

        local width, height = term.getSize()
        if currentAlarm then
            ui.block("!! " .. currentAlarm.message, alarmColour(), 3)
            local _, row = term.getCursorPos()
            alarmButton = ui.inlineButton("ALARM", alarmColour())
            write(" ")
            silenceButton = ui.inlineButton("SILENCE", colors.gray)
            if currentAlarm.facilityNodeId then
                write(" ")
                scramButton = ui.inlineButton("SCRAM", colors.red)
            else
                scramButton = nil
            end
            print("")
        else
            alarmButton = nil
            silenceButton = nil
            scramButton = nil
            ui.status("Alarms", config.alarms.enabled and "CLEAR" or "DISABLED",
                config.alarms.enabled and colors.lime or colors.gray)
        end

        -- Keep the controls on fixed bottom rows. Alarm and device text may
        -- consume only the space above this footer, preserving touch hitboxes.
        local footerRow = math.max(1, height - 1)
        local contentRow = select(2, term.getCursorPos())
        local availableRows = math.max(0, footerRow - contentRow)
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
        term.setCursorPos(1, footerRow)
        dashboardButtons.control = ui.inlineButton("CONTROL", colors.lime)
        write(" ")
        dashboardButtons.settings = ui.inlineButton("SETTINGS", colors.cyan)
        write(" ")
        dashboardButtons.graphical = ui.inlineButton("GUI", colors.lightGray)
        print("")
        term.setTextColor(colors.gray)
        term.setCursorPos(1, height)
        write(string.sub("Keyboard: B GUI | V/G/E/C/A/R/S | Q exit", 1, width))
        term.setTextColor(colors.white)
    end

    -- @section CONTROL VIEW
    local function manualReactorView(reactorName)
        local page, step, notice = 1, 1
        local buttons = {}
        while config.control.mode == "manual" do
            local reactor
            for _, candidate in ipairs(reactors) do
                if candidate.name == reactorName then reactor = candidate break end
            end
            if not reactor then return end
            local count = math.floor(tonumber(reactor.controlRods) or 0)
            local perPage = 6
            local pages = math.max(1, math.ceil(count / perPage))
            page = math.max(1, math.min(page, pages))
            ui.header("MANUAL REACTOR", deviceName(reactor.name))
            ui.status("Authority", manualSafetyState.armed and
                "MANUAL - GUARDED" or "MANUAL - GUARD ARMING", colors.orange)
            ui.status("Reactor", reactor.active == true and "ACTIVE" or "OFFLINE",
                reactor.active == true and colors.lime or colors.orange)
            ui.status("Steam / hot buffer", ("%s / %s"):format(
                reactor.steamProduction and
                    ("%.0f mB/t"):format(reactor.steamProduction) or "N/A",
                reactor.hotFluidPercent and
                    ("%.1f%%"):format(reactor.hotFluidPercent) or "N/A"), colors.cyan)
            ui.status("Fuel / casing temp", ("%s / %s"):format(
                reactor.fuelTemperature and
                    ("%.0f C"):format(reactor.fuelTemperature) or "N/A",
                reactor.casingTemperature and
                    ("%.0f C"):format(reactor.casingTemperature) or "N/A"))
            ui.status("Rod page / step", ("%d/%d / %d%%"):format(page, pages, step), colors.cyan)
            if notice then ui.line(notice, colors.orange) end
            buttons.rods = {}
            local first = (page - 1) * perPage
            local last = math.min(count - 1, first + perPage - 1)
            for index = first, last do
                local level = tonumber(reactor.controlRodLevels and
                    reactor.controlRodLevels[index])
                write(("Rod %03d %3s%% "):format(index + 1,
                    level and tostring(math.floor(level + 0.5)) or "N/A"))
                local decrease = ui.inlineButton("-", colors.orange)
                write(" ")
                local increase = ui.inlineButton("+", colors.lime)
                print("")
                buttons.rods[#buttons.rods + 1] = {
                    index = index, level = level, decrease = decrease,
                    increase = increase,
                }
            end
            buttons.previous = ui.inlineButton("< PAGE", colors.cyan)
            write(" ")
            buttons.next = ui.inlineButton("PAGE >", colors.cyan)
            write(" ")
            buttons.step = ui.inlineButton("STEP", colors.cyan)
            print("")
            buttons.power = ui.inlineButton(reactor.active == true and
                "TURN OFF" or "TURN ON", colors.orange)
            write(" ")
            buttons.allDown = ui.inlineButton("ALL -", colors.orange)
            write(" ")
            buttons.allUp = ui.inlineButton("ALL +", colors.lime)
            write(" ")
            buttons.back = ui.inlineButton("BACK", colors.cyan)
            print("")
            ui.line("Keyboard: <-/-> page | Z/X all rods | T step | P power | B back", colors.gray)

            local event, value, message, protocol = os.pullEvent()
            local x, y = ui.eventPoint(event, value, message, protocol)
            if (event == "key" and value == keys.b) or ui.hit(buttons.back, x, y) then
                return
            elseif (event == "key" and value == keys.left) or ui.hit(buttons.previous, x, y) then page = math.max(1, page - 1)
            elseif (event == "key" and value == keys.right) or ui.hit(buttons.next, x, y) then page = math.min(pages, page + 1)
            elseif (event == "key" and value == keys.t) or ui.hit(buttons.step, x, y) then
                step = step == 1 and 5 or step == 5 and 10 or 1
            elseif (event == "key" and value == keys.p) or ui.hit(buttons.power, x, y) then
                local ok, _, reason = reactorAdapter.setActive(reactor,
                    reactor.active ~= true)
                notice = ok and "Reactor state verified" or tostring(reason)
                pollReactors()
            elseif (event == "key" and (value == keys.z or value == keys.x)) or
                   ui.hit(buttons.allDown, x, y) or ui.hit(buttons.allUp, x, y) then
                local current = tonumber(reactor.controlRodLevel) or 100
                local increase = (event == "key" and value == keys.x) or ui.hit(buttons.allUp, x, y)
                local requested = current + (increase and step or -step)
                local ok, _, reason = reactorAdapter.setAllControlRodLevels(
                    reactor, requested)
                notice = ok and "All rods verified" or tostring(reason)
                pollReactors()
            else
                for _, rod in ipairs(buttons.rods) do
                    local direction = ui.hit(rod.decrease, x, y) and -1 or
                        ui.hit(rod.increase, x, y) and 1 or 0
                    if direction ~= 0 and rod.level then
                        local ok, _, reason = reactorAdapter.setControlRodLevel(
                            reactor, rod.index, rod.level + direction * step)
                        notice = ok and ("Rod %d verified"):format(rod.index + 1) or
                            tostring(reason)
                        pollReactors()
                        break
                    end
                end
            end
            if event == "rednet_message" then handleNetwork(value, message, protocol) end
            if event == "timer" and value == reactorTimer then
                pollReactors()
                broadcastSnapshots()
                reactorTimer = os.startTimer(1)
            end
        end
    end

    -- @section MANUAL TURBINE CONTROLS
    local function manualTurbineView()
        local selected, step, notice = 1, 100
        local buttons = {}
        while config.control.mode == "manual" do
            buttons = {}
            ui.header("MANUAL TURBINE", "Direct flow and power control")
            ui.status("Authority", manualSafetyState.armed and
                "MANUAL - GUARDED" or "MANUAL - GUARD ARMING", colors.orange)
            if #turbines == 0 then
                ui.status("Status", "NO TURBINES FOUND", colors.orange)
                buttons.back = ui.button("BACK", colors.cyan)
            else
                if selected > #turbines then selected = #turbines end
                local turbine = turbines[selected]
                ui.status("Turbine", ("%d/%d %s"):format(selected, #turbines,
                    deviceName(turbine.name)), colors.cyan)
                ui.status("State", turbine.active == true and "ACTIVE" or
                    turbine.active == false and "OFFLINE" or "UNKNOWN",
                    turbine.active == true and colors.lime or colors.orange)
                ui.status("Steam actual / limit", ("%s / %s"):format(
                    turbine.flowRate and ("%.0f mB/t"):format(turbine.flowRate) or "N/A",
                    turbine.flowRateMax and ("%.0f mB/t"):format(turbine.flowRateMax) or "N/A"),
                    colors.cyan)
                ui.status("Steam buffer", turbine.inputPercent and
                    ("%.1f%%"):format(turbine.inputPercent) or "N/A")
                ui.status("Rotor / output", ("%s / %s"):format(
                    turbine.rotorSpeed and ("%.1f RPM"):format(turbine.rotorSpeed) or "N/A",
                    powerFormat.power(turbine.energyProduction, config.power, true)))
                ui.status("Flow adjustment", step .. " mB/t", colors.cyan)
                if notice then ui.line(notice, colors.orange) end
                buttons.previous = ui.inlineButton("< PREVIOUS", colors.cyan)
                write(" ")
                buttons.next = ui.inlineButton("NEXT >", colors.cyan)
                write(" ")
                buttons.step = ui.inlineButton("STEP", colors.cyan)
                print("")
                buttons.down = ui.inlineButton("FLOW -", colors.orange)
                write(" ")
                buttons.up = ui.inlineButton("FLOW +", colors.lime)
                print("")
                buttons.power = ui.inlineButton(turbine.active == true and
                    "TURN OFF" or "TURN ON", colors.orange)
                write(" ")
                buttons.back = ui.inlineButton("BACK", colors.cyan)
                print("")
                ui.line("Keyboard: <-/-> select | Z/X flow | T step | P power | B back", colors.gray)
            end

            local event, value, message, protocol = os.pullEvent()
            local x, y = ui.eventPoint(event, value, message, protocol)
            if (event == "key" and value == keys.b) or ui.hit(buttons.back, x, y) then
                return
            elseif #turbines > 0 then
                local turbine = turbines[selected]
                if (event == "key" and value == keys.left) or ui.hit(buttons.previous, x, y) then
                    selected = ((selected - 2) % #turbines) + 1
                elseif (event == "key" and value == keys.right) or ui.hit(buttons.next, x, y) then
                    selected = (selected % #turbines) + 1
                elseif (event == "key" and value == keys.t) or ui.hit(buttons.step, x, y) then
                    step = step == 100 and 500 or step == 500 and 1000 or 100
                elseif (event == "key" and (value == keys.z or value == keys.x)) or
                       ui.hit(buttons.down, x, y) or ui.hit(buttons.up, x, y) then
                    local current = tonumber(turbine.flowRateMax)
                    if not current then
                        notice = "Flow-limit telemetry is unavailable"
                    else
                        local increase = (event == "key" and value == keys.x) or
                            ui.hit(buttons.up, x, y)
                        local change = increase and step or -step
                        local ok, _, reason = turbineAdapter.setFlowLimit(turbine, current + change)
                        notice = ok and "Turbine flow limit verified" or tostring(reason)
                        pollReactors()
                    end
                elseif (event == "key" and value == keys.p) or ui.hit(buttons.power, x, y) then
                    local ok, _, reason = turbineAdapter.setActive(turbine,
                        turbine.active ~= true)
                    notice = ok and "Turbine state verified" or tostring(reason)
                    pollReactors()
                end
            end
            if event == "rednet_message" then handleNetwork(value, message, protocol) end
            if event == "timer" and value == reactorTimer then
                pollReactors()
                broadcastSnapshots()
                reactorTimer = os.startTimer(1)
            end
        end
    end

    local function controlView()
        local selected = 1
        local armed = false
        local buttons = {}
        local function draw()
            buttons = {}
            ui.setIdConflicts(idConflicts)
            ui.header("POWER CONTROL", "Guarded plant authority")
            local manual = config.control.mode == "manual"
            ui.status("Mode", manual and "MANUAL" or "AUTOMATIC",
                manual and colors.orange or colors.lime)
            ui.status("Actuators", "ENABLED - GUARDED", colors.lime)
            local reserve = minimumPowerReserve()
            local safetyState = manual and
                (manualSafetyState.armed and "ARMED" or "ARMING") or "STANDBY"
            ui.status("Safety guard", reserve and ("%s %.1f%% / %.1f%%"):
                format(safetyState, reserve, config.control.manualSafetyReserve) or
                (safetyState .. " / NO STORAGE"), reserve and colors.cyan or colors.gray)
            if manualNotice then ui.line(manualNotice, colors.orange) end
            if manual then
                if #reactors == 0 then
                    ui.status("Status", "NO REACTORS FOUND", colors.orange)
                else
                    if selected > #reactors then selected = #reactors end
                    local reactor = reactors[selected]
                    ui.status("Reactor", ("%d/%d %s"):format(selected, #reactors,
                        deviceName(reactor.name)), colors.cyan)
                    ui.status("State", reactor.active == true and "ACTIVE" or "OFFLINE")
                    ui.status("Rods", ("%d / %.1f%% average"):format(
                        tonumber(reactor.controlRods) or 0,
                        tonumber(reactor.controlRodLevel) or 0))
                end
                if #turbines > 0 then
                    ui.status("Turbines", (#turbines .. " MANUAL CONTROL AVAILABLE"), colors.cyan)
                end
            elseif #turbines == 0 then
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
            if manual then
                buttons.mode = ui.button("RETURN TO AUTOMATIC", colors.lime)
                buttons.reactor = #reactors > 0 and
                    ui.button("REACTOR ROD CONTROLS", colors.orange) or nil
                buttons.turbine = #turbines > 0 and
                    ui.button("TURBINE CONTROLS", colors.cyan) or nil
            else
                buttons.mode = ui.button(armed and "CONFIRM MANUAL CONTROL" or
                    "ARM MANUAL CONTROL", armed and colors.red or colors.orange)
            end
            buttons.previous = ui.inlineButton("< PREVIOUS", colors.cyan)
            write(" ")
            buttons.next = ui.inlineButton("NEXT >", colors.cyan)
            write(" ")
            buttons.back = ui.inlineButton("BACK", colors.cyan)
            print("")
            if not manual and #turbines > 0 then
                local selectedTurbine = turbines[selected]
                local label = selectedTurbine.active == false and
                    "START & CALIBRATE" or "RETRY CALIBRATION"
                buttons.retry = ui.button(label, colors.orange)
            else
                buttons.retry = nil
            end
        end
        while true do
            draw()
            local event, value, message, protocol = os.pullEvent()
            local x, y = ui.eventPoint(event, value, message, protocol)
            if event == "key" and value == keys.b then return
            elseif ui.hit(buttons.mode, x, y) then
                if config.control.mode == "manual" then
                    returnToAutomatic("Manual control ended by operator", false)
                    armed = false
                elseif armed and #idConflicts == 0 then
                    config.control.mode = "manual"
                    manualSafetyState = manualControl.newSafetyState()
                    local activated, activationErrors = manualControl.activateReactors(
                        reactors, reactorAdapter.setActive)
                    manualNotice = activated and
                        "Reactors active; governors paused; safety guard arming" or
                        ("Manual armed; reactor activation failed: " ..
                            table.concat(activationErrors, "; "))
                    pollReactors()
                    armed = false
                else
                    armed = true
                    manualNotice = #idConflicts > 0 and
                        "Manual control blocked by computer ID conflict" or
                        "Press CONFIRM to accept direct control authority"
                end
            elseif ui.hit(buttons.reactor, x, y) and #reactors > 0 then
                manualReactorView(reactors[selected].name)
            elseif ui.hit(buttons.turbine, x, y) and #turbines > 0 then
                manualTurbineView()
            elseif ((event == "key" and value == keys.left) or ui.hit(buttons.previous, x, y)) and
                   ((config.control.mode == "manual" and #reactors > 0) or #turbines > 0) then
                local count = config.control.mode == "manual" and #reactors or #turbines
                selected = ((selected - 2) % count) + 1
            elseif ((event == "key" and value == keys.right) or ui.hit(buttons.next, x, y)) and
                   ((config.control.mode == "manual" and #reactors > 0) or #turbines > 0) then
                local count = config.control.mode == "manual" and #reactors or #turbines
                selected = (selected % count) + 1
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

    local function restartReactorPolling()
        if reactorTimer then os.cancelTimer(reactorTimer) end
        pollReactors()
        reactorTimer = os.startTimer(1)
    end

    local function restoreTimersAfterTextInput()
        restartReactorPolling()
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

    -- @section SETTINGS
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
            local selectedGui = guiLoader.resolve(config.ui.renderer, config.version)
            ui.status("Graphical interface", selectedGui and selectedGui.name or
                (tostring(config.ui.renderer) .. " (UNAVAILABLE)"), selectedGui and colors.cyan or colors.orange)
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
            buttons.gui = ui.inlineButton("GUI MODULE", colors.cyan)
            print("")
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
            elseif (event == "key" and value == keys.g) or ui.hit(buttons.gui, touchX, touchY) then
                local modules = guiLoader.scan(config.version)
                local index = 1
                for moduleIndex, module in ipairs(modules) do
                    if module.id == config.ui.renderer then index = moduleIndex break end
                end
                while true do
                    ui.header("GUI MODULES", "Installed graphical interfaces")
                    local module = modules[index]
                    ui.status("Selected", module.name, colors.cyan)
                    ui.status("Module ID", module.id)
                    ui.status("Minimum display", ("%dx%d characters"):format(
                        module.minimumWidth or 1, module.minimumHeight or 1))
                    print("")
                    local previous = ui.inlineButton("< PREVIOUS", colors.cyan)
                    write(" ")
                    local nextButton = ui.inlineButton("NEXT >", colors.cyan)
                    print("")
                    local apply = ui.inlineButton("USE THIS GUI", colors.lime)
                    write(" ")
                    local back = ui.inlineButton("BACK", colors.cyan)
                    print("")
                    local subEvent, subValue, subMessage, subProtocol = os.pullEvent()
                    local sx, sy = ui.eventPoint(subEvent, subValue, subMessage, subProtocol)
                    if (subEvent == "key" and subValue == keys.b) or ui.hit(back, sx, sy) then break
                    elseif (subEvent == "key" and subValue == keys.left) or ui.hit(previous, sx, sy) then
                        index = ((index - 2) % #modules) + 1
                    elseif (subEvent == "key" and subValue == keys.right) or ui.hit(nextButton, sx, sy) then
                        index = (index % #modules) + 1
                    elseif (subEvent == "key" and subValue == keys.enter) or ui.hit(apply, sx, sy) then
                        config.ui.renderer = module.id
                        saveConfig()
                        break
                    elseif subEvent == "rednet_message" then handleNetwork(subValue, subMessage, subProtocol)
                    elseif subEvent == "timer" and subValue == reactorTimer then
                        pollReactors(); broadcastSnapshots(); reactorTimer = os.startTimer(1)
                    end
                end
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

    local function facilityHeader(role, subtitle)
        local buttons = {}
        ui.header(role, subtitle, function()
            buttons.reactors = ui.inlineButton("REACTORS", colors.red)
            write(" ")
            buttons.turbines = ui.inlineButton("TURBINES", colors.blue)
            write(" ")
            buttons.storage = ui.inlineButton("POWER", colors.yellow)
            print("")
        end)
        return buttons
    end

    -- @section REACTOR VIEW AND CALIBRATION
    local function reactorView()
        local selected = 1
        local viewSilenceButton
        local previousButton
        local nextButton
        local backButton
        local calibrationButton
        local notice
        local navigationButtons = {}

        local function displayedReactors()
            local result = {}
            for _, reactor in ipairs(reactors) do result[#result + 1] = reactor end
            for _, reactor in ipairs(facilityReactorViews()) do result[#result + 1] = reactor end
            return result
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
                    plan.steamProductionLow and plan.steamProductionHigh and
                    ("%.0f avg [%.0f-%.0f]"):format(
                        plan.averageSteamProduction,
                        plan.steamProductionLow,
                        plan.steamProductionHigh) or
                    plan.averageSteamProduction and
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
                        -- Recalibration is an explicit operator-confirmed safe
                        -- insertion. Apply and verify that conservative command
                        -- immediately, then restart the polling timer so the
                        -- baseline cannot remain at sample 1 after a modal view.
                        local prepared, prepareError =
                            reactorAdapter.prepareRecalibration(reactor, function()
                                sleep(0.1)
                            end)
                        if prepared then
                            reactorGovernor.beginRecalibration(reactorGovernorMemory,
                                config.control, reactorName)
                            saveConfig()
                            if maintenance then stopMaintenance() end
                            maintenanceEnabledHere = false
                            restartReactorPolling()
                            calibrationNotice = {
                                text = "RECALIBRATION STARTED - RODS INSERTED",
                                colour = colors.orange,
                            }
                        else
                            calibrationNotice = {
                                text = "RECALIBRATION BLOCKED: " ..
                                    tostring(prepareError or "REACTOR RESET FAILED"),
                                colour = colors.red,
                            }
                        end
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
                            turbineGovernor.requestSteamPrime(governorMemory)
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
            navigationButtons = facilityHeader("REACTORS", "Live telemetry and steam governor")
            local reactorList = displayedReactors()
            if #reactorList == 0 then
                ui.status("Status", "NO REACTORS FOUND", colors.orange)
                print("")
                previousButton, nextButton, viewSilenceButton, calibrationButton = nil, nil, nil, nil
                backButton = ui.button("BACK", colors.cyan)
                return
            end
            if selected > #reactorList then selected = #reactorList end
            local reactor = reactorList[selected]
            ui.status("Reactor", ("%d/%d %s"):format(selected, #reactorList, deviceName(reactor.name)), colors.cyan)
            if reactor.facility then
                local function ratio(value, maximum)
                    value, maximum = tonumber(value), tonumber(maximum)
                    if not value or not maximum or maximum <= 0 then return nil end
                    return math.max(0, math.min(100, value / maximum * 100))
                end
                ui.status("Type", "DRACONIC / REMOTE GUARDIAN", colors.magenta)
                ui.status("Authority", "READ-ONLY / LOCAL GUARDIAN", colors.lightGray)
                ui.status("Link", reactor.online and "ONLINE" or "STALE",
                    reactor.online and colors.lime or colors.orange)
                ui.status("State", string.upper(tostring(reactor.state or "UNKNOWN")), colors.white)
                ui.status("Generation", powerFormat.power(reactor.generationRate,
                    config.power, true), colors.cyan)
                ui.status("Core", formatValue(reactor.temperature, " C"), colors.orange)
                ui.status("Field", formatValue(ratio(reactor.fieldStrength,
                    reactor.maxFieldStrength), "%"))
                ui.status("Saturation", formatValue(ratio(reactor.energySaturation,
                    reactor.maxEnergySaturation), "%"))
                ui.status("Fuel conversion", formatValue(ratio(reactor.fuelConversion,
                    reactor.maxFuelConversion), "%"))
                ui.status("Field gate", powerFormat.power(reactor.fieldGate,
                    config.power, true), colors.lime)
                ui.status("Export gate", powerFormat.power(reactor.exportGate,
                    config.power, true), colors.lime)
                ui.status("Guardian", tostring(reactor.mode or "UNKNOWN") .. " / " ..
                    tostring(reactor.request or "UNKNOWN"), colors.orange)
                ui.status("Version", tostring(reactor.softwareVersion or "UNKNOWN"), colors.lightGray)
                print("")
                previousButton = ui.inlineButton("< PREVIOUS", colors.cyan)
                write(" ")
                nextButton = ui.inlineButton("NEXT >", colors.cyan)
                write(" ")
                backButton = ui.inlineButton("BACK", colors.cyan)
                print("")
                calibrationButton = nil
                viewSilenceButton = nil
                if notice then ui.status("Result", notice, colors.orange) end
                return
            end
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
            local selectedReactor = reactorList[selected]
            calibrationButton = selectedReactor and ui.button("CALIBRATION STATUS",
                selectedReactor.mode == "steam" and colors.lime or colors.gray) or nil
            if notice then ui.status("Result", notice, colors.orange) end
        end

        while true do
            draw()
            local event, value, x, y = os.pullEvent()
            if event == "key" and value == keys.b then
                return "dashboard"
            elseif event == "key" and value == keys.v then
                return "reactors"
            elseif event == "key" and value == keys.g then
                return "turbines"
            elseif event == "key" and value == keys.e then
                return "storage"
            elseif event == "key" and value == keys.left and #displayedReactors() > 0 then
                selected = ((selected - 2) % #displayedReactors()) + 1
            elseif event == "key" and value == keys.right and #displayedReactors() > 0 then
                selected = (selected % #displayedReactors()) + 1
            elseif (event == "mouse_click" or event == "monitor_touch") and ui.hit(viewSilenceButton, x, y) then
                silenceCurrentAlarm()
            elseif (event == "mouse_click" or event == "monitor_touch") and
                   ui.hit(navigationButtons.reactors, x, y) then
                return "reactors"
            elseif (event == "mouse_click" or event == "monitor_touch") and
                   ui.hit(navigationButtons.turbines, x, y) then
                return "turbines"
            elseif (event == "mouse_click" or event == "monitor_touch") and
                   ui.hit(navigationButtons.storage, x, y) then
                return "storage"
            elseif (event == "mouse_click" or event == "monitor_touch") and ui.hit(previousButton, x, y) and #displayedReactors() > 0 then
                selected = ((selected - 2) % #displayedReactors()) + 1
            elseif (event == "mouse_click" or event == "monitor_touch") and ui.hit(nextButton, x, y) and #displayedReactors() > 0 then
                selected = (selected % #displayedReactors()) + 1
            elseif (event == "mouse_click" or event == "monitor_touch") and ui.hit(backButton, x, y) then
                return "dashboard"
            elseif (event == "mouse_click" or event == "monitor_touch") and
                   ui.hit(calibrationButton, x, y) and selected <= #reactors then
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

    -- @section TURBINE VIEW
    local function turbineView()
        local selected = 1
        local previousButton, nextButton, backButton, idleButton
        local navigationButtons = {}

        local function formatValue(value, suffix)
            if value == nil then return "N/A" end
            return ("%.1f%s"):format(value, suffix or "")
        end

        local function draw()
            navigationButtons = facilityHeader("TURBINES", "Live telemetry and governor plan")
            if #turbines == 0 then
                ui.status("Status", "NO TURBINES FOUND", colors.orange)
                print("")
                previousButton, nextButton, idleButton = nil, nil, nil
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
                local profile = (config.control.turbineProfiles or {})[tostring(turbine.name)]
                if type(profile) == "table" and profile.calibrated == true then
                    idleButton = ui.button(profile.assistedIdle == true and
                        "STEAM-ASSISTED IDLE: ENABLED" or
                        "STEAM-ASSISTED IDLE: DISABLED",
                        profile.assistedIdle == true and colors.lime or colors.gray)
                else
                    idleButton = nil
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
                return "dashboard"
            elseif event == "key" and value == keys.v then
                return "reactors"
            elseif event == "key" and value == keys.g then
                return "turbines"
            elseif event == "key" and value == keys.e then
                return "storage"
            elseif event == "key" and value == keys.left and #turbines > 0 then
                selected = ((selected - 2) % #turbines) + 1
            elseif event == "key" and value == keys.right and #turbines > 0 then
                selected = (selected % #turbines) + 1
            elseif ui.hit(previousButton, touchX, touchY) and #turbines > 0 then
                selected = ((selected - 2) % #turbines) + 1
            elseif ui.hit(nextButton, touchX, touchY) and #turbines > 0 then
                selected = (selected % #turbines) + 1
            elseif ui.hit(idleButton, touchX, touchY) and #turbines > 0 then
                local name = tostring(turbines[selected].name)
                local profile = (config.control.turbineProfiles or {})[name]
                if type(profile) == "table" and profile.calibrated == true then
                    profile.assistedIdle = profile.assistedIdle ~= true
                    configStore.save(config)
                end
            elseif ui.hit(navigationButtons.reactors, touchX, touchY) then
                return "reactors"
            elseif ui.hit(navigationButtons.turbines, touchX, touchY) then
                return "turbines"
            elseif ui.hit(navigationButtons.storage, touchX, touchY) then
                return "storage"
            elseif ui.hit(backButton, touchX, touchY) then
                return "dashboard"
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

    -- @section STORAGE VIEW
    local function storageView()
        local selected = 1
        local previousButton, nextButton, backButton
        local navigationButtons = {}

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
            navigationButtons = facilityHeader("ENERGY STORAGE", "Universal read-only telemetry")
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
                return "dashboard"
            elseif event == "key" and value == keys.v then
                return "reactors"
            elseif event == "key" and value == keys.g then
                return "turbines"
            elseif event == "key" and value == keys.e then
                return "storage"
            elseif event == "key" and value == keys.left and #storages > 0 then
                selected = ((selected - 2) % #storages) + 1
            elseif event == "key" and value == keys.right and #storages > 0 then
                selected = (selected % #storages) + 1
            elseif ui.hit(previousButton, touchX, touchY) and #storages > 0 then
                selected = ((selected - 2) % #storages) + 1
            elseif ui.hit(nextButton, touchX, touchY) and #storages > 0 then
                selected = (selected % #storages) + 1
            elseif ui.hit(navigationButtons.reactors, touchX, touchY) then
                return "reactors"
            elseif ui.hit(navigationButtons.turbines, touchX, touchY) then
                return "turbines"
            elseif ui.hit(navigationButtons.storage, touchX, touchY) then
                return "storage"
            elseif ui.hit(backButton, touchX, touchY) then
                return "dashboard"
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

    -- @section READ-ONLY GRAPHICAL INTERFACE
    local function graphicalView()
        local page = "overview"
        local selected = { reactors = 1, turbines = 1, storage = 1 }
        local buttons = {}
        local customState, customButtons, customManifest = {}, {}, nil
        local customRenderer

        local function displayedReactors()
            local result = {}
            for _, reactor in ipairs(reactors) do result[#result + 1] = reactor end
            for _, reactor in ipairs(facilityReactorViews()) do result[#result + 1] = reactor end
            return result
        end

        local function reloadCustomRenderer()
            customRenderer, customManifest = nil, nil
            local width, height = display.monitorSize()
            if width then
                customRenderer, customManifest = guiLoader.load(config.ui.renderer,
                    config.version, width, height)
            end
        end
        reloadCustomRenderer()

        local function readiness()
            if #idConflicts > 0 then return "FAULT", "DUPLICATE COMPUTER ID", colors.red end
            if authority.needsSelection(authorityState) then
                return "AUTHORITY", "MULTIPLE MAINFRAMES - SELECT ONE", colors.orange
            end
            if not authority.canControl(authorityState) then
                local peer = authority.controllingPeer(authorityState)
                return "MONITORING", peer and ("CONTROLLED BY MAINFRAME " .. peer.id) or
                    "AUTOMATIC CONTROL DISABLED", colors.cyan
            end
            local alarmLevel = currentAlarm and tonumber(currentAlarm.level) or nil
            if currentAlarm and alarmLevel and alarmLevel >= 3 then
                return "FAULT", currentAlarm.message, colors.red
            end
            if currentAlarm then return "WARNING", currentAlarm.message, colors.orange end
            for _, reactor in ipairs(reactors) do
                local state = string.upper(tostring(reactor.governor and reactor.governor.state or ""))
                if string.find(state, "CALIBRAT", 1, true) then
                    return "CALIBRATING", deviceName(reactor.name), colors.orange
                end
            end
            for _, turbine in ipairs(turbines) do
                local state = string.upper(tostring(turbine.governor and turbine.governor.state or ""))
                if string.find(state, "CALIBRAT", 1, true) or
                   string.find(state, "SPOOL", 1, true) or
                   string.find(state, "PRIM", 1, true) then
                    return "CALIBRATING", deviceName(turbine.name) .. " - " .. state, colors.orange
                end
            end
            if #reactors == 0 and #turbines == 0 and #storages == 0 then
                return "STARTING", "WAITING FOR PLANT TELEMETRY", colors.orange
            end
            local controlText = select(1, controlStatus())
            if string.find(controlText, "WAITING", 1, true) then
                return "STARTING", controlText, colors.orange
            end
            return "READY", controlText, colors.lime
        end

        local function header(title)
            gui.prepare()
            local width = select(1, term.getSize())
            gui.text(1, 1, "HELIOS // " .. title, colors.yellow)
            local version = "v" .. tostring(config.version)
            gui.text(math.max(1, width - #version + 1), 1, version, colors.yellow)
            local state, detail, colour = readiness()
            gui.text(1, 2, " " .. state .. " ", colors.black, colour)
            gui.text(#state + 4, 2, detail, colour, colors.black,
                math.max(0, width - #state - 3))
            buttons = {}
            local x = 1
            buttons.overview = gui.button(x, 4, "HOME", colors.white,
                page == "overview" and colors.gray or colors.black)
            x = buttons.overview.x2 + 2
            buttons.reactors = gui.button(x, 4, "REACTORS", colors.red,
                page == "reactors" and colors.gray or colors.black)
            x = buttons.reactors.x2 + 2
            buttons.turbines = gui.button(x, 4, "TURBINES", colors.cyan,
                page == "turbines" and colors.gray or colors.black)
            x = buttons.turbines.x2 + 2
            buttons.storage = gui.button(x, 4, "POWER", colors.yellow,
                page == "storage" and colors.gray or colors.black)
            buttons.advanced = gui.button(1, select(2, term.getSize()), "ADVANCED",
                colors.white, colors.gray)
            if currentAlarm and currentAlarm.facilityNodeId then
                buttons.scram = gui.button(12, select(2, term.getSize()), "SCRAM",
                    colors.white, colors.red)
            end
        end

        local function overview()
            header("PLANT OVERVIEW")
            local width = select(1, term.getSize())
            gui.text(1, 6, "SYSTEM READINESS", colors.lightGray)
            local state, detail, colour = readiness()
            gui.text(1, 7, state, colour)
            gui.text(1, 8, detail, colors.white, colors.black, width)
            gui.text(1, 10, ("REACTORS  %d   TURBINES  %d   STORAGE  %d"):format(
                #displayedReactors(), #turbines, #storages), colors.cyan)
            local reserve = minimumPowerReserve()
            gui.text(1, 12, "POWER RESERVE", colors.lightGray)
            gui.progress(1, 13, math.max(10, width - 8), reserve or 0,
                reserve and reserve > 20 and colors.lime or colors.orange, colors.gray)
            gui.text(math.max(1, width - 6), 13,
                reserve and ("%5.1f%%"):format(reserve) or "  N/A", colors.white)
            gui.text(1, 15, "Graphical monitoring only", colors.gray)
            gui.text(1, 16, "Manual control: ADVANCED text interface", colors.gray)
            local height = select(2, term.getSize())
            if authority.needsSelection(authorityState) then
                local row = math.max(17, height - 2)
                buttons.keepControl = gui.button(1, row, "KEEP CONTROL", colors.black, colors.lime)
                buttons.monitorOnly = gui.button(buttons.keepControl.x2 + 2, row,
                    "MONITOR ONLY", colors.black, colors.cyan)
            elseif authorityState.mode == "monitor" and
                   not authority.controllingPeer(authorityState) then
                local row = math.max(17, height - 2)
                buttons.keepControl = gui.button(1, row, "TAKE CONTROL", colors.black, colors.orange)
            end
        end

        local function reactorPage()
            header("REACTORS")
            local width = select(1, term.getSize())
            local reactorList = displayedReactors()
            if #reactorList == 0 then
                gui.text(1, 7, "NO REACTORS FOUND", colors.orange)
                return
            end
            selected.reactors = math.max(1, math.min(selected.reactors, #reactorList))
            local reactor = reactorList[selected.reactors]
            if reactor.facility then
                local function ratio(value, maximum)
                    value, maximum = tonumber(value), tonumber(maximum)
                    if not value or not maximum or maximum <= 0 then return nil end
                    return math.max(0, math.min(100, value / maximum * 100))
                end
                local field = ratio(reactor.fieldStrength, reactor.maxFieldStrength)
                local saturation = ratio(reactor.energySaturation, reactor.maxEnergySaturation)
                local fuel = ratio(reactor.fuelConversion, reactor.maxFuelConversion)
                gui.text(1, 6, ("%d/%d  %s"):format(selected.reactors, #reactorList,
                    deviceName(reactor.name)), colors.cyan, colors.black, width)
                gui.text(1, 7, "TYPE DRACONIC / REMOTE GUARDIAN", colors.magenta)
                gui.text(1, 8, "LINK " .. (reactor.online and "ONLINE" or "STALE"),
                    reactor.online and colors.lime or colors.orange)
                gui.text(1, 9, "STATE " .. string.upper(tostring(reactor.state or "UNKNOWN")), colors.white)
                gui.text(1, 10, "GENERATION " .. powerFormat.power(reactor.generationRate,
                    config.power, true), colors.cyan)
                gui.text(1, 11, reactor.temperature and
                    ("CORE %.2f C"):format(reactor.temperature) or "CORE N/A", colors.orange)
                gui.text(1, 12, field and ("FIELD %.1f%%"):format(field) or "FIELD N/A", colors.white)
                gui.text(1, 13, saturation and
                    ("SATURATION %.1f%%"):format(saturation) or "SATURATION N/A", colors.white)
                gui.text(1, 14, fuel and
                    ("FUEL CONVERSION %.1f%%"):format(fuel) or "FUEL CONVERSION N/A", colors.white)
                gui.text(1, 15, "FIELD GATE " .. powerFormat.power(reactor.fieldGate,
                    config.power, true), colors.lime)
                gui.text(1, 16, "EXPORT GATE " .. powerFormat.power(reactor.exportGate,
                    config.power, true), colors.lime)
                gui.text(1, 17, "GUARDIAN " .. tostring(reactor.mode or "UNKNOWN") .. " / " ..
                    tostring(reactor.request or "UNKNOWN"), colors.orange)
                gui.text(1, 19, "[<] PREVIOUS     NEXT [>]", colors.cyan)
                return
            end
            local output = reactor.mode == "steam" and reactor.steamProduction or reactor.energyProduction
            local target = reactor.mode == "steam" and
                tonumber(reactor.governor and reactor.governor.targetSteam) or
                tonumber(reactor.governor and reactor.governor.targetPower)
            local profile = reactor.mode == "steam" and
                ((config.control.reactorProfiles or {})[reactor.name] or
                    (reactor.governor and reactor.governor.learnedProfile)) or
                ((config.control.powerReactorProfiles or {})[reactor.name])
            local maximum = profile and (reactor.mode == "steam" and
                tonumber(profile.learnedMaximumSteam) or tonumber(profile.maximumPower)) or nil
            local scale = maximum and maximum > 0 and maximum or
                math.max(1, tonumber(target) or 0, tonumber(output) or 0)
            local outputPercent = maximum and maximum > 0 and
                math.min(100, (tonumber(output) or 0) / scale * 100) or
                tonumber(reactor.energyPercent) or 0
            local barWidth = math.max(10, width - 10)
            gui.text(1, 6, ("%d/%d  %s"):format(selected.reactors, #reactorList,
                deviceName(reactor.name)), colors.cyan, colors.black, width)
            gui.text(1, 7, ("TYPE %-8s  %s"):format(string.upper(reactor.mode or "unknown"),
                reactor.active == true and "ACTIVE" or "OFFLINE"),
                reactor.active == true and colors.lime or colors.orange)
            local unit = reactor.mode == "steam" and "mB/t" or "FE/t"
            gui.text(1, 8,
                maximum and ("OUTPUT %.0f / %.0f %s"):format(output or 0, maximum, unit) or
                    ("OUTPUT %.0f / LEARNING"):format(output or 0),
                colors.lightGray, colors.black, width)
            if target then
                gui.text(1, 9, ("DEMAND %.0f %s"):format(target, unit), colors.yellow)
            end
            gui.progress(1, 10, barWidth, outputPercent,
                reactor.active == true and colors.lime or colors.orange, colors.gray)
            if target and maximum and maximum > 0 then
                local marker = math.floor(math.max(0, math.min(100,
                    target / maximum * 100)) / 100 * (barWidth - 1))
                gui.text(1 + marker, 10, "|", colors.yellow)
            elseif reactor.mode ~= "steam" then
                gui.text(math.max(1, width - 8), 10,
                    output and ("%.0f"):format(output) or "N/A", colors.white)
            end
            gui.text(1, 12, "FUEL", colors.lightGray)
            gui.progress(1, 13, math.max(10, width - 10), reactor.fuelPercent or 0,
                (reactor.fuelPercent or 0) < 20 and colors.orange or colors.lime, colors.gray)
            gui.text(math.max(1, width - 8), 13,
                reactor.fuelPercent and ("%6.1f%%"):format(reactor.fuelPercent) or "   N/A", colors.white)
            local buffer = reactor.mode == "steam" and reactor.hotFluidPercent or reactor.energyPercent
            gui.text(1, 15, ("CYANITE %s mB"):format(
                reactor.waste and ("%.0f"):format(reactor.waste) or "N/A"), colors.cyan)
            gui.text(math.max(24, width - 16), 15, ("BUFFER %s"):format(
                buffer and ("%.1f%%"):format(buffer) or "N/A"), colors.cyan)
            gui.text(1, 17, "[<] PREVIOUS     NEXT [>]", colors.cyan)
        end

        local function turbinePage()
            header("TURBINES")
            local width = select(1, term.getSize())
            if #turbines == 0 then
                gui.text(1, 7, "NO TURBINES FOUND", colors.orange)
                return
            end
            selected.turbines = math.max(1, math.min(selected.turbines, #turbines))
            local turbine = turbines[selected.turbines]
            local rpm = tonumber(turbine.rotorSpeed) or 0
            gui.text(1, 6, ("%d/%d  %s"):format(selected.turbines, #turbines,
                deviceName(turbine.name)), colors.cyan, colors.black, width)
            gui.text(1, 7, turbine.active == true and "ACTIVE" or "OFFLINE",
                turbine.active == true and colors.lime or colors.orange)
            gui.text(1, 9, ("ROTOR %.1f RPM"):format(rpm), rpm >= 1900 and colors.red or colors.white)
            local gaugeWidth = math.max(20, width - 1)
            gui.rpmGauge(1, 10, gaugeWidth, rpm)
            local lowLabel = "[900 RPM]"
            local highLabel = "[1800 RPM]"
            local lowX = math.max(1, math.floor(900 / 2100 * (gaugeWidth - 1)) -
                math.floor(#lowLabel / 2) + 1)
            local highX = math.min(width - #highLabel + 1,
                math.floor(1800 / 2100 * (gaugeWidth - 1)) -
                math.floor(#highLabel / 2) + 1)
            gui.text(lowX, 11, lowLabel, colors.lime)
            gui.text(highX, 11, highLabel, colors.lime)
            local plan = turbine.governor or {}
            gui.text(1, 13, "STATE " .. tostring(plan.state or "WAITING"), colors.white)
            gui.text(1, 14, "OUTPUT " .. powerFormat.power(turbine.energyProduction,
                config.power, true), colors.cyan)
            gui.text(1, 16, "[<] PREVIOUS     NEXT [>]", colors.cyan)
        end

        local function storagePage()
            header("POWER STORAGE")
            local width = select(1, term.getSize())
            if #storages == 0 then
                gui.text(1, 7, "NO SUPPORTED STORAGE FOUND", colors.orange)
                return
            end
            selected.storage = math.max(1, math.min(selected.storage, #storages))
            local storage = storages[selected.storage]
            gui.text(1, 6, ("%d/%d  %s"):format(selected.storage, #storages,
                deviceName(storage.name)), colors.cyan, colors.black, width)
            gui.text(1, 8, "CAPACITY", colors.lightGray)
            gui.progress(1, 9, math.max(10, width - 10), storage.percent or 0,
                (storage.percent or 0) < 20 and colors.orange or colors.lime, colors.gray)
            gui.text(math.max(1, width - 8), 9,
                storage.percent and ("%6.1f%%"):format(storage.percent) or "   N/A", colors.white)
            gui.text(1, 11, "STORED  " .. powerFormat.power(storage.stored,
                config.power, false), colors.white)
            gui.text(1, 12, "FILL    " .. powerFormat.power(storage.input,
                config.power, true), colors.lime)
            gui.text(1, 13, "DRAW    " .. powerFormat.power(storage.output,
                config.power, true), colors.orange)
            gui.text(1, 14, "STATE   " .. tostring(storage.state or "UNKNOWN"), colors.cyan)
            gui.text(1, 16, "[<] PREVIOUS     NEXT [>]", colors.cyan)
        end

        local function draw()
            if page == "reactors" then reactorPage()
            elseif page == "turbines" then turbinePage()
            elseif page == "storage" then storagePage()
            else overview() end
        end

        while true do
            if customRenderer then
                display.useNative()
                draw()
                display.useMonitors()
                local ok, rendered = pcall(customRenderer.render, snapshotFor("all"), customState, {
                    gui = gui, powerFormat = powerFormat, allowEmergency = true,
                })
                if ok then customButtons = rendered or {} else customRenderer = nil end
                display.useNative()
            else
                display.useMirrored()
                draw()
                display.useNative()
            end
            local event, value, message, protocol = os.pullEvent()
            local touchX, touchY = ui.eventPoint(event, value, message, protocol)
            if (event == "monitor_touch" or event == "key") and customRenderer then
                local handled, action = pcall(customRenderer.handle, customState, customButtons,
                    event, value, message, protocol, { eventPoint = ui.eventPoint, hit = gui.hit })
                if not handled then customRenderer = nil
                elseif action == "advanced" then display.useMirrored(); return "advanced" end
                if action == "scram" and currentAlarm and currentAlarm.facilityNodeId then
                    scramFacility(currentAlarm.facilityNodeId)
                end
                if event == "monitor_touch" then touchX, touchY = nil, nil end
            end
            if event == "key" and value == keys.q then display.useMirrored(); return "quit"
            elseif event == "key" and value == keys.v then page = "reactors"
            elseif event == "key" and value == keys.g then page = "turbines"
            elseif event == "key" and value == keys.e then page = "storage"
            elseif event == "key" and value == keys.a then display.useMirrored(); return "advanced"
            elseif gui.hit(buttons.overview, touchX, touchY) then page = "overview"
            elseif gui.hit(buttons.reactors, touchX, touchY) then page = "reactors"
            elseif gui.hit(buttons.turbines, touchX, touchY) then page = "turbines"
            elseif gui.hit(buttons.storage, touchX, touchY) then page = "storage"
            elseif gui.hit(buttons.advanced, touchX, touchY) then display.useMirrored(); return "advanced"
            elseif gui.hit(buttons.scram, touchX, touchY) and
                   currentAlarm and currentAlarm.facilityNodeId then
                scramFacility(currentAlarm.facilityNodeId)
            elseif gui.hit(buttons.keepControl, touchX, touchY) then
                selectAuthority("control")
            elseif gui.hit(buttons.monitorOnly, touchX, touchY) then
                selectAuthority("monitor")
            elseif event == "key" and value == keys.left then
                local reactorList = displayedReactors()
                if page == "reactors" and #reactorList > 0 then
                    selected.reactors = ((selected.reactors - 2) % #reactorList) + 1
                elseif page == "turbines" and #turbines > 0 then
                    selected.turbines = ((selected.turbines - 2) % #turbines) + 1
                elseif page == "storage" and #storages > 0 then
                    selected.storage = ((selected.storage - 2) % #storages) + 1
                end
            elseif event == "key" and value == keys.right then
                local reactorList = displayedReactors()
                if page == "reactors" and #reactorList > 0 then
                    selected.reactors = (selected.reactors % #reactorList) + 1
                elseif page == "turbines" and #turbines > 0 then
                    selected.turbines = (selected.turbines % #turbines) + 1
                elseif page == "storage" and #storages > 0 then
                    selected.storage = (selected.storage % #storages) + 1
                end
            elseif event == "mouse_click" or event == "monitor_touch" then
                local reactorList = displayedReactors()
                if (touchY == 17 or touchY == 19) and page == "reactors" and #reactorList > 0 then
                    selected.reactors = touchX < 15 and ((selected.reactors - 2) % #reactorList) + 1 or
                        (selected.reactors % #reactorList) + 1
                elseif touchY == 16 and page == "turbines" and #turbines > 0 then
                    selected.turbines = touchX < 15 and ((selected.turbines - 2) % #turbines) + 1 or
                        (selected.turbines % #turbines) + 1
                elseif touchY == 16 and page == "storage" and #storages > 0 then
                    selected.storage = touchX < 15 and ((selected.storage - 2) % #storages) + 1 or
                        (selected.storage % #storages) + 1
                end
            elseif event == "rednet_message" then
                handleNetwork(value, message, protocol)
            elseif event == "peripheral" or event == "peripheral_detach" then
                if maintenance or config.discovery.defaultMode == "manual" then registryStale = true else rescan() end
                reloadCustomRenderer()
            elseif event == "term_resize" or event == "monitor_resize" then
                reloadCustomRenderer()
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

    local function openFacility(route)
        while route and route ~= "dashboard" do
            if route == "reactors" then
                route = reactorView()
            elseif route == "turbines" then
                route = turbineView()
            elseif route == "storage" then
                route = storageView()
            else
                return
            end
        end
    end

    local function openAlarmLocation()
        if not currentAlarm then return end
        local name = tostring(currentAlarm.key or ""):match("^(.-):")
        for _, reactor in ipairs(reactors) do
            if reactor.name == name then openFacility("reactors"); return end
        end
        for _, turbine in ipairs(turbines) do
            if turbine.name == name then openFacility("turbines"); return end
        end
        for _, storage in ipairs(storages) do
            if storage.name == name then openFacility("storage"); return end
        end
        controlView()
    end

    rescan(true)
    pollReactors()
    reactorTimer = os.startTimer(1)

    local function advancedDashboard()
        render()
        while true do
        local event, value, x, y = os.pullEvent()
        if event == "key" and value == keys.q then
            return "quit"
        elseif event == "key" and value == keys.b then
            return "graphical"
        elseif event == "key" and value == keys.r then
            rescan(true)
            render()
        elseif event == "key" and value == keys.s then
            settings()
            render()
        elseif event == "key" and value == keys.v then
            openFacility("reactors")
            render()
        elseif event == "key" and value == keys.g then
            openFacility("turbines")
            render()
        elseif event == "key" and value == keys.e then
            openFacility("storage")
            render()
        elseif event == "key" and value == keys.c then
            controlView()
            render()
        elseif event == "key" and value == keys.a then
            openAlarmLocation()
            render()
        elseif event == "monitor_touch" or event == "mouse_click" then
            local touchX, touchY = x, y
            if alarmButton and ui.hit(alarmButton, touchX, touchY) then
                openAlarmLocation()
            elseif scramButton and ui.hit(scramButton, touchX, touchY) and
                   currentAlarm and currentAlarm.facilityNodeId then
                scramFacility(currentAlarm.facilityNodeId)
            elseif silenceButton and ui.hit(silenceButton, touchX, touchY) then
                silenceCurrentAlarm()
            elseif ui.hit(dashboardButtons.reactors, touchX, touchY) then openFacility("reactors")
            elseif ui.hit(dashboardButtons.turbines, touchX, touchY) then openFacility("turbines")
            elseif ui.hit(dashboardButtons.storage, touchX, touchY) then openFacility("storage")
            elseif ui.hit(dashboardButtons.control, touchX, touchY) then controlView()
            elseif ui.hit(dashboardButtons.settings, touchX, touchY) then settings()
            elseif ui.hit(dashboardButtons.graphical, touchX, touchY) then return "graphical"
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

    while true do
        local result = graphicalView()
        if result == "quit" then
            ui.prepare()
            display.stop()
            return
        end
        result = advancedDashboard()
        if result == "quit" then
            ui.prepare()
            display.stop()
            return
        end
    end
end

return mainframe
]=],

    ["mainframe/manual_control.lua"] = [=[
local manual = {}

-- @section MANUAL AUTHORITY SAFETY
function manual.minimumReserve(storages)
    local minimum
    for _, storage in ipairs(storages or {}) do
        local percent = tonumber(storage.percent)
        if storage.telemetryOk ~= false and percent then
            minimum = minimum and math.min(minimum, percent) or percent
        end
    end
    return minimum
end

function manual.newSafetyState()
    return { armed = false }
end

local function activateDevices(devices, setActive, kind)
    if type(setActive) ~= "function" then
        return false, { tostring(kind or "Device") .. " activation writer is unavailable" }
    end
    local errors = {}
    for _, device in ipairs(devices or {}) do
        local ok, _, reason = setActive(device, true)
        if not ok then
            errors[#errors + 1] = tostring(device.name or string.lower(kind or "device")) ..
                ": " .. tostring(reason or "activation rejected")
        end
    end
    return #errors == 0, errors
end

function manual.activateReactors(reactors, setActive)
    return activateDevices(reactors, setActive, "Reactor")
end

function manual.activateTurbines(turbines, setActive)
    return activateDevices(turbines, setActive, "Turbine")
end

function manual.shouldFailover(state, storages, threshold)
    state = type(state) == "table" and state or manual.newSafetyState()
    local reserve = manual.minimumReserve(storages)
    threshold = tonumber(threshold) or 2

    -- Manual control is also the recovery path for an already depleted grid.
    -- Do not immediately eject the operator when manual authority begins below
    -- the threshold. Arm the failover only after this session has first reached
    -- a safe reserve, then protect against a subsequent fall below it.
    if reserve ~= nil and reserve >= threshold then state.armed = true end
    return state.armed == true and reserve ~= nil and reserve < threshold,
        reserve, state.armed == true
end

return manual
]=],

    ["mainframe/reactor_governor.lua"] = [=[
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

local function evaluatePower(memory, reactor, control, context)
    local name = tostring(reactor.name or "unknown")
    local previous = memory.reactors[name] or {}
    control.powerReactorProfiles = control.powerReactorProfiles or {}
    local profile = control.powerReactorProfiles[name]
    local production = tonumber(reactor.energyProduction)

    if context.commissioning == true then
        local reserve = tonumber(context.powerReserve)
        if reserve == nil then
            local result = hold("WAITING FOR STORAGE TELEMETRY",
                "Power-reactor commissioning requires a trusted external storage buffer")
            result.managed = true
            result.currentActive = reactor.active
            result.recommendedActive = false
            result.activeChange = reactor.active == true
            result.action = result.activeChange and "STOP REACTOR" or "HOLD"
            return result
        elseif reserve >= (tonumber(control.storageHigh) or 85) then
            local result = hold("WAITING FOR STORAGE CAPACITY",
                ("Commissioning power reactor %d of %d is paused while storage is full"):
                    format(context.commissioningIndex or 1,
                        context.commissioningTotal or 1))
            result.managed = true
            result.currentActive = reactor.active
            result.recommendedActive = false
            result.activeChange = reactor.active == true
            result.action = result.activeChange and "STOP REACTOR" or "HOLD"
            return result
        elseif reactor.active == false then
            local result = hold("CALIBRATING", ("Commissioning power reactor %d of %d; starting output test"):
                format(context.commissioningIndex or 1, context.commissioningTotal or 1))
            result.managed, result.currentActive = true, false
            result.recommendedActive, result.activeChange = true, true
            return result
        elseif reactor.active ~= true then
            return hold("CALIBRATION FAILED", "Power-reactor active state is unavailable", false)
        elseif production == nil then
            return hold("CALIBRATION FAILED", "Power-production telemetry is unavailable", false)
        end

        local wanted = math.max(3, math.floor(tonumber(
            control.powerReactorCalibrationSamples) or 10))
        previous.powerSamples = previous.powerSamples or {}
        previous.powerSamples[#previous.powerSamples + 1] = math.max(0, production)
        while #previous.powerSamples > wanted do table.remove(previous.powerSamples, 1) end
        local maximum = 0
        for _, sample in ipairs(previous.powerSamples) do maximum = math.max(maximum, sample) end
        memory.reactors[name] = previous
        if #previous.powerSamples < wanted then
            local result = hold("CALIBRATING", ("Commissioning power reactor %d of %d; collecting output %d/%d"):
                format(context.commissioningIndex or 1,
                    context.commissioningTotal or 1, #previous.powerSamples, wanted))
            result.managed = true
            result.powerProduction = production
            return result
        elseif maximum <= 0 then
            memory.commissioningFailures = memory.commissioningFailures or {}
            memory.commissioningFailures[name] =
                "No output observed; storage may be full or the reactor may be disconnected"
            return hold("CALIBRATION FAILED", memory.commissioningFailures[name], false)
        end

        control.powerReactorProfiles[name] = {
            maximumPower = round(maximum, 1),
            updatedAt = tonumber(context.now) or 0,
        }
        memory.profileDirty = true
        previous.powerSamples = nil
        local result = hold("CALIBRATION COMPLETE",
            ("Learned maximum %.0f FE/t; placing reactor in standby"):format(maximum))
        result.managed, result.currentActive = true, true
        result.recommendedActive, result.activeChange = false, true
        result.maximumPower, result.powerProduction = maximum, production
        return result
    end

    if type(profile) ~= "table" then
        local result = hold("QUEUED", "Waiting for sequential reactor commissioning")
        result.managed = true
        return result
    end
    local wantedActive = context.powerDispatched == true
    local result = hold(wantedActive and "ACTIVE" or "READY / STANDBY",
        wantedActive and "Storage demand assigned to this power reactor" or
            "Calibrated power reactor is not currently required")
    result.managed = true
    result.currentActive = reactor.active
    result.recommendedActive = wantedActive
    result.activeChange = reactor.active ~= wantedActive
    result.action = result.activeChange and
        (wantedActive and "START REACTOR" or "STOP REACTOR") or "HOLD"
    result.maximumPower = tonumber(profile.maximumPower)
    result.powerProduction = production
    result.targetPower = tonumber(context.powerDemand) or 0
    result.dispatchRequested = wantedActive
    return result
end

-- @section STEAM DEMAND AND SOURCE STATUS
function governor.steamDemand(turbines, control)
    if #(turbines or {}) == 0 then
        return nil, 0, "No turbine telemetry is available"
    end
    control = control or {}
    local total, active = 0, 0
    for _, turbine in ipairs(turbines or {}) do
        if turbine.active == true and
           (turbine.dispatchRequested == nil or turbine.dispatchRequested == true or
            (tonumber(turbine.requestedSteam) or 0) > 0) then
            if turbine.error then
                return nil, active, "Active turbine telemetry is unavailable"
            end
            if turbine.governor and turbine.governor.trusted == false then
                return nil, active, "Active turbine telemetry is untrusted"
            end
            local profile = (control.turbineProfiles or {})[tostring(turbine.name)]
            local requested = tonumber(turbine.requestedSteam) or
                (profile and tonumber(profile.flowLimit)) or
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
    end
    local required = math.max(0, tonumber(demand) or 0)
    local production, bufferPercent, assigned, prepared = 0, nil, 0, true
    local wantedSamples = math.max(3,
        math.floor(tonumber((control or {}).reactorSteamAverageSamples) or 10))
    for _, reactor in ipairs(sources) do
        local plan = reactor.governor or {}
        local requested = tonumber(plan.requestedSteam)
        if requested == nil and #sources == 1 then requested = required end
        if (requested or 0) > 0 and
           plan.recalibrating ~= true then
            assigned = assigned + 1
            production = production +
                (tonumber(plan.averageSteamProduction) or 0)
            local buffer = tonumber(reactor.hotFluidPercent)
            if buffer then bufferPercent = bufferPercent and
                math.min(bufferPercent, buffer) or buffer end
            if reactor.active ~= true or plan.trusted == false or
               (tonumber(plan.averageSteamSamples) or 0) < wantedSamples then
                prepared = false
            end
        end
    end
    local ratio = clamp(tonumber((control or {}).calibrationSteamRatio) or 0.98,
        0.1, 1)
    local ready = required <= 0 or
        (assigned > 0 and prepared and production >= required * ratio)
    local reason
    if assigned == 0 and required > 0 then
        reason = "Dispatching calibrated steam capacity"
    elseif not prepared then
        reason = ("Preparing %d assigned steam reactor%s"):
            format(assigned, assigned == 1 and "" or "s")
    elseif not ready then
        reason = ("Reactor fleet supplying %.0f of %.0f mB/t"):
            format(production, required)
    else
        reason = ("Reactor fleet supplying %.0f mB/t for %.0f mB/t demand"):
            format(production, required)
    end
    return {
        managed = true,
        ready = ready,
        state = ready and "READY" or "PREPARING",
        reason = reason,
        reactors = assigned,
        demand = required,
        production = production,
        bufferPercent = bufferPercent,
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
        result = evaluatePower(memory, reactor, control, context)
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
            local profile = (control.reactorProfiles or {})[name]
            result = hold(type(profile) == "table" and "READY / STANDBY" or "OFFLINE",
                type(profile) == "table" and
                    "Calibrated steam reactor is not currently required" or
                    "No turbine demand requires this reactor")
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
            -- Use a wider threshold for issuing a new physical rod command than
            -- for deciding whether telemetry is stable. Without this hysteresis,
            -- a learned reactor can alternate between two adjacent rod settings:
            -- each tiny correction invalidates the rolling average, the next
            -- completed average reverses it, and calibration never finishes.
            local commandDeadband = previous.recalibrating == true and deadband or
                math.max(deadband, target * 0.025)
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

                if production < target - commandDeadband then
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
                elseif production > target + commandDeadband then
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
                steamCommandDeadband = commandDeadband,
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
            if requestedSteam <= 0 and type(profile) == "table" and
               previous.recalibrating ~= true and exposure <= 0.005 then
                result.state = "READY / STANDBY"
                result.action = "STOP REACTOR"
                result.reason = "Calibration complete; no steam demand requires this reactor"
                result.currentActive = true
                result.recommendedActive = false
                result.activeChange = true
            end
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
    memory.commissioningOrder = memory.commissioningOrder or {}
    memory.commissioningDone = memory.commissioningDone or {}
    memory.commissioningFailures = memory.commissioningFailures or {}
    control.reactorProfiles = control.reactorProfiles or {}
    control.powerReactorProfiles = control.powerReactorProfiles or {}
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
    local known = {}
    for _, reactor in ipairs(reactors or {}) do
        local name = tostring(reactor.name)
        known[name] = reactor
        local profile = reactor.mode == "steam" and control.reactorProfiles[name] or
            reactor.mode == "power" and control.powerReactorProfiles[name] or nil
        local queued = false
        for _, queuedName in ipairs(memory.commissioningOrder) do
            if queuedName == name then queued = true break end
        end
        if not reactor.error and (reactor.mode == "steam" or reactor.mode == "power") and
           type(profile) ~= "table" and not queued and
           not memory.commissioningFailures[name] then
            memory.commissioningOrder[#memory.commissioningOrder + 1] = name
        end
    end
    for _, name in ipairs(memory.commissioningOrder) do
        local reactor = known[name]
        local profile = reactor and (reactor.mode == "steam" and
            control.reactorProfiles[name] or reactor.mode == "power" and
            control.powerReactorProfiles[name]) or nil
        if type(profile) == "table" or memory.commissioningFailures[name] or not reactor then
            memory.commissioningDone[name] = true
        end
    end
    local commissioningName, completed = nil, 0
    local commissioningPending = {}
    for _, name in ipairs(memory.commissioningOrder) do
        if memory.commissioningDone[name] then completed = completed + 1
        else
            commissioningPending[name] = true
            if not commissioningName then commissioningName = name end
        end
    end
    local commissioningTotal = #memory.commissioningOrder
    if commissioningName then
        local unit = known[commissioningName]
        local previous = memory.reactors[commissioningName] or {}
        if unit and unit.mode == "steam" and previous.recalibrating ~= true then
            governor.beginRecalibration(memory, control, commissioningName)
        end
    elseif commissioningTotal > 0 then
        memory.commissioningOrder, memory.commissioningDone = {}, {}
        commissioningTotal, completed = 0, 0
    end

    if demand == nil and activeTurbines == 0 then demand, demandError = 0, nil end

    local reserveMargin = math.max(0, math.min(0.25,
        tonumber(control.reactorSteamReserveMargin) or 0.15))
    local remainingSteam = tonumber(demand)
    local steamAllocation, steamSources = {}, {}
    for _, reactor in ipairs(reactors or {}) do
        local profile = control.reactorProfiles[tostring(reactor.name)]
        if reactor.mode == "steam" and type(profile) == "table" and
           tostring(reactor.name) ~= commissioningName then
            steamSources[#steamSources + 1] = reactor
        end
    end
    table.sort(steamSources, function(a, b)
        if a.active ~= b.active then return a.active == true end
        local ap = control.reactorProfiles[tostring(a.name)] or {}
        local bp = control.reactorProfiles[tostring(b.name)] or {}
        return (tonumber(ap.learnedMaximumSteam) or math.huge) <
            (tonumber(bp.learnedMaximumSteam) or math.huge)
    end)
    if remainingSteam then
        for index, reactor in ipairs(steamSources) do
            local profile = control.reactorProfiles[tostring(reactor.name)] or {}
            local capacity = tonumber(profile.learnedMaximumSteam) or
                tonumber(profile.steam) or 0
            local available = index == #steamSources and remainingSteam or
                (capacity > 0 and capacity / (1 + reserveMargin) or remainingSteam)
            local assigned = math.min(math.max(0, remainingSteam), available)
            steamAllocation[tostring(reactor.name)] = assigned
            remainingSteam = math.max(0, remainingSteam - assigned)
        end
    end

    local powerSources, powerDispatch, powerAssignment = {}, {}, {}
    for _, reactor in ipairs(reactors or {}) do
        local profile = control.powerReactorProfiles[tostring(reactor.name)]
        if reactor.mode == "power" and type(profile) == "table" and
           tostring(reactor.name) ~= commissioningName then
            powerSources[#powerSources + 1] = reactor
        end
    end
    table.sort(powerSources, function(a, b)
        if a.active ~= b.active then return a.active == true end
        local ap = control.powerReactorProfiles[tostring(a.name)] or {}
        local bp = control.powerReactorProfiles[tostring(b.name)] or {}
        return (tonumber(ap.maximumPower) or math.huge) <
            (tonumber(bp.maximumPower) or math.huge)
    end)
    local reserve = tonumber(context and context.powerReserve)
    local storageLow = tonumber(control.storageLow) or 25
    local storageHigh = tonumber(control.storageHigh) or 85
    if reserve ~= nil then
        if memory.powerRechargeActive == nil then
            memory.powerRechargeActive = reserve < storageHigh
        elseif reserve >= storageHigh then
            memory.powerRechargeActive = false
        elseif reserve < storageLow then
            memory.powerRechargeActive = true
        end
    else
        memory.powerRechargeActive = false
    end
    local wantedPower = 0
    if context and context.plantDispatch == true then
        for _, reactor in ipairs(powerSources) do
            local name = tostring(reactor.name)
            if reactor.powerDispatchRequested == true then
                powerDispatch[name] = true
                powerAssignment[name] = tonumber(reactor.powerDispatchTarget) or 0
            end
        end
    elseif memory.powerRechargeActive == true then
        wantedPower = 0
        for _, reactor in ipairs(powerSources) do
            wantedPower = wantedPower +
                (tonumber((control.powerReactorProfiles[tostring(reactor.name)] or {}).maximumPower) or 0)
        end
    end
    if not (context and context.plantDispatch == true) then
        local remainingPower = wantedPower
        for _, reactor in ipairs(powerSources) do
            local maximum = tonumber((control.powerReactorProfiles[tostring(reactor.name)] or {}).maximumPower) or 0
            if remainingPower > 0 then
                local name = tostring(reactor.name)
                powerDispatch[name] = true
                powerAssignment[name] = math.min(remainingPower, maximum > 0 and maximum or remainingPower)
                remainingPower = math.max(0, remainingPower - maximum)
            end
        end
    end

    local present = {}
    for _, reactor in ipairs(reactors or {}) do
        local name = tostring(reactor.name)
        present[name] = true
        local reactorContext = {}
        for key, value in pairs(context or {}) do reactorContext[key] = value end
        reactorContext.demandError = demandError
        reactorContext.turbineBufferPercent = turbineBufferPercent
        reactorContext.turbineBufferTelemetryComplete = activeTurbines > 0 and
            bufferReadings == activeTurbines
        reactorContext.commissioning = name == commissioningName
        reactorContext.commissioningIndex = completed + 1
        reactorContext.commissioningTotal = commissioningTotal
        reactorContext.powerDispatched = powerDispatch[name] == true
        reactorContext.powerDemand = powerAssignment[name] or 0
        local target = steamAllocation[name]
        if name == commissioningName and reactor.mode == "steam" then
            target = math.max(1, tonumber(control.reactorCommissioningSteamTarget) or 1000)
        end
        if name ~= commissioningName and commissioningPending[name] and
           (reactor.mode == "steam" or reactor.mode == "power") then
            reactor.governor = hold("QUEUED", ("Waiting for calibration %d of %d"):
                format(completed + 1, commissioningTotal))
            reactor.governor.managed = true
        else
            reactor.governor = governor.evaluate(memory, reactor, control, reactorContext,
                target, activeTurbines)
        end
        reactor.governor.commissioningIndex = completed + 1
        reactor.governor.commissioningTotal = commissioningTotal
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
]=],

    ["mainframe/turbine_governor.lua"] = [=[
local governor = {}

-- @section COMMON FUNCTIONS
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
    local existing = control.turbineProfiles[name] or {}
    control.turbineProfiles[name] = {
        targetRpm = target,
        learnedRpm = learnedRpm,
        flowLimit = learnedFlow and round(learnedFlow) or nil,
        calibrated = true,
        assistedIdle = existing.assistedIdle == true,
        maximumPower = tonumber(existing.maximumPower),
    }
    memory.profileDirty = true
    return control.turbineProfiles[name]
end

function governor.new()
    return { turbines = {}, profileDirty = false }
end

-- @section CALIBRATION PROFILE STORAGE
function governor.requestSteamPrime(memory)
    memory.turbines = memory.turbines or {}
    for _, previous in pairs(memory.turbines) do
        previous.primeRequested = true
    end
end

function governor.needsSteamPrime(memory, turbines)
    memory.turbines = memory.turbines or {}
    for _, turbine in ipairs(turbines or {}) do
        if turbine.active == true then
            local previous = memory.turbines[tostring(turbine.name or "unknown")]
            if previous == nil or previous.primeRequested == true or
               previous.phase == "CHARGE_STEAM" then
                return true
            end
        end
    end
    return false
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
    memory.turbines[name] = {
        overspeedCount = 0,
        primeRequested = true,
        startRequested = true,
    }
    if hadProfile then memory.profileDirty = true end
    return true
end

-- @section TURBINE GOVERNOR
function governor.evaluate(memory, turbine, control, context)
    control = control or {}
    context = context or {}
    memory.turbines = memory.turbines or {}

    local name = tostring(turbine.name or "unknown")
    local previous = memory.turbines[name] or {
        overspeedCount = 0,
        primeRequested = true,
        startRequested = true,
    }
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
    local bufferReady = math.max(50, math.min(
        tonumber(control.reactorHotFluidHigh) or 85,
        tonumber(control.calibrationBufferReady) or 85))
    local now = tonumber(context.now) or 0

    local result
    if context.maintenance then
        result = hold("MAINTENANCE", "Automatic decisions paused during maintenance")
    elseif context.mainframeId and contains(context.idConflicts, context.mainframeId) then
        result = hold("NO TRUSTED DATA", "Mainframe computer ID is conflicting", false)
    elseif turbine.error then
        result = hold("NO TRUSTED DATA", tostring(turbine.error), false)
    elseif turbine.active == false then
        local dispatchMode = tostring(context.dispatchMode or "COASTING")
        local shouldStart = profile == nil or dispatchMode == "GENERATING" or
            dispatchMode == "ASSISTED IDLE"
        if shouldStart then
            result = {
                mode = "automatic",
                state = "STARTING",
                action = "START TURBINE",
                reason = "Automatic startup requested; activate and verify this turbine",
                trusted = true,
                currentActive = false,
                recommendedActive = true,
                activeChange = true,
                actionSamples = 1,
            }
        else
            result = hold("OFFLINE", shouldStart and "Turbine is not active" or
                "No plant generation or assisted-idle request")
        end
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
        previous.startRequested = false
        local rpm = tonumber(turbine.rotorSpeed)
        local currentFlow = tonumber(turbine.flowRateMax)
        local flowMaximum = tonumber(turbine.flowRateLimit)
        local rpmTrend = previous.rpm and (rpm - previous.rpm) or 0
        local overspeedCount = rpm >= overspeedRpm and (previous.overspeedCount + 1) or 0
        local recommendedFlow = currentFlow
        local recommendedInductor = turbine.inductorEngaged
        local state, action, reason = "STABLE", "HOLD", "Rotor is inside the target deadband"
        local sourceBuffer = tonumber(context.steamSourceBufferPercent)
        local turbineBuffer = tonumber(turbine.inputPercent)
        local canPrimeSteam = context.steamSourceManaged == true and
            sourceBuffer ~= nil and turbineBuffer ~= nil

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

        local function beginInputPhase()
            beginPhase(canPrimeSteam and "CHARGE_STEAM" or "PREFLIGHT")
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
            previous.primeRequested = false
            previous.settleCount, previous.settleSum = 0, 0
            return learned
        end

        if profile then
            if previous.phase == "CHARGE_STEAM" or
               previous.phase == "RESTORE_PROFILE" then
                -- Preserve an active one-shot prime and its guarded flow restore.
            elseif previous.primeRequested == true and canPrimeSteam then
                beginPhase("CHARGE_STEAM")
            else
                previous.primeRequested = false
                previous.phase = "OPERATING"
            end
        elseif previous.phase == nil then
            beginInputPhase()
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
        elseif previous.phase == "CHARGE_STEAM" then
            previous.calibrationError = nil
            previous.fullSteamCount = 0
            previous.lowSteamCount = 0
            previous.settleCount = 0
            previous.settleSum = 0
            recommendedInductor = true
            if not canPrimeSteam then
                previous.primeRequested = false
                if profile then
                    beginPhase("RESTORE_PROFILE")
                    recommendedFlow = tonumber(profile.flowLimit) or currentFlow
                    state = "RESTORING PROFILE"
                    action = turbine.inductorEngaged and "RESTORE FLOW" or
                        "ENGAGE INDUCTOR"
                    reason = "Buffer telemetry unavailable; resume saved turbine profile"
                else
                    beginPhase("PREFLIGHT")
                    state = "CALIBRATION PREFLIGHT"
                    recommendedFlow = flowMaximum
                    action = turbine.inductorEngaged and "MAXIMIZE FLOW" or
                        "ENGAGE INDUCTOR"
                    reason = "Buffer telemetry unavailable; using full-steam preflight"
                end
            elseif sourceBuffer >= bufferReady and turbineBuffer >= bufferReady then
                previous.primeRequested = false
                if profile then
                    beginPhase("RESTORE_PROFILE")
                    recommendedFlow = tonumber(profile.flowLimit) or currentFlow
                    state = "STEAM PRIMED"
                    if turbine.inductorEngaged == false then
                        action = "ENGAGE INDUCTOR"
                    elseif currentFlow ~= recommendedFlow then
                        action = "RESTORE FLOW"
                    else
                        action = "HOLD"
                    end
                    reason = ("Steam buffers primed at reactor %.0f%% / turbine %.0f%%; resume saved flow"):
                        format(sourceBuffer, turbineBuffer)
                else
                    beginPhase("PREFLIGHT")
                    state = "CALIBRATION PREFLIGHT"
                    recommendedFlow = flowMaximum
                    action = turbine.inductorEngaged and "MAXIMIZE FLOW" or
                        "ENGAGE INDUCTOR"
                    reason = ("Steam buffers primed at reactor %.0f%% / turbine %.0f%%; open full flow"):
                        format(sourceBuffer, turbineBuffer)
                end
            elseif context.steamSourceReady ~= true then
                local waitingFlow = profile and tonumber(profile.flowLimit) or flowMaximum
                recommendedFlow = waitingFlow or currentFlow
                state = "WAITING FOR STEAM SOURCE"
                if turbine.inductorEngaged == false then
                    action = "ENGAGE INDUCTOR"
                elseif currentFlow ~= recommendedFlow then
                    action = "RESTORE FLOW"
                else
                    action = "WAIT FOR STEAM SOURCE"
                end
                reason = tostring(context.steamSourceReason or
                    "Preparing managed steam before buffer priming")
            else
                state = "CHARGING STEAM"
                recommendedFlow = profile and tonumber(profile.flowLimit) or flowMaximum
                recommendedFlow = recommendedFlow or currentFlow
                if turbine.inductorEngaged == false then
                    action = "ENGAGE INDUCTOR"
                elseif currentFlow ~= recommendedFlow then
                    action = "RESTORE FLOW"
                else
                    action = "PRIME BUFFERS"
                end
                reason = ("Reactor overproducing to prime buffers to %.0f%%: reactor %.0f%% / turbine %.0f%%"):
                    format(bufferReady, sourceBuffer, turbineBuffer)
            end
        elseif profile and previous.phase == "RESTORE_PROFILE" then
            recommendedInductor = true
            recommendedFlow = tonumber(profile.flowLimit) or currentFlow
            if turbine.inductorEngaged == false then
                state, action = "RESTORING PROFILE", "ENGAGE INDUCTOR"
                reason = "Re-engage generator load before restoring saved steam flow"
            elseif currentFlow ~= recommendedFlow then
                state, action = "RESTORING PROFILE", "RESTORE FLOW"
                reason = ("Restore learned turbine flow at %.0f mB/t"):
                    format(recommendedFlow)
            else
                beginPhase("OPERATING")
                state, action = "STABLE", "HOLD"
                reason = "Steam buffers primed; saved turbine profile restored"
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
            beginInputPhase()
            previous.calibrationError = nil
            previous.fullSteamCount = 0
            previous.lowSteamCount = 0
            recommendedInductor = true
            if canPrimeSteam then
                state = "CHARGING STEAM"
                action = turbine.inductorEngaged and "CLOSE FLOW" or "ENGAGE INDUCTOR"
                reason = "Managed steam restored; recharging buffers before retry"
                recommendedFlow = 0
            else
                state = "CALIBRATION PREFLIGHT"
                action = turbine.inductorEngaged and "VERIFY STEAM" or "ENGAGE INDUCTOR"
                reason = "Managed steam restored; retrying turbine calibration"
                recommendedFlow = flowMaximum
            end
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
        elseif tostring(context.dispatchMode or "GENERATING") ~= "GENERATING" then
            local assisted = tostring(context.dispatchMode) == "ASSISTED IDLE"
            local idleFloor = target * (tonumber(control.assistedIdleRpmRatio) or 0.75)
            recommendedInductor = false
            recommendedFlow = 0
            if assisted and rpm < idleFloor then
                recommendedFlow = math.min(flowMaximum,
                    tonumber(control.assistedIdleFlow) or 250)
                state, action = "IDLE BOOST", "PULSE STEAM"
                reason = ("Assisted idle restoring rotor above %.0f RPM"):format(idleFloor)
            elseif assisted then
                state, action = "ASSISTED IDLE", "COAST"
                reason = ("Warm reserve coasting above %.0f RPM"):format(idleFloor)
            else
                state, action = "COASTING", "COAST"
                reason = "Generation not requested; inductor disengaged and steam closed"
            end
        elseif rpm < target - deadband and turbine.inductorEngaged == false then
            recommendedInductor = false
            recommendedFlow = math.min(flowMaximum,
                tonumber(profile.flowLimit) or flowMaximum)
            state, action = "SPOOLING", "RELEASE LOAD"
            reason = "Generation requested; spool unloaded to the learned target"
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
            dispatchMode = tostring(context.dispatchMode or "GENERATING"),
            assistedIdle = profile and profile.assistedIdle == true or false,
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
    if result.currentActive == nil then result.currentActive = turbine.active end
    if result.recommendedActive == nil then result.recommendedActive = turbine.active end
    result.activeChange = result.recommendedActive ~= nil and
        result.currentActive ~= nil and result.recommendedActive ~= result.currentActive
    if result.currentInductor == nil then result.currentInductor = turbine.inductorEngaged end
    if result.recommendedInductor == nil then result.recommendedInductor = turbine.inductorEngaged end
    result.inductorChange = result.recommendedInductor ~= nil and
        result.currentInductor ~= nil and result.recommendedInductor ~= result.currentInductor
    return result
end

-- @section ACTUATOR APPLICATION
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
    local needsActive = plan.activeChange == true
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
    elseif not needsActive and not needsFlow and not needsInductor then
        plan.actuatorState = "HOLD"
    elseif plan.action ~= "START TURBINE" and not emergency and
           (tonumber(plan.actionSamples) or 0) < commandSamples then
        plan.actuatorState = "VERIFYING"
    elseif type(writers) ~= "table" or
           (needsActive and type(writers.setActive) ~= "function") or
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
        local ok, appliedActive, appliedFlow, appliedInductor, reason =
            true, nil, nil, nil, nil
        if needsActive then
            ok, appliedActive, reason = writers.setActive(
                turbine, plan.recommendedActive)
        end
        if ok and needsInductor then
            ok, appliedInductor, reason = writers.setInductor(turbine, plan.recommendedInductor)
        end
        if ok and needsFlow then
            ok, appliedFlow, reason = writers.setFlowLimit(turbine, proposed)
        end
        if ok then
            previous.lastAppliedAt = now
            if needsActive then
                previous.lastAppliedActive = appliedActive == true
                previous.startRequested = false
                plan.appliedActive = previous.lastAppliedActive
            end
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
            if needsActive then plan.reportedActive = appliedActive end
            if needsFlow then plan.reportedFlow = tonumber(appliedFlow) end
            if needsInductor then plan.reportedInductor = appliedInductor end
        end
    end

    plan.lastAppliedAt = previous.lastAppliedAt
    plan.lastAppliedActive = previous.lastAppliedActive
    plan.lastAppliedFlow = previous.lastAppliedFlow
    plan.lastAppliedInductor = previous.lastAppliedInductor
    memory.turbines[name] = previous
    return plan
end

-- @section MULTI-TURBINE EVALUATION
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
        local turbineContext = {}
        for key, value in pairs(context or {}) do turbineContext[key] = value end
        turbineContext.dispatchMode = turbine.dispatchMode or "GENERATING"
        turbine.governor = governor.evaluate(memory, turbine, control, turbineContext)
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

-- @section REMOTE TERMINAL RUNTIME
function terminal.run(config)
    local display = dofile("/helios/core/display.lua")
    display.start(config)
    local ui = dofile("/helios/core/ui.lua")
    ui.setVersion(config.version)
    local gui = dofile("/helios/core/gui.lua")
    local guiLoader = dofile("/helios/core/gui_loader.lua")
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
    local advanced = false
    local graphicalPage = ({ reactor = "reactors", turbine = "turbines",
        battery = "storage" })[config.display] or "overview"
    local graphicalButtons = {}
    local customRenderer = guiLoader.load(config.ui.renderer, config.version, term.getSize())
    local customState, customButtons = {}, {}

    local function nameOf(rawName, state)
        local aliases = state.aliases or {}
        local alias = aliases[rawName]
        if alias and alias ~= "" then
            if state.showPeripheralNames then return alias .. " [" .. rawName .. "]" end
            return alias
        end
        return rawName or "UNKNOWN"
    end

    -- @section LOCAL ALARMS
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

    -- @section MAINFRAME LINK
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

    -- @section TELEMETRY VIEWS
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

    -- @section READ-ONLY GRAPHICAL VIEWS
    local function graphicalStatus()
        local link = statusLine()
        if link ~= "ONLINE" then return link, link, colors.red end
        if snapshot and snapshot.alarm then
            local level = tonumber(snapshot.alarm.level) or 1
            return level >= 3 and "FAULT" or "WARNING",
                tostring(snapshot.alarm.message), level >= 3 and colors.red or colors.orange
        end
        local control = snapshot and snapshot.control or {}
        for _, reactor in ipairs(snapshot and snapshot.reactors or {}) do
            local state = string.upper(tostring(reactor.governor and reactor.governor.state or ""))
            if string.find(state, "CALIBRAT", 1, true) then
                return "CALIBRATING", nameOf(reactor.name, snapshot), colors.orange
            end
        end
        for _, turbine in ipairs(snapshot and snapshot.turbines or {}) do
            local state = string.upper(tostring(turbine.governor and turbine.governor.state or ""))
            if string.find(state, "CALIBRAT", 1, true) or
               string.find(state, "SPOOL", 1, true) or
               string.find(state, "PRIM", 1, true) then
                return "CALIBRATING", nameOf(turbine.name, snapshot) .. " - " .. state,
                    colors.orange
            end
        end
        if not snapshot then return "STARTING", "SEARCHING FOR MAINFRAME", colors.orange end
        return "READY", string.upper(tostring(control.mode or "automatic")), colors.lime
    end

    local function graphicalHeader(title)
        gui.prepare()
        local width, height = term.getSize()
        gui.text(1, 1, "HELIOS // REMOTE " .. title, colors.yellow)
        local version = "v" .. tostring(config.version)
        gui.text(math.max(1, width - #version + 1), 1, version, colors.yellow)
        local state, detail, colour = graphicalStatus()
        gui.text(1, 2, " " .. state .. " ", colors.black, colour)
        gui.text(#state + 4, 2, detail, colour, colors.black,
            math.max(0, width - #state - 3))
        graphicalButtons = {}
        local x = 1
        graphicalButtons.overview = gui.button(x, 4, "HOME", colors.white,
            graphicalPage == "overview" and colors.gray or colors.black)
        x = graphicalButtons.overview.x2 + 2
        graphicalButtons.reactors = gui.button(x, 4, "REACTORS", colors.red,
            graphicalPage == "reactors" and colors.gray or colors.black)
        x = graphicalButtons.reactors.x2 + 2
        graphicalButtons.turbines = gui.button(x, 4, "TURBINES", colors.cyan,
            graphicalPage == "turbines" and colors.gray or colors.black)
        x = graphicalButtons.turbines.x2 + 2
        graphicalButtons.storage = gui.button(x, 4, "POWER", colors.yellow,
            graphicalPage == "storage" and colors.gray or colors.black)
        graphicalButtons.advanced = gui.button(1, height, "ADVANCED", colors.white, colors.gray)
    end

    local function graphicalOverview()
        graphicalHeader("OVERVIEW")
        local width = select(1, term.getSize())
        if not snapshot then
            gui.text(1, 7, "SEARCHING FOR MAINFRAME", colors.orange)
            return
        end
        local state, detail, colour = graphicalStatus()
        gui.text(1, 6, "SYSTEM READINESS", colors.lightGray)
        gui.text(1, 7, state, colour)
        gui.text(1, 8, detail, colors.white, colors.black, width)
        gui.text(1, 10, ("REACTORS  %d   TURBINES  %d   STORAGE  %d"):format(
            #(snapshot.reactors or {}), #(snapshot.turbines or {}),
            #(snapshot.storages or {})), colors.cyan)
        local stored, capacity = 0, 0
        for _, storage in ipairs(snapshot.storages or {}) do
            stored = stored + (tonumber(storage.stored) or 0)
            capacity = capacity + (tonumber(storage.capacity) or 0)
        end
        local percent = capacity > 0 and stored / capacity * 100 or 0
        gui.text(1, 12, "COMBINED STORAGE", colors.lightGray)
        gui.progress(1, 13, math.max(10, width - 8), percent,
            percent < 20 and colors.orange or colors.lime, colors.gray)
        gui.text(math.max(1, width - 6), 13, ("%5.1f%%"):format(percent), colors.white)
        gui.text(1, 15, "REMOTE MONITORING - READ ONLY", colors.gray)
    end

    local function graphicalReactors()
        graphicalHeader("REACTORS")
        local list = snapshot and snapshot.reactors or {}
        local width = select(1, term.getSize())
        if #list == 0 then gui.text(1, 7, "NO REACTORS REPORTED", colors.orange) return end
        selected = math.max(1, math.min(selected, #list))
        local reactor = list[selected]
        local output = reactor.mode == "steam" and reactor.steamProduction or reactor.energyProduction
        local target = reactor.mode == "steam" and
            tonumber(reactor.governor and reactor.governor.targetSteam) or
            tonumber(reactor.governor and reactor.governor.targetPower)
        local profile = reactor.mode == "steam" and
            (((snapshot.control or {}).reactorProfiles or {})[reactor.name] or
                (reactor.governor and reactor.governor.learnedProfile)) or
            (((snapshot.control or {}).powerReactorProfiles or {})[reactor.name])
        local maximum = profile and (reactor.mode == "steam" and
            tonumber(profile.learnedMaximumSteam) or tonumber(profile.maximumPower)) or nil
        local scale = maximum and maximum > 0 and maximum or
            math.max(1, tonumber(target) or 0, tonumber(output) or 0)
        local outputPercent = maximum and maximum > 0 and
            math.min(100, (tonumber(output) or 0) / scale * 100) or
            tonumber(reactor.energyPercent) or 0
        local barWidth = math.max(10, width - 10)
        gui.text(1, 6, ("%d/%d  %s"):format(selected, #list,
            nameOf(reactor.name, snapshot)), colors.cyan, colors.black, width)
        gui.text(1, 7, ("TYPE %-8s  %s"):format(string.upper(reactor.mode or "unknown"),
            reactor.active == true and "ACTIVE" or "OFFLINE"),
            reactor.active == true and colors.lime or colors.orange)
        local unit = reactor.mode == "steam" and "mB/t" or "FE/t"
        gui.text(1, 8,
            maximum and ("OUTPUT %.0f / %.0f %s"):format(output or 0, maximum, unit) or
                ("OUTPUT %.0f / LEARNING"):format(output or 0),
            colors.lightGray, colors.black, width)
        if target then
            gui.text(1, 9, ("DEMAND %.0f %s"):format(target, unit), colors.yellow)
        end
        gui.progress(1, 10, barWidth, outputPercent,
            reactor.active == true and colors.lime or colors.orange, colors.gray)
        if target and maximum and maximum > 0 then
            local marker = math.floor(math.max(0, math.min(100,
                target / maximum * 100)) / 100 * (barWidth - 1))
            gui.text(1 + marker, 10, "|", colors.yellow)
        elseif reactor.mode ~= "steam" then
            gui.text(math.max(1, width - 8), 10,
                output and ("%.0f"):format(output) or "N/A")
        end
        gui.text(1, 12, "FUEL", colors.lightGray)
        gui.progress(1, 13, math.max(10, width - 10), reactor.fuelPercent or 0,
            (reactor.fuelPercent or 0) < 20 and colors.orange or colors.lime, colors.gray)
        gui.text(math.max(1, width - 8), 13,
            reactor.fuelPercent and ("%6.1f%%"):format(reactor.fuelPercent) or "N/A")
        local buffer = reactor.mode == "steam" and reactor.hotFluidPercent or reactor.energyPercent
        gui.text(1, 15, ("CYANITE %s mB"):format(
            reactor.waste and ("%.0f"):format(reactor.waste) or "N/A"), colors.cyan)
        gui.text(math.max(24, width - 16), 15, ("BUFFER %s"):format(
            buffer and ("%.1f%%"):format(buffer) or "N/A"), colors.cyan)
        graphicalButtons.previous = gui.button(1, 17, "<", colors.cyan, colors.black)
        graphicalButtons.next = gui.button(15, 17, ">", colors.cyan, colors.black)
    end

    local function graphicalTurbines()
        graphicalHeader("TURBINES")
        local list = snapshot and snapshot.turbines or {}
        local width = select(1, term.getSize())
        if #list == 0 then gui.text(1, 7, "NO TURBINES REPORTED", colors.orange) return end
        selected = math.max(1, math.min(selected, #list))
        local turbine = list[selected]
        local rpm = tonumber(turbine.rotorSpeed) or 0
        gui.text(1, 6, ("%d/%d  %s"):format(selected, #list,
            nameOf(turbine.name, snapshot)), colors.cyan, colors.black, width)
        gui.text(1, 7, turbine.active == true and "ACTIVE" or "OFFLINE",
            turbine.active == true and colors.lime or colors.orange)
        gui.text(1, 9, ("ROTOR %.1f RPM"):format(rpm), rpm >= 1900 and colors.red or colors.white)
        local gaugeWidth = math.max(20, width - 1)
        gui.rpmGauge(1, 10, gaugeWidth, rpm)
        local lowLabel, highLabel = "[900 RPM]", "[1800 RPM]"
        gui.text(math.max(1, math.floor(900 / 2100 * (gaugeWidth - 1)) - 3),
            11, lowLabel, colors.lime)
        gui.text(math.min(width - #highLabel + 1,
            math.floor(1800 / 2100 * (gaugeWidth - 1)) - 3), 11, highLabel, colors.lime)
        gui.text(1, 13, "STATE " .. tostring(turbine.governor and turbine.governor.state or "WAITING"))
        gui.text(1, 14, "OUTPUT " .. powerFormat.power(turbine.energyProduction,
            snapshot.power, true), colors.cyan)
        graphicalButtons.previous = gui.button(1, 16, "<", colors.cyan, colors.black)
        graphicalButtons.next = gui.button(15, 16, ">", colors.cyan, colors.black)
    end

    local function graphicalStorage()
        graphicalHeader("POWER")
        local list = snapshot and snapshot.storages or {}
        local width = select(1, term.getSize())
        if #list == 0 then gui.text(1, 7, "NO STORAGE REPORTED", colors.orange) return end
        selected = math.max(1, math.min(selected, #list))
        local storage = list[selected]
        gui.text(1, 6, ("%d/%d  %s"):format(selected, #list,
            nameOf(storage.name, snapshot)), colors.cyan, colors.black, width)
        gui.text(1, 8, "CAPACITY", colors.lightGray)
        gui.progress(1, 9, math.max(10, width - 10), storage.percent or 0,
            (storage.percent or 0) < 20 and colors.orange or colors.lime, colors.gray)
        gui.text(math.max(1, width - 8), 9,
            storage.percent and ("%6.1f%%"):format(storage.percent) or "N/A")
        gui.text(1, 11, "STORED  " .. powerFormat.power(storage.stored, snapshot.power, false))
        gui.text(1, 12, "FILL    " .. powerFormat.power(storage.input, snapshot.power, true), colors.lime)
        gui.text(1, 13, "DRAW    " .. powerFormat.power(storage.output, snapshot.power, true), colors.orange)
        gui.text(1, 14, "STATE   " .. tostring(storage.state or "UNKNOWN"), colors.cyan)
        graphicalButtons.previous = gui.button(1, 16, "<", colors.cyan, colors.black)
        graphicalButtons.next = gui.button(15, 16, ">", colors.cyan, colors.black)
    end

    local function renderGraphical()
        if graphicalPage == "reactors" then graphicalReactors()
        elseif graphicalPage == "turbines" then graphicalTurbines()
        elseif graphicalPage == "storage" then graphicalStorage()
        else graphicalOverview() end
    end

    -- @section EVENT LOOP AND RENDERING
    local function renderAdvanced()
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

    local function render()
        if advanced then
            renderAdvanced()
        elseif customRenderer and snapshot then
            local ok, result = pcall(customRenderer.render, snapshot, customState, {
                gui = gui, powerFormat = powerFormat,
            })
            if ok then customButtons = result or {} else customRenderer = nil; renderGraphical() end
        else
            renderGraphical()
        end
    end

    sendHello()
    heartbeatTimer = os.startTimer(1)
    render()
    while true do
        local event, value, message, protocol = os.pullEvent()
        if customRenderer and snapshot and not advanced then
            local ok, action = pcall(customRenderer.handle, customState, customButtons,
                event, value, message, protocol, { eventPoint = ui.eventPoint, hit = gui.hit })
            if not ok then customRenderer = nil
            elseif action == "advanced" then advanced = true end
        end
        if event == "key" and value == keys.q then
            ui.prepare()
            display.stop()
            return
        elseif event == "key" and value == keys.a then
            advanced = true
            render()
        elseif event == "key" and value == keys.b and advanced then
            advanced = false
            render()
        elseif event == "key" and value == keys.v and not advanced then
            graphicalPage, selected = "reactors", 1
            render()
        elseif event == "key" and value == keys.g and not advanced then
            graphicalPage, selected = "turbines", 1
            render()
        elseif event == "key" and value == keys.e and not advanced then
            graphicalPage, selected = "storage", 1
            render()
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
        elseif event == "monitor_touch" or event == "mouse_click" then
            local x, y = message, protocol
            if not advanced then
                if gui.hit(graphicalButtons.overview, x, y) then graphicalPage, selected = "overview", 1
                elseif gui.hit(graphicalButtons.reactors, x, y) then graphicalPage, selected = "reactors", 1
                elseif gui.hit(graphicalButtons.turbines, x, y) then graphicalPage, selected = "turbines", 1
                elseif gui.hit(graphicalButtons.storage, x, y) then graphicalPage, selected = "storage", 1
                elseif gui.hit(graphicalButtons.advanced, x, y) then advanced = true
                elseif gui.hit(graphicalButtons.previous, x, y) then selected = math.max(1, selected - 1)
                elseif gui.hit(graphicalButtons.next, x, y) then selected = selected + 1 end
            elseif ui.hit(previousButton, x, y) then selected = math.max(1, selected - 1)
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

    ["tools/discovery_probe.lua"] = [=[
-- HELIOS Discovery Probe
-- Standalone, read-only peripheral inventory for CC:Tweaked.
-- Run with: wget run <raw GitHub URL>

local VERSION = "0.1.0"

local function contains(value, fragment)
    return string.find(string.lower(tostring(value or "")), fragment, 1, true) ~= nil
end

local function methodSet(methods)
    local set = {}
    for _, method in ipairs(methods or {}) do set[method] = true end
    return set
end

local function hasAny(methods, names)
    for _, name in ipairs(names) do
        if methods[name] then return true end
    end
    return false
end

local function classify(name, types, methods)
    local available = methodSet(methods)
    local reactor = contains(name, "reactor")
    local turbine = contains(name, "turbine")
    local induction = contains(name, "inductionport") or contains(name, "induction_port")
    for _, peripheralType in ipairs(types) do
        reactor = reactor or contains(peripheralType, "reactor")
        turbine = turbine or contains(peripheralType, "turbine")
        induction = induction or contains(peripheralType, "inductionport") or
            contains(peripheralType, "induction_port")
    end
    -- "BigReactors-Turbine" includes the word "reactor", so turbines must
    -- win whenever both identity checks match.
    if turbine then
        local controllable = hasAny(available, { "setActive", "setFluidFlowRateMax", "setInductorEngaged" })
        local readable = hasAny(available, { "getRotorSpeed", "getEnergyProducedLastTick", "getFluidFlowRate" })
        return "TURBINE", controllable and readable and "MANAGEABLE" or "TELEMETRY / API CHECK"
    end
    if reactor then
        local controllable = hasAny(available, { "setActive", "setControlRodLevel", "setAllControlRodLevels" })
        local readable = hasAny(available, { "getActive", "active", "getEnergyProducedLastTick", "getFuelFilledPercentage" })
        return "REACTOR", controllable and readable and "MANAGEABLE" or "TELEMETRY / API CHECK"
    end
    if induction and available.getEnergy and available.getMaxEnergy then
        return "INDUCTION STORAGE", "MANAGEABLE"
    end
    if (available.getEnergyStored and available.getMaxEnergyStored) or
       (available.getEnergy and available.getMaxEnergy) or
       (available.getEnergy and available.getEnergyCapacity) or
       (available.getStoredEnergy and available.getEnergyCapacity) or
       (available.getStored and available.getCapacity) then
        return "ENERGY STORAGE", "MANAGEABLE"
    end
    for _, peripheralType in ipairs(types) do
        if peripheralType == "monitor" then return "MONITOR", "DISPLAY" end
        if peripheralType == "modem" then return "MODEM", "NETWORK" end
    end
    return "UNRECOGNISED", "INSPECT"
end

local names = peripheral.getNames()
table.sort(names)
local report, counts = {}, { reactor = 0, turbine = 0, storage = 0, unknown = 0 }
local function emit(line)
    report[#report + 1] = line
end

emit("HELIOS DISCOVERY PROBE v" .. VERSION)
emit("Read-only inventory - no device settings will be changed")
emit(string.rep("-", 46))
for _, name in ipairs(names) do
    local types = { peripheral.getType(name) }
    local methods = peripheral.getMethods(name) or {}
    table.sort(types)
    table.sort(methods)
    local category, status = classify(name, types, methods)
    if category == "REACTOR" then counts.reactor = counts.reactor + 1
    elseif category == "TURBINE" then counts.turbine = counts.turbine + 1
    elseif contains(category, "STORAGE") then counts.storage = counts.storage + 1
    elseif category == "UNRECOGNISED" then counts.unknown = counts.unknown + 1 end
    emit(("[%s] %s"):format(status, name))
    emit("  Class: " .. category)
    emit("  Types: " .. (#types > 0 and table.concat(types, ", ") or "unreported"))
    if status ~= "MANAGEABLE" then
        emit("  Methods: " .. (#methods > 0 and table.concat(methods, ", ") or "none reported"))
    end
end
emit(string.rep("-", 46))
emit(("Summary: %d reactor(s), %d turbine(s), %d storage device(s), %d unrecognised"):format(
    counts.reactor, counts.turbine, counts.storage, counts.unknown))
emit("Result: HELIOS can manage devices marked MANAGEABLE after installation.")
emit("Use the detailed method list on API CHECK / INSPECT devices when reporting compatibility.")

local fileName = "helios-discovery-report.txt"
local handle = fs.open(fileName, "w")
if handle then
    handle.write(table.concat(report, "\n") .. "\n")
    handle.close()
end

-- CC:Tweaked terminals do not retain a normal scrollback buffer.  Use a small
-- pager with an explicit skip action: S keeps the saved report but jumps
-- straight to its final summary.
local width, height = term.getSize()
local lines = {}
for _, line in ipairs(report) do
    line = tostring(line)
    if #line == 0 then
        lines[#lines + 1] = ""
    else
        for start = 1, #line, width do
            lines[#lines + 1] = string.sub(line, start, start + width - 1)
        end
    end
end

local pageSize = math.max(1, height - 2)
local function drawPage(start)
    term.clear()
    term.setCursorPos(1, 1)
    for index = start, math.min(#lines, start + pageSize - 1) do print(lines[index]) end
end

local start = 1
while start <= #lines do
    drawPage(start)
    local lastPage = start + pageSize > #lines
    if lastPage then
        print("[Any key] finish   [S] saved report only")
    else
        print("[Any key] next page   [S] skip to saved report")
    end
    local _, key = os.pullEvent("key")
    if key == keys.s then
        term.clear()
        term.setCursorPos(1, 1)
        print("Discovery display skipped.")
        print("Full report saved to " .. fileName)
        print(report[#report - 1] or "")
        print(report[#report] or "")
        break
    elseif lastPage then
        break
    end
    start = start + pageSize
end
]=],

    ["draconic/controller.lua"] = [=[
-- HELIOS Draconic Guardian v1.1.0-alpha.10
-- Dedicated local Draconic controller. Never install this on the normal
-- HELIOS modem bus: it owns exactly one reactor component and its two gates.

local FIELD_TARGET, FIELD_EMERGENCY = 50, 15
local MAX_TEMPERATURE, MINIMUM_FUEL = 8000, 10
-- Draconic's peripheral telemetry reports live generation but not a safe
-- maximum output. Establish one by proving progressively larger exports.
-- The calibration may approach the real limit, but never crosses the 15%
-- hard shutdown interlock: 17% is the operating-edge cutoff.
local COMMISSION_START_FLOW, COMMISSION_SAMPLES = 50000, 20
local COMMISSION_FIELD_FLOOR, COMMISSION_TEMP_LIMIT = 17, 5000
local COMMISSION_STEP_RATIO, COMMISSION_MIN_STEP = 1.25, 50000
local COMMISSION_SHORTFALL_SAMPLES = 20
-- A cool reactor ramps up to a new export request over several seconds.  This
-- is a settling period, not evidence that the output path has reached its
-- ceiling, so do not score it as a failed sample.
local COMMISSION_SETTLE_SAMPLES = 120
local FRACTION = { OFF = 0, MIN = .25, MED = .50, MAX = 1 }
local PRESET_RAMP_STEP = 50000
local MANUAL_GATE_FINE_STEP, MANUAL_GATE_SMALL_STEP = 1000, 10000
local MANUAL_GATE_STEP, MANUAL_GATE_LARGE_STEP = 100000, 1000000
local GUARDIAN_VERSION = "1.1.0-alpha.10"
local PROFILER_REQUEST_CHANNEL, PROFILER_TELEMETRY_CHANNEL = 43120, 43121
local SETTINGS = fs.exists("/helios") and "/helios/data/draconic_guardian.lua" or
  ".helios-draconic-guardian.lua"
local facilityNetwork,facilityProtocol,facilityIdentity,facilitySequence
local facilityConnected,facilityLastWelcome=false,nil
local facilityCollectorId,facilityCollectorRole,facilityCollectorPriority=nil,nil,-1
local facilityCollectorLeaseUntil=0
local facilitySiteId="default"
if fs.exists("/helios/config.lua") then
  local okConfig,guardianConfig=pcall(dofile,"/helios/config.lua")
  if okConfig and type(guardianConfig)=="table" and type(guardianConfig.network)=="table" and
     type(guardianConfig.network.siteId)=="string" and guardianConfig.network.siteId~="" then
    facilitySiteId=guardianConfig.network.siteId
  end
end
if fs.exists("/helios/core/network.lua") and fs.exists("/helios/core/facility_protocol.lua") then
  local okNetwork,loadedNetwork=pcall(dofile,"/helios/core/network.lua")
  local okProtocol,loadedProtocol=pcall(dofile,"/helios/core/facility_protocol.lua")
  if okNetwork and okProtocol then
    facilityNetwork,facilityProtocol=loadedNetwork,loadedProtocol
    facilityNetwork.openAll()
    facilityIdentity=facilityProtocol.identity({
      nodeId="guardian:draconic-"..tostring(os.getComputerID()),
      sessionId=facilityNetwork.sessionId("guardian"),role="guardian",
      software="draconic_guardian",softwareVersion=GUARDIAN_VERSION,
    })
    facilitySequence=0
  end
end

local function hasType(name, fragment)
  for _, t in ipairs({ peripheral.getType(name) }) do
    if string.find(string.lower(tostring(t or "")), fragment, 1, true) then return true end
  end
  return false
end
local function sort(t) table.sort(t, function(a,b) return tostring(a) < tostring(b) end); return t end
local function localSides() local r = {}; for _, s in ipairs(rs.getSides()) do if peripheral.isPresent(s) then r[s] = true end end; return r end
local function inspect()
  local p, localReactors, remoteReactors, directGates, exportGates, modems, monitors = localSides(), {}, {}, {}, {}, {}, {}
  for side in pairs(p) do
    if hasType(side, "draconic_reactor") then localReactors[#localReactors+1] = side end
    if hasType(side, "flow_gate") then
      directGates[#directGates+1] = side
      -- Fixed Guardian topology: one local Flux Gate on LEFT or RIGHT is the
      -- reactor's export throttle. It never provides containment power.
      if side == "left" or side == "right" then exportGates[#exportGates+1] = side end
    end
    if hasType(side, "modem") then modems[#modems+1] = side end
    if hasType(side, "monitor") then monitors[#monitors+1] = side end
  end
  local inputs = {}; for _, n in ipairs(peripheral.getNames()) do
    if not p[n] then
      if hasType(n,"draconic_reactor") then remoteReactors[#remoteReactors+1]=n end
      if hasType(n,"flow_gate") then inputs[#inputs+1]=n end
    end
  end
  local reactors={};for _,n in ipairs(localReactors) do reactors[#reactors+1]=n end;for _,n in ipairs(remoteReactors) do reactors[#reactors+1]=n end
  sort(reactors);sort(directGates);sort(exportGates);sort(modems);sort(monitors);sort(inputs)
  local why={}; if #reactors~=1 then why[#why+1]="Require exactly one reactor component (direct or wired)" end
  if #exportGates~=1 then why[#why+1]="Require exactly one local export gate on LEFT or RIGHT (never both)" end
  if #directGates~=#exportGates then why[#why+1]="No other Flux Gate may be directly attached to the Guardian" end
  if #modems<1 then why[#why+1]="Require one local wired modem/peripheral hub" end
  -- The sole remote gate reachable through the wired modem is always the
  -- injector-feed gate. Guardian uses it only to sustain field strength.
  if #inputs~=1 then why[#why+1]="Require exactly one modem-connected injector field gate" end
  return {ready=#why==0,reasons=why,reactor=reactors[1],output=exportGates[1],modem=modems[1],monitor=monitors[1],input=inputs[1]}
end
local function call(n,m,...)
  if not n then return nil,"missing" end
  local ok,v=pcall(peripheral.call,n,m,...); if not ok then return nil,tostring(v) end; return v
end
local gateApplied,gateCommands={},{}
local function read(b)
  local r,e=call(b.reactor,"getReactorInfo"); if type(r)~="table" then return nil,e or "getReactorInfo failed" end
  local inputSet=call(b.input,"getFlowOverride");if inputSet==nil then inputSet=call(b.input,"getSignalLowFlow") end
  local outputSet=call(b.output,"getFlowOverride");if outputSet==nil then outputSet=call(b.output,"getSignalLowFlow") end
  if tonumber(inputSet) then gateApplied[b.input]=tonumber(inputSet) end
  if tonumber(outputSet) then gateApplied[b.output]=tonumber(outputSet) end
  return {reactor=r,inputFlow=call(b.input,"getFlow"),outputFlow=call(b.output,"getFlow"),inputSet=inputSet,outputSet=outputSet,inputOverride=call(b.input,"getOverrideEnabled"),outputOverride=call(b.output,"getOverrideEnabled")}
end
local function gate(n,v,force)
  local flow=math.max(0,math.floor(tonumber(v) or 0))
  local applied=tonumber(gateApplied[n])
  if not force and applied and math.abs(applied-flow)<1 then return true end
  local previous=gateCommands[n]
  local now=os.clock()
  if not force and previous and previous.flow==flow and now-previous.sent<.75 then return true end
  local enabled,enableError=call(n,"setOverrideEnabled",true);if enabled==nil and enableError then return false,enableError end
  local _,flowError=call(n,"setFlowOverride",flow);if flowError then return false,flowError end
  gateCommands[n]={flow=flow,sent=now}
  return true
end
local function positive(v) v=tonumber(v);return v and v>0 and math.floor(v) or nil end
local function adoptInjectorBaseline(d,c)
  if not positive(c.injectorBaseline) then
    -- Prefer the configured gate limit over live flow: live flow drops when
    -- the reactor is cool, but the configured limit remains the proven field
    -- support capacity selected by the operator.
    c.injectorBaseline=positive(d.inputSet) or positive(d.inputFlow)
  end
  return positive(c.injectorBaseline)
end
local function acquireGates(b,d,c)
  local injectorCap=adoptInjectorBaseline(d,c)
  if not injectorCap then
    c.gatesOwned=false;c.gateError="no positive injector gate limit to adopt"
    c.message="CONTROL LOCKED: set the injector gate manually, then restart Guardian"
    return false
  end
  if c.inputControlVerified==true and c.outputControlVerified==true then c.gatesOwned=true;c.gateError=nil;return true end
  if d.inputOverride==true and d.outputOverride==true then c.gatesOwned=true;c.inputControlVerified=true;c.outputControlVerified=true;c.gateError=nil;return true end
  -- Containment first, then export. Never close field support while taking control.
  local inputOk,inputError=gate(b.input,injectorCap,true)
  local outputOk,outputError=gate(b.output,0,true)
  local inputReported=call(b.input,"getOverrideEnabled")==true
  local outputReported=call(b.output,"getOverrideEnabled")==true
  local inputSet=call(b.input,"getFlowOverride");if inputSet==nil then inputSet=call(b.input,"getSignalLowFlow") end
  local outputSet=call(b.output,"getFlowOverride");if outputSet==nil then outputSet=call(b.output,"getSignalLowFlow") end
  -- Some DE builds show "Overridden" in the GUI but return false/nil from
  -- getOverrideEnabled(). A successful command whose override setpoint reads
  -- back exactly is equivalent proof that this computer owns the gate.
  local inputOwned=inputReported or (inputOk and tonumber(inputSet) and math.abs(tonumber(inputSet)-injectorCap)<1)
  local outputOwned=outputReported or (outputOk and tonumber(outputSet) and math.abs(tonumber(outputSet))<1)
  c.inputControlVerified=inputOwned==true;c.outputControlVerified=outputOwned==true
  c.gatesOwned=inputOk and outputOk and inputOwned and outputOwned
  if not c.gatesOwned then
    c.message="CONTROL LOCKED: gate override not acquired (field "..tostring(inputOwned)..", output "..tostring(outputOwned)..")"
    c.gateError=inputError or outputError
  else c.gateError=nil end
  return c.gatesOwned
end
local reactorCommands={}
local function reactor(n,m)
  local now=os.clock();local previous=reactorCommands[n]
  if previous and previous.method==m and now-previous.sent<.75 then return true end
  local ok,result=pcall(peripheral.call,n,m)
  if ok then reactorCommands[n]={method=m,sent=now} end
  return ok,result
end

-- A requested export is only meaningful once the core is actually online.
-- Keep the entire charge -> activate sequence in one place so the manual
-- selector, commissioning, and the explicit activation control behave alike.
local function ensureStarted(b,c,status,reason,fieldTarget,telemetry)
  local fieldSupply=positive(fieldTarget) or positive(c.injectorBaseline) or 0
  local function percent(value,maximum)
    value,maximum=tonumber(value),tonumber(maximum)
    return value and maximum and maximum>0 and value/maximum*100 or nil
  end
  gate(b.output,0)
  gate(b.input,fieldSupply)
  if status=="offline" or status=="stopping" or status=="cooling" then
    reactor(b.reactor,"chargeReactor")
    c.startActivated=false
    c.message=reason..": charging containment"
    return true
  end
  if status=="charging" then
    c.startActivated=false
    c.message=reason..": charging reactor; waiting for CHARGED"
    return true
  end
  local field=percent(telemetry and telemetry.fieldStrength,
    telemetry and telemetry.maxFieldStrength)
  local saturation=percent(telemetry and telemetry.energySaturation,
    telemetry and telemetry.maxEnergySaturation)
  local temperature=tonumber(telemetry and telemetry.temperature)
  local warmReady=(status=="warming_up" or status=="warning_up") and
    field and field>=49.5 and saturation and saturation>=49.5 and
    temperature and temperature>=1990
  if status=="charged" or warmReady then
    if not c.startActivated then
      reactor(b.reactor,"activateReactor")
      c.startActivated=true
    end
    c.message=reason..": activation sent; waiting for ONLINE"
    return true
  end
  if status=="warming_up" or status=="warning_up" then
    c.startActivated=false
    c.message=string.format("%s: charging (core %.0f/2000 C, field %.1f%%, saturation %.1f%%)",
      reason,temperature or 0,field or 0,saturation or 0)
    return true
  end
  if status=="online" or status=="running" then
    c.initialRequested=false
    c.startActivated=false
    return false
  end
  c.message=reason..": waiting for reactor state "..string.upper(status)
  return true
end
local function pct(a,b) if tonumber(a) and tonumber(b) and tonumber(b)>0 then return tonumber(a)/tonumber(b)*100 end end
local function imminentMeltdown(r)
  local status=string.lower(tostring(r and r.status or "unknown"))
  local normalized=status:gsub("[^%w]","")
  -- Draconic Evolution reports its irreversible terminal state as
  -- `beyond_hope`. It must alarm unconditionally: waiting for a secondary
  -- field/temperature threshold can suppress the only warning that matters.
  if normalized=="beyondhope" or normalized=="exploding" or
     normalized=="meltdown" or normalized=="explosionimminent" then
    return true,"IMMINENT DRACONIC REACTOR EXPLOSION: reactor state "..
      string.upper(status)
  end
  local atRisk=status=="online" or status=="running" or status=="stopping" or status=="cooling"
  if not atRisk then return false end
  local field=pct(r.fieldStrength,r.maxFieldStrength)
  local temperature=tonumber(r.temperature)
  local fuelRemaining=pct((tonumber(r.maxFuelConversion) or 0)-
    (tonumber(r.fuelConversion) or 0),r.maxFuelConversion)
  local reasons={}
  -- These are announcement thresholds only. They never alter gates, modes, or
  -- reactor state. Unrestricted remains genuinely unrestricted.
  if field and field<=25 then reasons[#reasons+1]=string.format("field %.1f%%",field) end
  if temperature and temperature>=7000 then reasons[#reasons+1]=string.format("core %.0f C",temperature) end
  if fuelRemaining and fuelRemaining<=12 then reasons[#reasons+1]=string.format("fuel %.1f%%",fuelRemaining) end
  if #reasons==0 then return false end
  return true,"IMMINENT DRACONIC REACTOR MELTDOWN: "..table.concat(reasons,", ")
end
local function clamp(x) return math.max(0,math.min(1,tonumber(x) or 0)) end
local function fmt(n)
  n=tonumber(n);if not n then return "N/A" end;local u={"","k","M","B","T","Qa"};local i=1
  while math.abs(n)>=1000 and i<#u do n=n/1000;i=i+1 end
  return string.format(math.abs(n)>=100 and "%.0f%s" or "%.2f%s",n,u[i])
end
local function text(t,x,y,s,c) local w=select(1,t.getSize());if y>=1 then t.setCursorPos(x,y);t.setTextColor(c or colors.white);t.write(string.sub(tostring(s),1,math.max(0,w-x+1))) end end
local function replaceLine(t,y,s,c)
  local w=select(1,t.getSize())
  if y<1 then return end
  t.setCursorPos(1,y);t.setBackgroundColor(colors.black);t.write(string.rep(" ",w))
  text(t,1,y,s,c)
end
local function compactMonitor(t,isMonitor) if isMonitor and t and type(t.setTextScale)=="function" then pcall(t.setTextScale,.5) end end
-- Monitor touches report character coordinates. Keep every target on its
-- rendered row so vertically adjacent controls can never steal a press.
local function button(t,x,y,label,c,pad)
  local v="["..label.."]";text(t,x,y,v,c or colors.cyan)
  pad=math.max(0,math.floor(tonumber(pad) or 0))
  return {x1=math.max(1,x-pad),x2=x+#v-1+pad,y1=math.max(1,y-pad),y2=y+pad,x=x,y=y,label=label}
end
local function hit(bs,x,y)
  local picked, distance
  -- Later controls are overlays (for example the unrestricted confirmation
  -- row) and must win if they cover an older control.
  for i=#bs,1,-1 do local b=bs[i]
    if y>=b.y1 and y<=b.y2 and x>=b.x1 and x<=b.x2 then
      local d=math.abs(y-b.y)*100+math.abs(x-(b.x+b.x2)/2)
      if not distance or d<distance then picked,distance=b,d end
    end
  end
  -- A wall monitor can report the neighbouring character at small text
  -- scales. If the exact box missed, accept the nearest control within one
  -- row and three columns instead of making the operator repeatedly tap it.
  if not picked then
    for i=#bs,1,-1 do local b=bs[i]
      if math.abs(y-b.y)<=1 and x>=b.x1-3 and x<=b.x2+3 then
        local d=math.abs(y-b.y)*100+math.abs(x-(b.x+b.x2)/2)
        if not distance or d<distance then picked,distance=b,d end
      end
    end
  end
  return picked and picked.label
end
local function vertical(t,x,y,h,label,now,maximum,c)
  local f=maximum and clamp((tonumber(now) or 0)/maximum) or 0;text(t,x,y,label,colors.lightGray)
  for row=1,h do t.setCursorPos(x,y+row);t.setBackgroundColor(row>h-math.max(1,math.floor(h*f)) and c or colors.gray);t.write("    ") end
  t.setBackgroundColor(colors.black);text(t,x,y+h+1,string.format("%3.0f%%",f*100),c)
end
local function load()
  local d={mode="AUTO",request="OFF",rated=nil,commissioned=false,commissioning=false,commissionFlow=nil,commissionSamples=0,commissionShortfallSamples=0,commissionSettleSamples=0,commissionLastSafe=nil,recovery=false,arm=0,initialRequested=false,startActivated=false,liveGatesSelected=false,message="Automatic safe supervision"}
  if not fs.exists(SETTINGS) then return d end;local ok,s=pcall(dofile,SETTINGS);if not ok or type(s)~="table" then return d end
  d.mode=(s.mode=="ASSISTED" or s.mode=="UNRESTRICTED") and s.mode or "AUTO";d.request=(FRACTION[s.request] or s.request=="MANUAL" or s.request=="OVERDRIVE") and s.request or "OFF";d.rated=tonumber(s.rated);d.injectorBaseline=positive(s.injectorBaseline);d.manualField=positive(s.manualField);d.manualExport=positive(s.manualExport) or 0;d.overdriveField=positive(s.overdriveField);d.overdriveExport=positive(s.overdriveExport);d.commissioned=s.commissioned==true;d.message=tostring(s.message or d.message);return d
end
local function save(c)
  local parent=fs.getDir(SETTINGS);if parent~="" and not fs.exists(parent) then fs.makeDir(parent) end
  local h=fs.open(SETTINGS,"w");if h then h.write("return "..textutils.serialize(c));h.close() end
end

-- AUTO and ASSISTED retain containment. UNRESTRICTED is visibly armed and lets
-- the operator's command stand, while warnings remain live.
local function supervise(b,d,c)
  local r=d.reactor;local status=string.lower(tostring(r.status or "unknown"));local field=pct(r.fieldStrength,r.maxFieldStrength) or 0
  local live=status=="online" or status=="running"
  local containmentRequired=live or status=="stopping" or status=="cooling"
  local fuel=pct((tonumber(r.maxFuelConversion) or 0)-(tonumber(r.fuelConversion) or 0),r.maxFuelConversion) or 0;local temp=tonumber(r.temperature) or math.huge;local free=c.mode=="UNRESTRICTED"
  local injectorCap=positive(c.injectorBaseline) or 0
  local function stop(reason,charge) gate(b.output,0);reactor(b.reactor,"stopReactor");if charge then reactor(b.reactor,"chargeReactor");gate(b.input,injectorCap) end;c.message="SAFETY INTERLOCK: "..reason;return true end
  if not acquireGates(b,d,c) then
    c.initialRequested=false;c.startActivated=false;c.commissioning=false
    reactor(b.reactor,"stopReactor")
    return
  end
  -- A pending start owns every pre-online transition. In particular, STOPPING
  -- may be the tail of an earlier shutdown and WARMING_UP has no containment
  -- yet. Let the shared charge/activate state machine finish before applying
  -- interlocks which are intended for a reactor that has already been live.
  if c.initialRequested and not live then
    ensureStarted(b,c,status,"Initial start",injectorCap,r)
    return
  end
  if not free then
    if fuel<=MINIMUM_FUEL then return stop("fuel reserve below "..MINIMUM_FUEL.."%") end
    -- WARMING_UP legitimately reports zero containment before activation has
    -- completed. Applying the live-reactor interlock there creates a loop of
    -- stop -> charge -> activate -> stop. Once the reactor is live (or is
    -- stopping/cooling after being live), containment must still win.
    if containmentRequired and field<=FIELD_EMERGENCY then
      return stop("field below "..FIELD_EMERGENCY.."%",true)
    end
    if temp>MAX_TEMPERATURE then return stop("temperature above "..MAX_TEMPERATURE.." C") end
  else
    local imminent,warning=imminentMeltdown(r)
    if imminent then c.message="UNRESTRICTED WARNING: "..warning end
  end
  if status=="charging" then gate(b.input,injectorCap);c.message="Charging containment";return end
  if c.initialRequested then
    if live then c.initialRequested=false;c.startActivated=false;c.message="Initial start complete; reactor is live" end
  end
  if c.recovery then
    -- A calibration that reaches its edge pauses with export closed until the
    -- field has rebuilt. This prevents an old manual request from resuming.
    gate(b.output,0);gate(b.input,injectorCap)
    if field>=45 and temp<=COMMISSION_TEMP_LIMIT then
      c.recovery=false
      c.message="Calibration recovery complete; export remains OFF"
    else c.message="Calibration recovery: output closed while containment rebuilds" end
    return
  end
  if c.commissioning then
    if not live then
      c.initialRequested=true
      c.message="Automatic commissioning: waiting for reactor to reach ONLINE"
      return
    end
    local trial=math.max(COMMISSION_START_FLOW,tonumber(c.commissionFlow) or COMMISSION_START_FLOW)
    gate(b.input,injectorCap)
    gate(b.output,trial)
    -- Stop just above the hard 15% interlock. A 17% calibration cutoff leaves
    -- the guardian room to close export and rebuild the field safely.
    if field<COMMISSION_FIELD_FLOOR or temp>COMMISSION_TEMP_LIMIT or fuel<=MINIMUM_FUEL then
      gate(b.output,0);gate(b.input,injectorCap);c.commissioning=false;c.initialRequested=false;c.commissionSamples=0;c.commissionShortfallSamples=0;c.commissionSettleSamples=0;c.request="OFF";c.recovery=true
      c.commissioned=tonumber(c.commissionLastSafe) and c.commissionLastSafe>0 or false;c.rated=c.commissionLastSafe
      c.message="Calibration reached the 17% field edge; output closed. Last verified ceiling "..fmt(c.rated or 0).." RF/t"
      return
    end
    -- A Flux Gate's reported flow is not a trustworthy measure of reactor
    -- generation on every DE/ATM configuration.  The reactor component is
    -- authoritative: only count a trial as proven when its generation rate
    -- actually follows the requested export.
    local generation=tonumber(r.generationRate) or 0
    local stable=field>=45 and temp<=COMMISSION_TEMP_LIMIT and fuel>MINIMUM_FUEL and generation>=trial*.9
    if generation<trial*.9 then
      c.commissionSamples=0
      c.commissionSettleSamples=(tonumber(c.commissionSettleSamples) or 0)+1
      if c.commissionSettleSamples<COMMISSION_SETTLE_SAMPLES then
        c.commissionShortfallSamples=0
        c.message="Waiting for "..fmt(trial).." RF/t to settle: reactor generation "..fmt(generation).." RF/t ("..c.commissionSettleSamples.."/"..COMMISSION_SETTLE_SAMPLES..")"
        return
      end
      c.commissionSamples=0;c.commissionShortfallSamples=(tonumber(c.commissionShortfallSamples) or 0)+1
      if c.commissionShortfallSamples>=COMMISSION_SHORTFALL_SAMPLES then
        gate(b.output,0);c.commissioning=false;c.initialRequested=false;c.request="OFF";c.commissioned=(tonumber(c.commissionLastSafe) or 0)>0;c.rated=c.commissionLastSafe
        c.message="Calibration complete: output path stopped accepting higher export; verified ceiling "..fmt(c.rated or 0).." RF/t"
      else c.message="Testing "..fmt(trial).." RF/t: reactor generation "..fmt(generation).." RF/t ("..c.commissionShortfallSamples.."/"..COMMISSION_SHORTFALL_SAMPLES..")" end
      return
    end
    c.commissionSettleSamples=0;c.commissionShortfallSamples=0;c.commissionSamples=stable and (tonumber(c.commissionSamples) or 0)+1 or 0
    if c.commissionSamples>=COMMISSION_SAMPLES then
      c.rated=trial;c.commissionLastSafe=trial;c.commissionSamples=0;c.commissionSettleSamples=0
      c.commissionFlow=math.max(trial+COMMISSION_MIN_STEP,math.floor(trial*COMMISSION_STEP_RATIO))
      c.message="Calibration proved "..fmt(trial).." RF/t; advancing to "..fmt(c.commissionFlow).." RF/t"
    else
      c.message="Calibrating "..fmt(trial).." RF/t: stable sample "..c.commissionSamples.."/"..COMMISSION_SAMPLES
    end
    return
  end
  if c.mode=="AUTO" then gate(b.input,injectorCap);gate(b.output,0);c.message="Automatic: adopted "..fmt(injectorCap).." RF/t injector limit; export closed";return end
  if not c.commissioned or not c.rated then c.message="Control locked: run automatic commissioning first";return end
  -- Manual Gates and the saved Overdrive preset use the operator's exact
  -- field/export pair. Overdrive ramps only its export value so a cold core
  -- can gain efficiency instead of being hit with the whole load at once.
  if c.request=="MANUAL" or c.request=="OVERDRIVE" then
    local fieldTarget=positive(c.request=="OVERDRIVE" and c.overdriveField or c.manualField) or injectorCap
    local exportTarget=positive(c.request=="OVERDRIVE" and c.overdriveExport or c.manualExport) or 0
    if not live then ensureStarted(b,c,status,"Manual power demand",fieldTarget,r);return end
    if live then
      gate(b.input,fieldTarget)
      local applied=exportTarget
      if c.request=="OVERDRIVE" then
        local previous=tonumber(c.overdriveApplied) or 0
        -- Hold instead of climbing whenever containment is below its normal
        -- operating target; the saved preset is never silently replaced.
        if field>=FIELD_TARGET then previous=math.min(exportTarget,previous+PRESET_RAMP_STEP) end
        c.overdriveApplied=previous;applied=previous
        c.message="Overdrive preset ramp: "..fmt(applied).." / "..fmt(exportTarget).." RF/t"
      else c.message="Manual gates applied: field "..fmt(fieldTarget)..", export "..fmt(exportTarget).." RF/t" end
      gate(b.output,applied)
      return
    end
  end
  if c.request=="OFF" then gate(b.output,0);reactor(b.reactor,"stopReactor");c.message="Manual OFF: export closed";return end
  if not live then ensureStarted(b,c,status,"Requested "..tostring(c.request).." output",injectorCap,r);return end
  if live then gate(b.input,injectorCap);gate(b.output,c.rated*(FRACTION[c.request] or 0));c.message=(free and "UNRESTRICTED" or "ASSISTED").." "..c.request.." output applied" end
end
local function draw(t,b,d,page,c,bs)
  local w,h=t.getSize();t.setBackgroundColor(colors.black);t.setTextColor(colors.white);t.clear();text(t,1,1,"HELIOS // DRACONIC GUARDIAN  "..GUARDIAN_VERSION,colors.yellow)
  local banner=c.mode=="UNRESTRICTED" and "UNRESTRICTED CONTROL - AUTOMATIC INTERVENTION DISABLED" or c.mode=="ASSISTED" and "ASSISTED MANUAL - HARD SAFETY INTERLOCKS ACTIVE" or "AUTOMATIC SAFE SUPERVISION"
  text(t,1,2,banner,c.mode=="UNRESTRICTED" and colors.red or colors.lime);text(t,1,3,"[OVERVIEW] [RAW DATA] [SETUP] [MANUAL GATES]",colors.cyan)
  if not b.ready then text(t,1,5,"SETUP INVALID",colors.red);for i,v in ipairs(b.reasons) do text(t,1,5+i,"- "..v) end;return end
  if not d then text(t,1,5,"TELEMETRY LOST",colors.red);return end
  local critical,criticalMessage=imminentMeltdown(d.reactor)
  if critical then replaceLine(t,2,criticalMessage,colors.red) end
  if page=="setup" then text(t,1,5,"FIXED GATE TOPOLOGY VALID",colors.lime);text(t,1,7,"Reactor component: "..b.reactor);text(t,1,8,"Export gate (LEFT/RIGHT): "..b.output);text(t,1,9,"Injector field gate (MODEM): "..b.input);text(t,1,10,"Wired modem: "..b.modem);text(t,1,12,"Export and containment roles are fixed; Guardian will not infer them.",colors.orange);return end
  if page=="raw" then text(t,1,5,"RAW DRACONIC TELEMETRY",colors.cyan);local ks={};for k in pairs(d.reactor) do ks[#ks+1]=tostring(k) end;sort(ks);for i,k in ipairs(ks) do if i+6<h then text(t,1,i+6,k..": "..tostring(d.reactor[k])) end end;return end
  if page=="gates" then
    text(t,1,5,"MANUAL GATES // unrestricted only",c.mode=="UNRESTRICTED" and colors.red or colors.orange)
    if c.mode~="UNRESTRICTED" then text(t,1,7,"Arm Unrestricted control before changing either gate manually.",colors.orange);return end
    local r=d.reactor
    local status=string.lower(tostring(r.status or "unknown"))
    local fieldTarget=tonumber(c.manualField) or tonumber(d.inputSet) or 0
    local exportTarget=tonumber(c.manualExport) or tonumber(d.outputSet) or 0
    local exportSet=tonumber(d.outputSet) or 0
    local fieldSet=tonumber(d.inputSet) or 0
    local manualApplied=c.request=="MANUAL" and math.abs(fieldSet-fieldTarget)<1 and math.abs(exportSet-exportTarget)<1
    local exportApplied=manualApplied and (status=="online" or status=="running")
    local liveGatesSelected=c.liveGatesSelected==true and math.abs(fieldTarget-fieldSet)<1 and math.abs(exportTarget-exportSet)<1
    local presetField,presetExport=positive(c.overdriveField),positive(c.overdriveExport)
    local presetSaved=presetField and presetExport and presetField==positive(c.manualField or d.inputSet) and presetExport==positive(exportTarget)
    text(t,1,7,"FIELD GATE (injector): "..fmt(c.manualField or d.inputSet).." RF/t",colors.cyan)
    local twoColumn=w>=78 and h>=27
    if twoColumn then
      local fieldSteps={{"FIELD -1k",1},{"FIELD -10k",9},{"FIELD -100k",18},{"FIELD -1M",28},{"FIELD +1k",1},{"FIELD +10k",9},{"FIELD +100k",18},{"FIELD +1M",28}}
      for index,item in ipairs(fieldSteps) do bs[#bs+1]=button(t,item[2],index<=4 and 9 or 11,string.sub(item[1],7),colors.cyan,1);bs[#bs].label=item[1] end
      text(t,1,14,"EXPORT GATE: "..fmt(exportTarget).." RF/t  "..(exportApplied and "APPLIED" or "PENDING"),exportApplied and colors.lime or colors.orange)
      local exportSteps={{"EXPORT -1k",1},{"EXPORT -10k",9},{"EXPORT -100k",18},{"EXPORT -1M",28},{"EXPORT +1k",1},{"EXPORT +10k",9},{"EXPORT +100k",18},{"EXPORT +1M",28}}
      for index,item in ipairs(exportSteps) do bs[#bs+1]=button(t,item[2],index<=4 and 16 or 18,string.sub(item[1],8),colors.cyan,1);bs[#bs].label=item[1] end
      bs[#bs+1]=button(t,1,20,"USE LIVE GATES",liveGatesSelected and colors.lime or colors.lightGray,1);bs[#bs+1]=button(t,24,20,"APPLY MANUAL",manualApplied and colors.lime or colors.orange,1)
      bs[#bs+1]=button(t,1,23,"SAVE AS OVERDRIVE PRESET",presetSaved and colors.lime or colors.red,1);bs[#bs+1]=button(t,40,23,"BACK",colors.lightGray,1)
      text(t,1,26,"Overdrive keeps this field setting and ramps only export to the saved target.",colors.lightGray)
    else
      bs[#bs+1]=button(t,1,9,"FIELD -1k",colors.cyan,1);bs[#bs+1]=button(t,16,9,"FIELD -10k",colors.cyan,1);bs[#bs+1]=button(t,33,9,"FIELD -100k",colors.cyan,1);bs[#bs+1]=button(t,51,9,"FIELD -1M",colors.cyan,1)
      bs[#bs+1]=button(t,1,11,"FIELD +1k",colors.cyan,1);bs[#bs+1]=button(t,16,11,"FIELD +10k",colors.cyan,1);bs[#bs+1]=button(t,33,11,"FIELD +100k",colors.cyan,1);bs[#bs+1]=button(t,51,11,"FIELD +1M",colors.cyan,1)
      text(t,1,12,"EXPORT GATE: "..fmt(exportTarget).." RF/t"..(exportApplied and "  APPLIED" or "  PENDING"),exportApplied and colors.lime or colors.orange)
      bs[#bs+1]=button(t,1,14,"EXPORT -1k",colors.cyan,1);bs[#bs+1]=button(t,16,14,"EXPORT -10k",colors.cyan,1);bs[#bs+1]=button(t,33,14,"EXPORT -100k",colors.cyan,1);bs[#bs+1]=button(t,51,14,"EXPORT -1M",colors.cyan,1)
      bs[#bs+1]=button(t,1,16,"EXPORT +1k",colors.cyan,1);bs[#bs+1]=button(t,16,16,"EXPORT +10k",colors.cyan,1);bs[#bs+1]=button(t,33,16,"EXPORT +100k",colors.cyan,1);bs[#bs+1]=button(t,51,16,"EXPORT +1M",colors.cyan,1)
      bs[#bs+1]=button(t,1,19,"USE LIVE GATES",liveGatesSelected and colors.lime or colors.lightGray,1);bs[#bs+1]=button(t,22,19,"APPLY MANUAL",manualApplied and colors.lime or colors.orange,1)
      bs[#bs+1]=button(t,1,22,"SAVE AS OVERDRIVE PRESET",presetSaved and colors.lime or colors.red,1);bs[#bs+1]=button(t,35,22,"BACK",colors.lightGray,1)
      text(t,1,25,"Overdrive keeps this field setting and ramps only export to the saved target.",colors.lightGray)
    end
    local tx,ty=1,25
    if twoColumn then tx,ty=49,6 end
    local tw=math.max(18,w-tx+1)
    local function liveLine(y,s,color) if y<=h then text(t,tx,y,string.sub(tostring(s),1,tw),color) end end
    liveLine(ty,"LIVE TELEMETRY",colors.cyan)
    liveLine(ty+2,"State: "..tostring(r.status),colors.lime)
    liveLine(ty+3,"Generation: "..fmt(r.generationRate).." RF/t",colors.cyan)
    liveLine(ty+4,"Core temp: "..fmt(r.temperature).." C",colors.orange)
    liveLine(ty+5,"Field strength: "..string.format("%.1f%%",pct(r.fieldStrength,r.maxFieldStrength) or 0))
    liveLine(ty+6,"Field drain: "..fmt(r.fieldDrainRate).." RF/t")
    liveLine(ty+7,"Saturation: "..string.format("%.1f%%",pct(r.energySaturation,r.maxEnergySaturation) or 0))
    liveLine(ty+8,"Fuel conversion: "..string.format("%.1f%%",pct(r.fuelConversion,r.maxFuelConversion) or 0))
    local inputControlled=d.inputOverride==true or c.inputControlVerified==true
    liveLine(ty+10,"Field live/set: "..fmt(d.inputFlow).." / "..fmt(d.inputSet),inputControlled and colors.lime or colors.red)
    liveLine(ty+11,"Export live/set: "..fmt(d.outputFlow).." / "..fmt(d.outputSet),exportApplied and colors.lime or colors.orange)
    return
  end
  local r=d.reactor;if w<54 or h<25 then text(t,1,5,"Large monitor required for the Guardian console.",colors.orange);text(t,1,7,"State: "..tostring(r.status).."  Temp: "..fmt(r.temperature).." C");text(t,1,8,"Generation: "..fmt(r.generationRate).." RF/t");return end
  -- Match the reactor GUI's composition: two bars, central telemetry, two
  -- bars. Every central line is clipped before the right-hand pair.
  local x,rightSat,rightFuel=18,w-11,w-5
  local centerWidth=math.max(12,rightSat-x-2)
  local function center(y,s,color) text(t,x,y,string.sub(tostring(s),1,centerWidth),color) end
  local function centerWrap(y,s,color,maxLines)
    local remaining=tostring(s or "")
    for line=1,(maxLines or 1) do
      if #remaining<=centerWidth then center(y+line-1,remaining,color);return end
      local chunk=string.sub(remaining,1,centerWidth)
      local split=chunk:match("^.*()%s") or centerWidth
      center(y+line-1,string.sub(remaining,1,split-1),color)
      remaining=string.gsub(string.sub(remaining,split+1),"^%s+","")
    end
  end
  vertical(t,2,5,12,"CORE",r.temperature,MAX_TEMPERATURE,colors.orange)
  vertical(t,9,5,12,"FIELD",r.fieldStrength,tonumber(r.maxFieldStrength),colors.red)
  vertical(t,rightSat,5,12,"SAT",r.energySaturation,tonumber(r.maxEnergySaturation),colors.blue)
  vertical(t,rightFuel,5,12,"FUEL",r.fuelConversion,tonumber(r.maxFuelConversion),colors.lime)
  center(5,"REACTOR TELEMETRY",colors.cyan);center(7,"State: "..tostring(r.status),colors.lime);center(8,"Generation: "..fmt(r.generationRate).." RF/t",colors.cyan)
  center(9,"Core temperature: "..fmt(r.temperature).." C",colors.orange);center(10,"Containment field strength: "..fmt(r.fieldStrength).." / "..fmt(r.maxFieldStrength));center(11,"Energy saturation: "..fmt(r.energySaturation).." / "..fmt(r.maxEnergySaturation));center(12,"Fuel conversion level: "..fmt(r.fuelConversion).." / "..fmt(r.maxFuelConversion))
  local inputControlled=d.inputOverride==true or c.inputControlVerified==true
  local outputControlled=d.outputOverride==true or c.outputControlVerified==true
  center(14,"GATE CONTROL",colors.cyan);center(15,"Field: "..fmt(d.inputFlow).." / "..fmt(d.inputSet),inputControlled and colors.lime or colors.red);center(16,"Export: "..fmt(d.outputFlow).." / "..fmt(d.outputSet),outputControlled and colors.lime or colors.red);center(17,"modem=field; "..tostring(b.output).."=export",colors.lightGray);centerWrap(18,"GUARDIAN: "..c.message,c.mode=="UNRESTRICTED" and colors.red or colors.lightGray,3)
  local y=h-7;if not c.gatesOwned then
    text(t,1,y-2,"GATE CONTROL NOT ACQUIRED - REACTOR START DISABLED",colors.red)
    text(t,1,y-1,"Field control: "..tostring(c.inputControlVerified).."  Export control: "..tostring(c.outputControlVerified),colors.orange)
    if c.gateError then text(t,1,y,"API error: "..tostring(c.gateError),colors.red) end
    bs[#bs+1]=button(t,1,y+3,"SAFE SHUTDOWN",colors.red)
  elseif not c.commissioned then
    text(t,1,y-2,"OUTPUT SELECTOR  [OFF] [MIN] [MED] [MAX] [OVERDRIVE]",colors.gray)
    text(t,1,y-1,"LOCKED: calibrate a verified output ceiling against live containment.",colors.orange)
    bs[#bs+1]=button(t,1,y,"AUTO COMMISSION",colors.orange)
    text(t,1,y+1,"Starts at 50k RF/t; rises while the field stays at or above 17%.",colors.lightGray)
    bs[#bs+1]=button(t,1,y+3,"INITIALIZE & ACTIVATE",colors.lime)
    bs[#bs+1]=button(t,27,y+3,"SAFE SHUTDOWN",colors.red)
  elseif c.mode=="AUTO" then bs[#bs+1]=button(t,1,y,"ENABLE ASSISTED MANUAL",colors.orange);bs[#bs+1]=button(t,27,y,"RECALIBRATE CEILING",colors.orange);bs[#bs+1]=button(t,1,y+2,"INITIALIZE & ACTIVATE",colors.lime);bs[#bs+1]=button(t,27,y+2,"SAFE SHUTDOWN",colors.red)
  elseif c.mode=="ASSISTED" then
    local px=1;for _,v in ipairs({"OFF","MIN","MED","MAX"}) do local q=button(t,px,y,v,colors.cyan);bs[#bs+1]=q;px=q.x2+2 end;bs[#bs+1]=button(t,px,y,"ARM UNRESTRICTED",colors.red)
    bs[#bs+1]=button(t,1,y+2,"INITIALIZE & ACTIVATE",colors.lime);bs[#bs+1]=button(t,27,y+2,"SAFE SHUTDOWN",colors.red)
    bs[#bs+1]=button(t,1,y+4,"RESTORE AUTOMATIC",colors.lime);bs[#bs+1]=button(t,27,y+4,"RECALIBRATE CEILING",colors.orange)
  else local px=1;for _,v in ipairs({"OFF","MIN","MED","MAX","OVERDRIVE"}) do local q=button(t,px,y,v,colors.red);bs[#bs+1]=q;px=q.x2+2 end;bs[#bs+1]=button(t,1,y+2,"RESTORE AUTOMATIC",colors.lime) end
  if c.arm and c.arm>0 then local labels={"LIFT SAFETY INTERLOCK","DISABLE AUTOMATIC CONTROL","TURN AUTHORIZATION KEY","ARM UNRESTRICTED CONTROL"};text(t,1,h-3,"UNRESTRICTED ARMING "..c.arm.."/4: "..labels[c.arm],colors.red);bs[#bs+1]=button(t,1,h-2,labels[c.arm],colors.red);bs[#bs+1]=button(t,35,h-2,"CANCEL",colors.lightGray) end
end
local function drawComputer(t,d,c)
  local w,h=t.getSize();t.setBackgroundColor(colors.black);t.setTextColor(colors.white);t.clear()
  local function line(y,s,color)
    if y>h then return end
    t.setCursorPos(1,y);t.setTextColor(color or colors.white);t.write(string.sub(tostring(s or ""),1,w))
  end
  line(1,"HELIOS DRACONIC GUARDIAN "..GUARDIAN_VERSION,colors.yellow)
  line(2,"Mode: "..tostring(c.mode).."  Request: "..tostring(c.request),c.mode=="UNRESTRICTED" and colors.red or colors.lime)
  if d and d.reactor then
    local r=d.reactor
    local critical,criticalMessage=imminentMeltdown(r)
    if critical then line(3,criticalMessage,colors.red) end
    line(4,"State "..tostring(r.status).."  Gen "..fmt(r.generationRate).." RF/t",colors.cyan)
    line(5,"Core "..fmt(r.temperature).." C  Field "..string.format("%.1f%%",pct(r.fieldStrength,r.maxFieldStrength) or 0),colors.orange)
    line(6,"Saturation "..string.format("%.1f%%",pct(r.energySaturation,r.maxEnergySaturation) or 0).."  Fuel conversion "..string.format("%.1f%%",pct(r.fuelConversion,r.maxFuelConversion) or 0))
    line(7,"Field gate "..fmt(d.inputSet).."  Export gate "..fmt(d.outputSet),colors.lime)
  else line(4,"TELEMETRY LOST",colors.red) end
  line(9,"a start | s stop | c calibrate | r automatic")
  line(10,"m assisted | u arm/confirm unrestricted")
  line(11,"0 OFF | 1 MIN | 2 MED | 3 MAX | 4 OVERDRIVE")
  line(12,"Field: j/J 1k | k/K 10k | f/F 100k | v/V 1M")
  line(13,"Export: n/N 1k | h/H 10k | e/E 100k | x/X 1M")
  line(14,"Lowercase - | uppercase +")
  line(15,"p apply manual | o save Overdrive | q quit")
  line(17,"Manual field "..fmt(c.manualField or 0).."  export "..fmt(c.manualExport or 0),colors.cyan)
  line(18,"Guardian: "..tostring(c.message),colors.lightGray)
  line(19,"HELIOS link: "..(facilityConnected and "ONLINE" or (facilityNetwork and "WAITING" or "LOCAL ONLY")),facilityConnected and colors.lime or colors.gray)
end
local binding,page,controls,buttons=inspect(),"overview",load(),{}
controls.inputControlVerified=false;controls.outputControlVerified=false;controls.gatesOwned=false;controls.telemetryStale=false
local computer=term.current();local target=binding.monitor and peripheral.wrap(binding.monitor) or computer;compactMonitor(target,binding.monitor~=nil)
local function beginCalibration()
  controls.commissioning=true;controls.commissionFlow=COMMISSION_START_FLOW;controls.commissionSamples=0;controls.commissionShortfallSamples=0;controls.commissionSettleSamples=0;controls.commissionLastSafe=nil;controls.recovery=false;controls.commissioned=false;controls.rated=nil;controls.request="OFF"
  controls.initialRequested=true;controls.startActivated=false;controls.message="Automatic calibration requested by operator"
end
local function act(choice,d)
  if type(choice)=="string" and (string.find(choice,"FIELD",1,true)==1 or string.find(choice,"EXPORT",1,true)==1) then
    controls.liveGatesSelected=false
  end
  if (choice=="AUTO COMMISSION" or choice=="RECALIBRATE CEILING") and controls.gatesOwned then beginCalibration()
  elseif choice=="INITIALIZE & ACTIVATE" and controls.gatesOwned then controls.initialRequested=true;controls.startActivated=false;controls.message="Initial start requested by operator"
  elseif choice=="SAFE SHUTDOWN" then controls.request="OFF";controls.initialRequested=false;controls.startActivated=false;controls.message="Operator safe shutdown requested"
  elseif choice=="ENABLE ASSISTED MANUAL" then controls.mode="ASSISTED";controls.request="OFF";controls.message="Assisted manual enabled at OFF"
  elseif choice=="ARM UNRESTRICTED" then controls.arm=1;controls.message="Unrestricted arming started"
  elseif choice=="CANCEL" then controls.arm=0;controls.message="Unrestricted arming cancelled"
  elseif controls.arm and controls.arm>0 and choice then controls.arm=controls.arm+1;if controls.arm>4 then controls.arm=0;controls.mode="UNRESTRICTED";controls.request="OFF";controls.message="UNRESTRICTED CONTROL ARMED: operator commands are not overridden" end
  elseif choice=="RESTORE AUTOMATIC" then controls.mode="AUTO";controls.request="OFF";controls.arm=0;controls.message="Automatic safety restored"
  elseif choice=="USE LIVE GATES" then controls.manualField=positive(d.inputSet) or positive(d.inputFlow) or controls.injectorBaseline;controls.manualExport=positive(d.outputSet) or positive(d.outputFlow) or 0;controls.liveGatesSelected=true;controls.message="Copied live gate limits into manual controls"
  elseif choice=="FIELD -1k" then controls.manualField=math.max(0,(tonumber(controls.manualField) or positive(d.inputSet) or controls.injectorBaseline or 0)-MANUAL_GATE_FINE_STEP)
  elseif choice=="FIELD +1k" then controls.manualField=(tonumber(controls.manualField) or positive(d.inputSet) or controls.injectorBaseline or 0)+MANUAL_GATE_FINE_STEP
  elseif choice=="FIELD -10k" then controls.manualField=math.max(0,(tonumber(controls.manualField) or positive(d.inputSet) or controls.injectorBaseline or 0)-MANUAL_GATE_SMALL_STEP)
  elseif choice=="FIELD +10k" then controls.manualField=(tonumber(controls.manualField) or positive(d.inputSet) or controls.injectorBaseline or 0)+MANUAL_GATE_SMALL_STEP
  elseif choice=="FIELD -100k" then controls.manualField=math.max(0,(tonumber(controls.manualField) or positive(d.inputSet) or controls.injectorBaseline or 0)-MANUAL_GATE_STEP)
  elseif choice=="FIELD +100k" then controls.manualField=(tonumber(controls.manualField) or positive(d.inputSet) or controls.injectorBaseline or 0)+MANUAL_GATE_STEP
  elseif choice=="FIELD -1M" then controls.manualField=math.max(0,(tonumber(controls.manualField) or positive(d.inputSet) or controls.injectorBaseline or 0)-MANUAL_GATE_LARGE_STEP)
  elseif choice=="FIELD +1M" then controls.manualField=(tonumber(controls.manualField) or positive(d.inputSet) or controls.injectorBaseline or 0)+MANUAL_GATE_LARGE_STEP
  elseif choice=="EXPORT -1k" then controls.manualExport=math.max(0,(tonumber(controls.manualExport) or positive(d.outputSet) or 0)-MANUAL_GATE_FINE_STEP)
  elseif choice=="EXPORT +1k" then controls.manualExport=(tonumber(controls.manualExport) or positive(d.outputSet) or 0)+MANUAL_GATE_FINE_STEP
  elseif choice=="EXPORT -10k" then controls.manualExport=math.max(0,(tonumber(controls.manualExport) or positive(d.outputSet) or 0)-MANUAL_GATE_SMALL_STEP)
  elseif choice=="EXPORT +10k" then controls.manualExport=(tonumber(controls.manualExport) or positive(d.outputSet) or 0)+MANUAL_GATE_SMALL_STEP
  elseif choice=="EXPORT -100k" then controls.manualExport=math.max(0,(tonumber(controls.manualExport) or positive(d.outputSet) or 0)-MANUAL_GATE_STEP)
  elseif choice=="EXPORT +100k" then controls.manualExport=(tonumber(controls.manualExport) or positive(d.outputSet) or 0)+MANUAL_GATE_STEP
  elseif choice=="EXPORT -1M" then controls.manualExport=math.max(0,(tonumber(controls.manualExport) or positive(d.outputSet) or 0)-MANUAL_GATE_LARGE_STEP)
  elseif choice=="EXPORT +1M" then controls.manualExport=(tonumber(controls.manualExport) or positive(d.outputSet) or 0)+MANUAL_GATE_LARGE_STEP
  elseif choice=="APPLY MANUAL" then controls.request="MANUAL";controls.overdriveApplied=0;controls.startActivated=false;controls.message="Manual gate pair requested"
  elseif choice=="SAVE AS OVERDRIVE PRESET" then
    local field=positive(controls.manualField) or positive(d.inputSet) or controls.injectorBaseline
    local export=positive(controls.manualExport) or positive(d.outputSet)
    if field and export then controls.overdriveField=field;controls.overdriveExport=export;controls.message="Overdrive preset saved: field "..fmt(field)..", export "..fmt(export).." RF/t" else controls.message="Preset not saved: set positive field and export limits first" end
  elseif choice=="OVERDRIVE" then
    if positive(controls.overdriveField) and positive(controls.overdriveExport) then controls.request="OVERDRIVE";controls.overdriveApplied=0;controls.startActivated=false;controls.message="Saved Overdrive preset requested" else controls.message="No saved Overdrive preset: configure Manual Gates first" end
  elseif FRACTION[choice] then controls.request=choice;controls.startActivated=false;controls.message="Output request: "..choice end
end
local function keyboardChoice(ch)
  local commands={a="INITIALIZE & ACTIVATE",s="SAFE SHUTDOWN",c="RECALIBRATE CEILING",r="RESTORE AUTOMATIC",m="ENABLE ASSISTED MANUAL",["0"]="OFF",["1"]="MIN",["2"]="MED",["3"]="MAX",["4"]="OVERDRIVE",j="FIELD -1k",J="FIELD +1k",k="FIELD -10k",K="FIELD +10k",f="FIELD -100k",F="FIELD +100k",v="FIELD -1M",V="FIELD +1M",n="EXPORT -1k",N="EXPORT +1k",h="EXPORT -10k",H="EXPORT +10k",e="EXPORT -100k",E="EXPORT +100k",x="EXPORT -1M",X="EXPORT +1M",p="APPLY MANUAL",o="SAVE AS OVERDRIVE PRESET"}
  local manualKey={j=true,J=true,k=true,K=true,f=true,F=true,v=true,V=true,n=true,N=true,h=true,H=true,e=true,E=true,x=true,X=true,p=true,o=true,["4"]=true}
  if manualKey[ch] and controls.mode~="UNRESTRICTED" then controls.message="Keyboard manual gates require Unrestricted mode";return nil end
  if ch=="u" then return (controls.arm or 0)>0 and "KEYBOARD CONFIRM" or "ARM UNRESTRICTED" end
  return commands[ch]
end
local data=binding.ready and read(binding) or nil
local function redraw()
  buttons={}
  if target~=computer then draw(target,binding,data,page,controls,buttons) end
  drawComputer(computer,data,controls)
end
local DRAW_EVENT="guardian_redraw"
local actions={}
local function requestDraw() os.queueEvent(DRAW_EVENT) end
local function enqueue(choice)
  if not choice then return end
  if choice=="SAFE SHUTDOWN" then actions={choice} else actions[#actions+1]=choice end
  controls.message="Command queued: "..tostring(choice)
  requestDraw()
end
local function inputWorker()
  while true do
    local e,a,b,c=os.pullEvent()
    if e=="char" then
      if a=="q" then save(controls);return end
      enqueue(keyboardChoice(a))
    elseif e=="key" then
      if a==keys.q then save(controls);return end
      if a==keys.one then page="overview" elseif a==keys.two then page="raw" elseif a==keys.three then page="setup" elseif a==keys.four then page="gates" end
      requestDraw()
    elseif e=="monitor_touch" and binding.monitor and a==binding.monitor then
      if c==3 then page=b<=10 and "overview" or b<=21 and "raw" or b<=29 and "setup" or "gates";requestDraw()
      else
        local choice=hit(buttons,b,c)
        if choice=="BACK" then page="overview";requestDraw() else enqueue(choice) end
      end
    elseif e=="peripheral" or e=="peripheral_detach" then
      binding=inspect()
      target=binding.monitor and peripheral.wrap(binding.monitor) or computer
      compactMonitor(target,binding.monitor~=nil)
      gateApplied={};gateCommands={};reactorCommands={}
      controls.inputControlVerified=false;controls.outputControlVerified=false;controls.gatesOwned=false
      data=nil
      requestDraw()
    end
  end
end
local function controlWorker()
  local timer=os.startTimer(.2)
  local ticks=0
  local lastTelemetry=os.clock()
  while true do
    local e,id=os.pullEvent("timer")
    if id==timer then
      local safeHandled=false
      if actions[1]=="SAFE SHUTDOWN" then
        actions={};safeHandled=true;act("SAFE SHUTDOWN",data or {})
        if binding.ready then gate(binding.output,0);reactor(binding.reactor,"stopReactor") end
      end
      local nextData,readError
      if binding.ready then nextData,readError=read(binding) end
      if nextData then
        data=nextData;lastTelemetry=os.clock();controls.telemetryStale=false;controls.telemetryAge=0
        if not controls.gatesOwned then acquireGates(binding,data,controls) end
        if not safeHandled then while #actions>0 do act(table.remove(actions,1),data) end end
        supervise(binding,data,controls)
      else
        controls.telemetryAge=os.clock()-lastTelemetry
        controls.telemetryStale=controls.telemetryAge>=2
        if controls.telemetryStale and binding.ready then
          gate(binding.output,0);reactor(binding.reactor,"stopReactor")
          controls.message="TELEMETRY STALE: export closed, reactor stop requested"
        elseif readError then controls.message="Telemetry retry: "..tostring(readError) end
      end
      ticks=ticks+1
      if ticks%2==0 then requestDraw() end
      if ticks>=5 then ticks=0;save(controls) end
      timer=os.startTimer(.2)
    end
  end
end
local function displayWorker()
  redraw()
  while true do os.pullEvent(DRAW_EVENT);redraw() end
end
local function facilityWorker()
  if not facilityNetwork or not facilityProtocol or not facilityIdentity then
    while true do os.pullEvent("guardian_network_disabled") end
  end
  local function send(kind,payload,target)
    facilitySequence=facilitySequence+1
    local message=facilityProtocol.make(kind,facilityIdentity,facilitySequence,payload,facilityNetwork.now())
    if not message then return end
    if target then facilityNetwork.sendOn(facilityProtocol.rednetProtocol,target,message)
    else facilityNetwork.broadcastOn(facilityProtocol.rednetProtocol,message) end
  end
  local function snapshot()
    local r=data and data.reactor or {}
    local imminent,alarmMessage=imminentMeltdown(r)
    return {
      siteId=facilitySiteId,facilityType="draconic_reactor",state=tostring(r.status or "unknown"),
      generationRate=tonumber(r.generationRate),temperature=tonumber(r.temperature),
      fieldStrength=tonumber(r.fieldStrength),maxFieldStrength=tonumber(r.maxFieldStrength),
      fieldDrainRate=tonumber(r.fieldDrainRate),
      energySaturation=tonumber(r.energySaturation),maxEnergySaturation=tonumber(r.maxEnergySaturation),
      fuelConversion=tonumber(r.fuelConversion),maxFuelConversion=tonumber(r.maxFuelConversion),
      fieldGate=tonumber(data and data.inputSet),exportGate=tonumber(data and data.outputSet),
      fieldInput=tonumber(data and data.inputFlow),exportFlow=tonumber(data and data.outputFlow),
      mode=controls.mode,request=controls.request,commissioned=controls.commissioned==true,
      ratedOutput=tonumber(controls.rated),localAuthority=true,remoteCommands=false,
      guardianMessage=tostring(controls.message or ""),telemetryStale=controls.telemetryStale==true,
      alarmLevel=imminent and 3 or nil,
      alarmCode=imminent and "draconic_meltdown_imminent" or nil,
      alarmMessage=alarmMessage,
    }
  end
  local function hello(target)
    send("hello",{siteId=facilitySiteId,facilityType="draconic_reactor",capabilities={"telemetry","heartbeat","local_guardian","ui_profile"},uiProfile="draconic_guardian"},target)
  end
  local function releaseCollector()
    facilityCollectorId,facilityCollectorRole,facilityCollectorPriority=nil,nil,-1
    facilityCollectorLeaseUntil=0;facilityConnected=false;facilityLastWelcome=nil
    requestDraw()
  end
  hello()
  local heartbeat=os.startTimer(1)
  local helloTimer=os.startTimer(5)
  while true do
    local event,a,b,c=os.pullEvent()
    if event=="timer" and a==heartbeat then
      local now=facilityNetwork.now()
      if facilityCollectorId and now>=facilityCollectorLeaseUntil then
        releaseCollector()
      end
      if facilityCollectorId then send("telemetry",snapshot(),facilityCollectorId) end
      heartbeat=os.startTimer(1)
    elseif event=="timer" and a==helloTimer then
      if not facilityCollectorId then hello() end
      helloTimer=os.startTimer(5)
    elseif event=="rednet_message" and c==facilityProtocol.rednetProtocol then
      local message=facilityProtocol.validate(b)
      if message and message.payload.siteId==facilitySiteId then
        local role=message.source.role
        local priority=tonumber(message.payload.collectorPriority) or (role=="overseer" and 100 or 50)
        local lease=math.max(2,math.min(30,tonumber(message.payload.leaseSeconds) or 5))
        if message.kind=="collector_presence" and (role=="mainframe" or role=="overseer") then
          if a==facilityCollectorId then
            facilityCollectorLeaseUntil=facilityNetwork.now()+lease
          elseif not facilityCollectorId or priority>facilityCollectorPriority then hello(a) end
        elseif message.kind=="welcome" and (role=="mainframe" or role=="overseer") and
               (not facilityCollectorId or a==facilityCollectorId or priority>facilityCollectorPriority) then
          facilityCollectorId,facilityCollectorRole,facilityCollectorPriority=a,role,priority
          facilityCollectorLeaseUntil=facilityNetwork.now()+lease
          facilityConnected=true;facilityLastWelcome=facilityNetwork.now();requestDraw()
        elseif message.kind=="acknowledgement" and a==facilityCollectorId then
          facilityCollectorLeaseUntil=facilityNetwork.now()+lease
          facilityConnected=true;facilityLastWelcome=facilityNetwork.now()
        elseif message.kind=="emergency_command" and a==facilityCollectorId and
               (role=="mainframe" or role=="overseer") and
               message.payload.targetNodeId==facilityIdentity.nodeId and
               message.payload.action=="scram" then
          actions={"SAFE SHUTDOWN"}
          controls.message="REMOTE SCRAM REQUEST ACCEPTED FROM "..string.upper(role)
          send("status",{
            siteId=facilitySiteId,commandMessageId=message.messageId,
            action="scram",status="accepted",
          },a)
          requestDraw()
        end
      end
    elseif event=="peripheral" or event=="peripheral_detach" then facilityNetwork.openAll() end
  end
end
local function profilerWorker()
  local modemName,modem
  local names=peripheral.getNames();sort(names)
  for _,name in ipairs(names) do
    local candidate=peripheral.wrap(name)
    if candidate and type(candidate.isWireless)=="function" then
      local ok,wireless=pcall(candidate.isWireless)
      if ok and wireless then modemName,modem=name,candidate;break end
    end
  end
  if not modem then while true do os.pullEvent("guardian_profiler_wireless_disabled") end end
  modem.open(PROFILER_REQUEST_CHANNEL)
  local profilerId,leaseUntil
  local timer=os.startTimer(1)
  local function snapshot()
    local r=data and data.reactor or {}
    local imminent,alarmMessage=imminentMeltdown(r)
    return {
      state=tostring(r.status or "unknown"),generationRate=tonumber(r.generationRate),
      temperature=tonumber(r.temperature),fieldStrength=tonumber(r.fieldStrength),
      maxFieldStrength=tonumber(r.maxFieldStrength),fieldDrainRate=tonumber(r.fieldDrainRate),
      energySaturation=tonumber(r.energySaturation),maxEnergySaturation=tonumber(r.maxEnergySaturation),
      fuelConversion=tonumber(r.fuelConversion),maxFuelConversion=tonumber(r.maxFuelConversion),
      fieldInput=tonumber(data and data.inputFlow),fieldGate=tonumber(data and data.inputSet),
      exportFlow=tonumber(data and data.outputFlow),exportGate=tonumber(data and data.outputSet),
      mode=controls.mode,request=controls.request,commissioned=controls.commissioned==true,
      ratedOutput=tonumber(controls.rated),guardianMessage=tostring(controls.message or ""),
      telemetryStale=controls.telemetryStale==true,alarmLevel=imminent and 3 or nil,
      alarmMessage=alarmMessage,
    }
  end
  while true do
    local event,a,channel,replyChannel,message=os.pullEvent()
    if event=="modem_message" and a==modemName and channel==PROFILER_REQUEST_CHANNEL and
       type(message)=="table" and message.heliosProfiler==true and message.version==1 and
       message.kind=="subscribe" and tonumber(message.targetGuardianId)==os.getComputerID() and
       tonumber(message.profilerId) then
      profilerId=tonumber(message.profilerId);leaseUntil=os.epoch("utc")/1000+10
    elseif event=="timer" and a==timer then
      local now=os.epoch("utc")/1000
      if profilerId and leaseUntil and now<leaseUntil then
        modem.transmit(PROFILER_TELEMETRY_CHANNEL,PROFILER_REQUEST_CHANNEL,{
          heliosProfiler=true,version=1,kind="telemetry",guardianId=os.getComputerID(),
          guardianVersion=GUARDIAN_VERSION,targetProfilerId=profilerId,sentAt=now,payload=snapshot(),
        })
      elseif leaseUntil and now>=leaseUntil then profilerId,leaseUntil=nil,nil end
      timer=os.startTimer(1)
    elseif event=="peripheral_detach" and a==modemName then
      -- Losing this optional read-only link must never stop the Guardian.
      while true do os.pullEvent("guardian_profiler_wireless_disabled") end
    end
  end
end
parallel.waitForAny(inputWorker,controlWorker,displayWorker,facilityWorker,profilerWorker)
save(controls)
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

local function buildConfig(role, display, existing, profilerGuardianId)
    existing = type(existing) == "table" and existing or {}
    local discovery = type(existing.discovery) == "table" and existing.discovery or {}
    local alarms = type(existing.alarms) == "table" and existing.alarms or {}
    local uiSettings = type(existing.ui) == "table" and existing.ui or {}
    local power = type(existing.power) == "table" and existing.power or {}
    local ratios = type(power.ratios) == "table" and power.ratios or {}
    local control = type(existing.control) == "table" and existing.control or {}
    local aliases = type(existing.deviceAliases) == "table" and existing.deviceAliases or {}
    local networkSettings = type(existing.network) == "table" and existing.network or {}
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
            renderer = type(uiSettings.renderer) == "string" and uiSettings.renderer or "default",
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
            mainframeAuthority = role == "mainframe" and "auto" or "monitor",
            targetRpm = tonumber(control.targetRpm) or 1800,
            rpmDeadband = math.max(1, tonumber(control.rpmDeadband) or 25),
            overspeedRpm = math.max((tonumber(control.targetRpm) or 1800) +
                math.max(1, tonumber(control.rpmDeadband) or 25),
                tonumber(control.overspeedRpm) or 2000),
            overspeedSamples = math.max(1,
                math.floor(tonumber(control.overspeedSamples) or 3)),
            storageLow = tonumber(control.storageLow) or 25,
            storageHigh = tonumber(control.storageHigh) or 85,
            assistedIdleRpmRatio = math.max(0.25, math.min(0.95,
                tonumber(control.assistedIdleRpmRatio) or 0.75)),
            assistedIdleFlow = math.max(1,
                tonumber(control.assistedIdleFlow) or 250),
            maxRodStep = tonumber(control.maxRodStep) or 5,
            reactorAdjustmentInterval = math.max(2,
                tonumber(control.reactorAdjustmentInterval) or 5),
            reactorCommandSamples = math.max(2,
                math.floor(tonumber(control.reactorCommandSamples) or 3)),
            reactorSteamDeadband = math.max(0.005, math.min(0.25,
                tonumber(control.reactorSteamDeadband) or 0.01)),
            reactorSteamDeadbandMin = math.max(1,
                tonumber(control.reactorSteamDeadbandMin) or 25),
            reactorSteamReserveMargin = 0.15,
            reactorSteamPrimeMargin = math.max(0.15, math.min(2,
                tonumber(control.reactorSteamPrimeMargin) or 0.90)),
            reactorSteamAverageSamples = math.max(3,
                math.floor(tonumber(control.reactorSteamAverageSamples) or 10)),
            reactorHotFluidHigh = math.max(50, math.min(99,
                tonumber(control.reactorHotFluidHigh) or 85)),
            calibrationBufferReady = math.max(50, math.min(
                math.max(50, math.min(99,
                    tonumber(control.reactorHotFluidHigh) or 85)),
                tonumber(control.calibrationBufferReady) or 85)),
            reactorHotFluidLow = math.max(1, math.min(84,
                tonumber(control.reactorHotFluidLow) or 15)),
            maxRodEquivalentStep = math.max(0.01, math.min(1,
                tonumber(control.maxRodEquivalentStep) or 0.25)),
            reactorLearningSamples = math.max(3,
                math.floor(tonumber(control.reactorLearningSamples) or 8)),
            reactorLearningSteamDelta = math.max(1,
                tonumber(control.reactorLearningSteamDelta) or 10),
            reactorLearningSteamTolerance = math.max(0.005, math.min(0.25,
                tonumber(control.reactorLearningSteamTolerance) or 0.05)),
            reactorLearningTemperatureDelta = math.max(0.01,
                tonumber(control.reactorLearningTemperatureDelta) or 0.1),
            reactorLearningBufferDelta = math.max(0.01,
                tonumber(control.reactorLearningBufferDelta) or 0.1),
            reactorMinimumResponseTime = math.max(5,
                tonumber(control.reactorMinimumResponseTime) or 15),
            reactorSettleTimeout = math.max(
                math.max(5, tonumber(control.reactorMinimumResponseTime) or 15) + 5,
                tonumber(control.reactorSettleTimeout) or 90),
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
            powerReactorProfiles = type(control.powerReactorProfiles) == "table" and
                control.powerReactorProfiles or {},
            powerReactorCalibrationSamples = math.max(3,
                math.floor(tonumber(control.powerReactorCalibrationSamples) or 10)),
            reactorCommissioningSteamTarget = math.max(1,
                tonumber(control.reactorCommissioningSteamTarget) or 1000),
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
        network = {
            siteId = type(networkSettings.siteId) == "string" and
                networkSettings.siteId ~= "" and networkSettings.siteId or "default",
            guardianId = role == "profiler" and tonumber(profilerGuardianId) or
                tonumber(networkSettings.guardianId),
        },
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
    local selection = choose("Select an installation category:", {
        { label = "Install Mainframe", value = "mainframe" },
        { label = "Install Remote Terminal", value = "terminal" },
        { label = "Modules", value = "modules" },
    })
    local role = selection
    local installLabel
    if selection == "modules" then
        title("Modules")
        local module = choose("Select a module:", {
            { label = "Hardware Probe (run once, read-only)", value = "probe" },
            { label = "Draconic Reactor Guardian", value = "guardian" },
            { label = "Draconic Reactor Profiler (read-only)", value = "profiler" },
        })
        if module == "probe" then
            local temporaryProbe = "/.helios-probe-run.lua"
            if fs.exists(temporaryProbe) then fs.delete(temporaryProbe) end
            writeFile(temporaryProbe, FILES["tools/discovery_probe.lua"])
            local ran, reason = shell.run(temporaryProbe)
            if fs.exists(temporaryProbe) then fs.delete(temporaryProbe) end
            if not ran then error("Probe failed: " .. tostring(reason), 0) end
            return
        end
        role = module
        installLabel = module == "guardian" and "Module: Draconic Reactor Guardian" or
            "Module: Draconic Reactor Profiler (read-only)"
    end

    if role == "mainframe" and not (existingConfig and existingConfig.role == "mainframe") then
        title("Checking HELIOS Network")
        print("Looking for an existing mainframe...")
        local existingMainframe = findExistingMainframe(3)
        if existingMainframe then
            error("Mainframe " .. tostring(existingMainframe) ..
                " is already managing this HELIOS network. Install this computer as a " ..
                "Remote Terminal instead.", 0)
        end
        term.setTextColor(colors.lime)
        print("No existing HELIOS mainframe found.")
        term.setTextColor(colors.white)
    end

    local display
    local profilerGuardianId
    if role == "terminal" then
        title("Remote Terminal Configuration")
        display = choose("Select the information this terminal will request:", {
            { label = "Reactor", value = "reactor" },
            { label = "Turbine", value = "turbine" },
            { label = "Battery", value = "battery" },
            { label = "All systems overview", value = "all" },
        })
    end

    if role == "profiler" then
        title("Profiler Pairing")
        print("Enter the computer ID shown by the Draconic Guardian:")
        profilerGuardianId = tonumber(read())
        if not profilerGuardianId or profilerGuardianId < 0 or
           profilerGuardianId ~= math.floor(profilerGuardianId) then
            error("Guardian computer ID must be a whole number.", 0)
        end
    end

    title("Ready to Install")
    print(installLabel or ("Role: " .. role))
    if display then print("Display: " .. display) end
    if profilerGuardianId then print("Guardian computer ID: " .. profilerGuardianId) end
    print("Location: " .. INSTALL_DIR)
    print("")
    if not confirm("Install HELIOS?") then
        print("Installation cancelled.")
        return
    end

    local configText = buildConfig(role, display, existingConfig, profilerGuardianId)
    local requiredBytes = embeddedInstallBytes(configText, role)
    local freeSpace = fs.getFreeSpace("/")
    local lowSpaceUpgrade = type(freeSpace) == "number" and freeSpace < requiredBytes

    if fs.exists(STAGE_DIR) then fs.delete(STAGE_DIR) end
    removeOldBackups()

    if lowSpaceUpgrade then
        title("Low-Space Upgrade")
        term.setTextColor(colors.yellow)
        print("Not enough room for a second HELIOS copy.")
        term.setTextColor(colors.white)
        print("Preserving configuration and calibration data.")
        print("Replacing installed program files in place...")
        removeReplaceableInstallFiles()
        freeSpace = fs.getFreeSpace("/")
        if type(freeSpace) == "number" and freeSpace < requiredBytes then
            error("Not enough disk space for HELIOS. Free " .. tostring(freeSpace) ..
                " bytes; approximately " .. tostring(requiredBytes) ..
                " bytes are required. Existing configuration and data were preserved.", 0)
        end
    end

    fs.makeDir(STAGE_DIR)
    for relativePath, contents in pairs(FILES) do
        writeFile(fs.combine(STAGE_DIR, relativePath), contents)
    end
    writeFile(fs.combine(STAGE_DIR, "config.lua"), configText)
    -- Runtime state belongs to the computer, not to a particular program
    -- version. Preserve Guardian calibration, facility registrations, and
    -- other HELIOS data across an ordinary staged upgrade.
    local existingData = fs.combine(INSTALL_DIR, "data")
    local stagedData = fs.combine(STAGE_DIR, "data")
    if fs.exists(existingData) and not fs.exists(stagedData) then
        fs.copy(existingData, stagedData)
    end
    local legacyGuardianState = "/.helios-draconic-guardian.lua"
    local stagedGuardianState = fs.combine(stagedData, "draconic_guardian.lua")
    if role == "guardian" and fs.exists(legacyGuardianState) and
       not fs.exists(stagedGuardianState) then
        if not fs.exists(stagedData) then fs.makeDir(stagedData) end
        fs.copy(legacyGuardianState, stagedGuardianState)
    end
    local modulePackVersion
    if role == "mainframe" then
        title("Installing Module Pack")
        print("Downloading official peripheral modules...")
        modulePackVersion = installModulePack(STAGE_DIR)
        print("Module Pack " .. tostring(modulePackVersion) .. " ready.")
    end

    local previousInstall
    if not lowSpaceUpgrade and fs.exists(INSTALL_DIR) then
        previousInstall = "/helios.previous"
        local backupNumber = 2
        while fs.exists(previousInstall) do
            previousInstall = "/helios.previous." .. backupNumber
            backupNumber = backupNumber + 1
        end
        fs.move(INSTALL_DIR, previousInstall)
    end

    local ok, reason = pcall(function()
        if lowSpaceUpgrade then
            installStageInPlace()
        else
            fs.move(STAGE_DIR, INSTALL_DIR)
        end
        writeFile("/helios.lua", [=[
shell.run("/helios/helios.lua", ...)
]=])
    end)
    if not ok then
        if previousInstall then
            if fs.exists(INSTALL_DIR) then fs.delete(INSTALL_DIR) end
            if fs.exists(previousInstall) then fs.move(previousInstall, INSTALL_DIR) end
            error("Installation failed and the previous install was restored: " .. tostring(reason), 0)
        end
        error("Installation failed during the low-space upgrade. Configuration and data " ..
            "were preserved; rerun the installer after freeing space: " .. tostring(reason), 0)
    end

    local autoStarted, startupNote = installStartup()

    title("Installation Complete")
    term.setTextColor(colors.lime)
    print("HELIOS " .. VERSION .. " installed successfully.")
    term.setTextColor(colors.white)
    print(installLabel or ("Role: " .. role))
    if modulePackVersion then print("Module Pack: " .. tostring(modulePackVersion)) end
    if display then print("Display: " .. display) end
    if profilerGuardianId then print("Guardian computer ID: " .. profilerGuardianId) end
    if previousInstall then print("Previous version: " .. previousInstall) end
    if lowSpaceUpgrade then print("Upgrade mode: low-space (configuration/data preserved)") end
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
