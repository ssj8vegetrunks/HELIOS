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
                                text = "RECALIBRATION STARTED — RODS INSERTED",
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
