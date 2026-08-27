Warning: truncated output (original token count: 95834)
Total output lines: 8159

-- HELIOS single-file installer
-- Manual-control alpha: guarded direct plant authority.

local VERSION = "1.6.0-alpha.4"
local INSTALL_DIR = "/helios"
local STAGE_DIR = "/.helios-install"
local MODULE_PACK_BASE_URL = "https://raw.githubusercontent.com/ssj8vegetrunks/HELIOS/agent/ui-module-contract-alpha4/module-pack"

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
    -- The external pack is currently much smaller than this allowance. Keeping
    -- a reserve here also covers its manifest and filesystem bookkeeping.
    if role == "mainframe" then bytes = bytes + (64 * 1024) end
    return bytes
end

local function removeReplaceableInstallFiles()
    if not fs.exists(INSTALL_DIR) then return end
    for _, name in ipairs({ "core", "gui", "mainframe", "terminal", "modules", "helios.lua" }) do
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
                    m…75834 tokens truncated…ber(storage.stored) or 0)
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

    local configText = buildConfig(role, display, existingConfig)
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
    print("Role: " .. role)
    if modulePackVersion then print("Module Pack: " .. tostring(modulePackVersion)) end
    if display then print("Display: " .. display) end
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
