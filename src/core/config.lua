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
       loaded.role ~= "guardian" then
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
