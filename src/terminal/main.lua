local terminal = {}

function terminal.run(config)
    local display = dofile("/helios/core/display.lua")
    display.start(config)
    local ui = dofile("/helios/core/ui.lua")
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
        previousButton = ui.button("< PREVIOUS", colors.cyan)
        nextButton = ui.button("NEXT >", colors.cyan)
        testButton = ui.button("TEST SPEAKER", colors.cyan)
    end

    local function formatValue(value, suffix)
        if value == nil then return "N/A" end
        return ("%.1f%s"):format(value, suffix or "")
    end

    local function renderReactors(state)
        renderList("REACTORS", state.reactors, state, function(item)
            ui.status("Mode", string.upper(item.mode or "unknown"))
            if item.error then ui.status("Telemetry", item.error, colors.red) return end
            ui.status("State", item.active == true and "ACTIVE" or item.active == false and "OFFLINE" or "UNKNOWN")
            ui.status("Fuel", formatValue(item.fuelPercent, "%"))
            ui.status("Fuel use", formatValue(item.fuelUse, " mB/t"))
            ui.status("Fuel temp", formatValue(item.fuelTemperature, " C"))
            ui.status("Casing temp", formatValue(item.casingTemperature, " C"))
            if item.mode == "steam" then
                ui.status("Steam output", formatValue(item.steamProduction, " mB/t"), colors.cyan)
                ui.status("Coolant", formatValue(item.coolantPercent, "%"))
                ui.status("Hot fluid", formatValue(item.hotFluidPercent, "%"))
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
            ui.status("Power output", powerFormat.power(item.energyProduction, state.power, true), colors.cyan)
            ui.status("Energy buffer", formatValue(item.energyPercent, "%"))
            ui.status("Fluid flow", formatValue(item.flowRate, " mB/t"))
            ui.status("Max flow", formatValue(item.flowRateMax, " mB/t"))
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
