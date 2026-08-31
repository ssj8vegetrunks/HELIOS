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
        end

        local function overview()
            header("PLANT OVERVIEW")
            local width = select(1, term.getSize())
            gui.text(1, 6, "SYSTEM READINESS", colors.lightGray)
            local state, detail, colour = readiness()
            gui.text(1, 7, state, colour)
            gui.text(1, 8, detail, colors.white, colors.black, width)
            gui.text(1, 10, ("REACTORS  %d   TURBINES  %d   STORAGE  %d"):format(
                #reactors, #turbines, #storages), colors.cyan)
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
            if #reactors == 0 then
                gui.text(1, 7, "NO REACTORS FOUND", colors.orange)
                return
            end
            selected.reactors = math.max(1, math.min(selected.reactors, #reactors))
            local reactor = reactors[selected.reactors]
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
            gui.text(1, 6, ("%d/%d  %s"):format(selected.reactors, #reactors,
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
                    gui = gui, powerFormat = powerFormat,
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
            elseif gui.hit(buttons.keepControl, touchX, touchY) then
                selectAuthority("control")
            elseif gui.hit(buttons.monitorOnly, touchX, touchY) then
                selectAuthority("monitor")
            elseif event == "key" and value == keys.left then
                if page == "reactors" and #reactors > 0 then
                    selected.reactors = ((selected.reactors - 2) % #reactors) + 1
                elseif page == "turbines" and #turbines > 0 then
                    selected.turbines = ((selected.turbines - 2) % #turbines) + 1
                elseif page == "storage" and #storages > 0 then
                    selected.storage = ((selected.storage - 2) % #storages) + 1
                end
            elseif event == "key" and value == keys.right then
                if page == "reactors" and #reactors > 0 then
                    selected.reactors = (selected.reactors % #reactors) + 1
                elseif page == "turbines" and #turbines > 0 then
                    selected.turbines = (selected.turbines % #turbines) + 1
                elseif page == "storage" and #storages > 0 then
                    selected.storage = (selected.storage % #storages) + 1
                end
            elseif event == "mouse_click" or event == "monitor_touch" then
                if touchY == 17 and page == "reactors" and #reactors > 0 then
                    selected.reactors = touchX < 15 and ((selected.reactors - 2) % #reactors) + 1 or
                        (selected.reactors % #reactors) + 1
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
