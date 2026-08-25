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
    for _, name in ipairs({ "core", "mainframe", "terminal", "modules", "helios.lua" }) do
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
    loaded.control = loaded.control or {}
    -- Manual authority is deliberately never restored after a reboot.
    loaded.control.mode = "automatic"
    loaded.control.manualSafetyReserve = math.max(0.5, math.min(25,
        tonumber(loaded.control.manualSafetyReserve) or 2))
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

-- @section DISPLAY LIFECYCLE
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

    ["helios.lua"] = [=[
-- @section PROGRAM ENTRYPOINT
local args = { ... }
local config = dofile("/helios/core/config.lua").load()

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

-- @section STARTUP AND RUNTIME STATE
function mainframe.run(config)
    local display = dofile("/helios/core/display.lua")
    display.start(config)
    local ui = dofile("/helios/core/ui.lua")
    ui.setVersion(config.version)
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
    local modemCount = network.openAll()
    local terminals = network.loadPeers()
    local missingDevices = {}
    local sessionId = network.sessionId("mainframe")
    local identityClaims = {}
    local idConflicts = {}
    local dashboardButtons = {}
    local governorMemory = turbineGovernor.new()
    local reactorGovernorMemory = reactorGovernor.new()
    local manualNotice
    local manualSafetyState = manualControl.newSafetyState()
    local minimumPowerReserve
    local returnToAutomatic

    local timeoutChoices = { 300, 900, 1800, 3600 }

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
        local now = os.epoch("utc") / 1000
        local steamPrimeRequested = turbineGovernor.needsSteamPrime(
            governorMemory, turbines)
        local _, steamDemand = reactorGovernor.evaluateAll(reactorGovernorMemory,
            reactors, turbines, config.control, {
                maintenance = maintenance or manualAuthority,
                mainframeId = os.getComputerID(),
                idConflicts = idConflicts,
                now = now,
                steamPrimeRequested = steamPrimeRequested,
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
            maintenance = maintenance or manualAuthority,
            now = now,
        }, {
            setActive = reactorAdapter.setActive,
            setControlRodExposure = reactorAdapter.setControlRodExposure,
        })

        local steamSource = reactorGovernor.steamSourceStatus(reactors,
            steamDemand, config.control)
        turbineGovernor.evaluateAll(governorMemory, turbines, config.control, {
            maintenance = maintenance or manualAuthority,
            mainframeId = os.getComputerID(),
            idConflicts = idConflicts,
            now = now,
            steamSourceManaged = steamSource.managed,
            steamSourceReady = steamSource.ready,
            steamSourceReason = steamSource.reason,
            steamSourceBufferPercent = steamSource.bufferPercent,
        })
        if turbineGovernor.consumeProfileChanges(governorMemory) then
            configStore.save(config)
        end
        turbineGovernor.applyAll(governorMemory, turbines, config.control, {
                maintenance = maintenance or manualAuthority,
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
    local function snapshotFor(assignment)
        local includeAll = assignment == "all"
        return uiContract.attach({
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
            print("")
        else
            alarmButton = nil
            silenceButton = nil
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
        print("")
        term.setTextColor(colors.gray)
        term.setCursorPos(1, height)
        write(string.sub("Keyboard: V/G/E/C/A/R/S | Q exit", 1, width))
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
                return "dashboard"
            elseif event == "key" and value == keys.v then
                return "reactors"
            elseif event == "key" and value == keys.g then
                return "turbines"
            elseif event == "key" and value == keys.e then
                return "storage"
            elseif event == "key" and value == keys.left and #reactors > 0 then
                selected = ((selected - 2) % #reactors) + 1
            elseif event == "key" and value == keys.right and #reactors > 0 then
                selected = (selected % #reactors) + 1
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
            elseif (event == "mouse_click" or event == "monitor_touch") and ui.hit(previousButton, x, y) and #reactors > 0 then
                selected = ((selected - 2) % #reactors) + 1
            elseif (event == "mouse_click" or event == "monitor_touch") and ui.hit(nextButton, x, y) and #reactors > 0 then
                selected = (selected % #reactors) + 1
            elseif (event == "mouse_click" or event == "monitor_touch") and ui.hit(backButton, x, y) then
                return "dashboard"
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

    -- @section TURBINE VIEW
    local function turbineView()
        local selected = 1
        local previousButton, nextButton, backButton
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
            elseif silenceButton and ui.hit(silenceButton, touchX, touchY) then
                silenceCurrentAlarm()
            elseif ui.hit(dashboardButtons.reactors, touchX, touchY) then openFacility("reactors")
            elseif ui.hit(dashboardButtons.turbines, touchX, touchY) then openFacility("turbines")
            elseif ui.hit(dashboardButtons.storage, touchX, touchY) then openFacility("storage")
            elseif ui.hit(dashboardButtons.control, touchX, touchY) then controlView()
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
        if previous.startRequested == true then
            result = {
                mode = "automatic",
                state = "STARTING",
                action = "START TURBINE",
                reason = "Calibration requested; activate and verify this turbine",
                trusted = true,
                currentActive = false,
                recommendedActive = true,
                activeChange = true,
                actionSamples = 1,
            }
        else
            result = hold("OFFLINE", "Turbine is not active")
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

-- @section REMOTE TERMINAL RUNTIME
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

    -- @section EVENT LOOP AND RENDERING
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
