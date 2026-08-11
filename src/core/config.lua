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
    loaded.control.maxRodStep = tonumber(loaded.control.maxRodStep) or 5
    loaded.control.maxFlowStep = tonumber(loaded.control.maxFlowStep) or 100
    loaded.control.adjustmentInterval = tonumber(loaded.control.adjustmentInterval) or 2
    loaded.control.commandSamples = math.max(1,
        math.floor(tonumber(loaded.control.commandSamples) or 2))
    loaded.control.lowBandRpm = tonumber(loaded.control.lowBandRpm) or 900
    loaded.control.highBandRpm = tonumber(loaded.control.highBandRpm) or 1800
    loaded.control.calibrationSpoolRpm = tonumber(loaded.control.calibrationSpoolRpm) or
        loaded.control.highBandRpm
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
    loaded.control.calibrationTimeout = math.max(60,
        tonumber(loaded.control.calibrationTimeout) or 600)
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
