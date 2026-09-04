local terminal = {}

-- @section REMOTE TERMINAL RUNTIME
function terminal.run(config)
    local display = dofile("/helios/core/display.lua")
    display.start(config)
    local ui = dofile("/helios/core/ui.lua")
    ui.setVersion(config.version)
    local language = dofile("/helios/core/i18n.lua").new(config)
    local function tr(key, values, fallback) return language.get(key, values, fallback) end
    local function tv(value) return language.value(value) end
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
            ui.status(tr("common.state"), tv(item.active == true and "ACTIVE" or item.active == false and "OFFLINE" or "UNKNOWN"))
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
                ui.status(tr("common.governor"), tv(plan.state or "WAITING") .. " / " ..
                    tv(plan.actuatorState or "WAITING"),
                    (plan.trusted == false or plan.actuatorState == "FAULT") and
                        colors.red or
                    ((plan.state == "STEAM DEFICIT" or
                      plan.state == "STEAM SURPLUS") and colors.orange or colors.lime))
            else
                ui.status(tr("common.power_output"), powerFormat.power(item.energyProduction, state.power, true), colors.cyan)
                ui.status(tr("common.energy_buffer"), formatValue(item.energyPercent, "%"))
            end
        end)
    end

    local function renderTurbines(state)
        renderList("TURBINES", state.turbines, state, function(item)
            if item.error then ui.status("Telemetry", item.error, colors.red) return end
            ui.status(tr("common.state"), tv(item.active == true and "ACTIVE" or item.active == false and "OFFLINE" or "UNKNOWN"))
            ui.status(tr("common.rotor_speed"), formatValue(item.rotorSpeed, " RPM"), colors.cyan)
            local plan = item.governor or {}
            ui.status(tr("common.governor"), tv(plan.state or "WAITING") .. " / " ..
                tv(plan.actuatorState or "WAITING"),
                (plan.trusted == false or plan.actuatorState == "FAULT") and colors.red or colors.lime)
            ui.status(tr("common.power_output"), powerFormat.power(item.energyProduction, state.power, true), colors.cyan)
            ui.status(tr("common.energy_buffer"), formatValue(item.energyPercent, "%"))
            if plan.currentFlow ~= nil and plan.recommendedFlow ~= nil then
                ui.status("Flow actual/set/plan", ("%s / %.0f -> %.0f"):format(
                    plan.actualFlow and ("%.0f"):format(plan.actualFlow) or "N/A",
                    plan.currentFlow, plan.recommendedFlow), colors.cyan)
            else
                ui.status("Flow actual/set/plan", "N/A / HOLD", colors.gray)
            end
            ui.status(tr("common.inductor"), tv(item.inductorEngaged == true and "ENGAGED" or item.inductorEngaged == false and "DISENGAGED" or "N/A"))
        end)
    end

    local function renderStorage(state)
        renderList("STORAGE", state.storages, state, function(item)
            ui.status(tr("common.driver"), item.adapterName or tv("UNKNOWN"), item.fallback and colors.orange or colors.lime)
            if item.error then ui.status("Telemetry", item.error, colors.red) return end
            ui.status(tr("common.charge"), formatValue(item.percent, "%"), colors.cyan)
            ui.status(tr("common.stored"), powerFormat.power(item.stored, state.power, false) .. " / " .. powerFormat.power(item.capacity, state.power, false))
            ui.status(tr("common.input"), powerFormat.power(item.input, state.power, true))
            ui.status(tr("common.output"), powerFormat.power(item.output, state.power, true))
            ui.status(tr("common.net"), powerFormat.power(item.net, state.power, true))
            ui.status(tr("common.state"), tv(item.state or "UNKNOWN"))
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
        if link ~= "ONLINE" then return tv(link), tv(link), colors.red end
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
        local version = "v" .. tostring(config.version)
        gui.text(1, 1, language.fit("remote.screen_title", math.max(1, width - #version - 1),
            { title = title }, "HELIOS // REMOTE {title}"), colors.yellow)
        gui.text(math.max(1, width - #version + 1), 1, version, colors.yellow)
        local state, detail, colour = graphicalStatus()
        state, detail = tv(state), tv(detail)
        gui.text(1, 2, " " .. state .. " ", colors.black, colour)
        local stateWidth = gui.length(state)
        gui.text(stateWidth + 4, 2, detail, colour, colors.black,
            math.max(0, width - stateWidth - 3))
        graphicalButtons = {}
        local x = 1
        graphicalButtons.overview = gui.button(x, 4, tr("nav.home"), colors.white,
            graphicalPage == "overview" and colors.gray or colors.black)
        x = graphicalButtons.overview.x2 + 2
        graphicalButtons.reactors = gui.button(x, 4, tr("nav.reactors"), colors.red,
            graphicalPage == "reactors" and colors.gray or colors.black)
        x = graphicalButtons.reactors.x2 + 2
        graphicalButtons.turbines = gui.button(x, 4, tr("nav.turbines"), colors.cyan,
            graphicalPage == "turbines" and colors.gray or colors.black)
        x = graphicalButtons.turbines.x2 + 2
        graphicalButtons.storage = gui.button(x, 4, tr("nav.power"), colors.yellow,
            graphicalPage == "storage" and colors.gray or colors.black)
        graphicalButtons.advanced = gui.button(1, height, tr("nav.advanced"), colors.white, colors.gray)
    end

    local function graphicalOverview()
        graphicalHeader(tr("nav.overview"))
        local width = select(1, term.getSize())
        if not snapshot then
            gui.text(1, 7, tr("remote.searching_mainframe"), colors.orange)
            return
        end
        local state, detail, colour = graphicalStatus()
        state, detail = tv(state), tv(detail)
        gui.text(1, 6, tr("dashboard.system_readiness"), colors.lightGray)
        gui.text(1, 7, state, colour)
        gui.text(1, 8, detail, colors.white, colors.black, width)
        gui.text(1, 10, tr("dashboard.device_counts", {
            reactors = #(snapshot.reactors or {}), turbines = #(snapshot.turbines or {}),
            storage = #(snapshot.storages or {}),
        }, "REACTORS  {reactors}   TURBINES  {turbines}   STORAGE  {storage}"), colors.cyan)
        local stored, capacity = 0, 0
        for _, storage in ipairs(snapshot.storages or {}) do
            stored = stored + (tonumber(storage.stored) or 0)
            capacity = capacity + (tonumber(storage.capacity) or 0)
        end
        local percent = capacity > 0 and stored / capacity * 100 or 0
        gui.text(1, 12, tr("remote.combined_storage"), colors.lightGray)
        gui.progress(1, 13, math.max(10, width - 8), percent,
            percent < 20 and colors.orange or colors.lime, colors.gray)
        gui.text(math.max(1, width - 6), 13, ("%5.1f%%"):format(percent), colors.white)
        gui.text(1, 15, tr("remote.monitoring_read_only"), colors.gray)
    end

    local function graphicalReactors()
        graphicalHeader(tr("nav.reactors"))
        local list = snapshot and snapshot.reactors or {}
        local width = select(1, term.getSize())
        if #list == 0 then gui.text(1, 7, tr("remote.no_reactors"), colors.orange) return end
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
        gui.text(1, 7, ("%s %-8s  %s"):format(tr("common.type"), tv(reactor.mode or "unknown"),
            tv(reactor.active == true and "ACTIVE" or "OFFLINE")),
            reactor.active == true and colors.lime or colors.orange)
        local unit = reactor.mode == "steam" and "mB/t" or "FE/t"
        gui.text(1, 8,
            maximum and ("%s %.0f / %.0f %s"):format(tr("common.output"), output or 0, maximum, unit) or
                ("%s %.0f / %s"):format(tr("common.output"), output or 0, tv("LEARNING")),
            colors.lightGray, colors.black, width)
        if target then
            gui.text(1, 9, ("%s %.0f %s"):format(tr("common.demand"), target, unit), colors.yellow)
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
        gui.text(1, 12, tr("common.fuel"), colors.lightGray)
        gui.progress(1, 13, math.max(10, width - 10), reactor.fuelPercent or 0,
            (reactor.fuelPercent or 0) < 20 and colors.orange or colors.lime, colors.gray)
        gui.text(math.max(1, width - 8), 13,
            reactor.fuelPercent and ("%6.1f%%"):format(reactor.fuelPercent) or "N/A")
        local buffer = reactor.mode == "steam" and reactor.hotFluidPercent or reactor.energyPercent
        gui.text(1, 15, ("%s %s mB"):format(tr("dashboard.cyanite"),
            reactor.waste and ("%.0f"):format(reactor.waste) or "N/A"), colors.cyan)
        gui.text(math.max(24, width - 16), 15, ("%s %s"):format(tr("common.buffer"),
            buffer and ("%.1f%%"):format(buffer) or "N/A"), colors.cyan)
        graphicalButtons.previous = gui.button(1, 17, "<", colors.cyan, colors.black)
        graphicalButtons.next = gui.button(15, 17, ">", colors.cyan, colors.black)
    end

    local function graphicalTurbines()
        graphicalHeader(tr("nav.turbines"))
        local list = snapshot and snapshot.turbines or {}
        local width = select(1, term.getSize())
        if #list == 0 then gui.text(1, 7, tr("remote.no_turbines"), colors.orange) return end
        selected = math.max(1, math.min(selected, #list))
        local turbine = list[selected]
        local rpm = tonumber(turbine.rotorSpeed) or 0
        gui.text(1, 6, ("%d/%d  %s"):format(selected, #list,
            nameOf(turbine.name, snapshot)), colors.cyan, colors.black, width)
        gui.text(1, 7, tv(turbine.active == true and "ACTIVE" or "OFFLINE"),
            turbine.active == true and colors.lime or colors.orange)
        gui.text(1, 9, ("%s %.1f RPM"):format(tr("common.rotor_speed"), rpm), rpm >= 1900 and colors.red or colors.white)
        local gaugeWidth = math.max(20, width - 1)
        gui.rpmGauge(1, 10, gaugeWidth, rpm)
        local lowLabel, highLabel = "[900 RPM]", "[1800 RPM]"
        gui.text(math.max(1, math.floor(900 / 2100 * (gaugeWidth - 1)) - 3),
            11, lowLabel, colors.lime)
        gui.text(math.min(width - #highLabel + 1,
            math.floor(1800 / 2100 * (gaugeWidth - 1)) - 3), 11, highLabel, colors.lime)
        gui.text(1, 13, tr("common.state") .. " " .. tv(turbine.governor and turbine.governor.state or "WAITING"))
        gui.text(1, 14, tr("common.output") .. " " .. powerFormat.power(turbine.energyProduction,
            snapshot.power, true), colors.cyan)
        graphicalButtons.previous = gui.button(1, 16, "<", colors.cyan, colors.black)
        graphicalButtons.next = gui.button(15, 16, ">", colors.cyan, colors.black)
    end

    local function graphicalStorage()
        graphicalHeader(tr("dashboard.power_storage"))
        local list = snapshot and snapshot.storages or {}
        local width = select(1, term.getSize())
        if #list == 0 then gui.text(1, 7, tr("remote.no_storage"), colors.orange) return end
        selected = math.max(1, math.min(selected, #list))
        local storage = list[selected]
        gui.text(1, 6, ("%d/%d  %s"):format(selected, #list,
            nameOf(storage.name, snapshot)), colors.cyan, colors.black, width)
        gui.text(1, 8, tr("common.capacity"), colors.lightGray)
        gui.progress(1, 9, math.max(10, width - 10), storage.percent or 0,
            (storage.percent or 0) < 20 and colors.orange or colors.lime, colors.gray)
        gui.text(math.max(1, width - 8), 9,
            storage.percent and ("%6.1f%%"):format(storage.percent) or "N/A")
        gui.text(1, 11, tr("common.stored") .. "  " .. powerFormat.power(storage.stored, snapshot.power, false))
        gui.text(1, 12, tr("common.input") .. "    " .. powerFormat.power(storage.input, snapshot.power, true), colors.lime)
        gui.text(1, 13, tr("common.output") .. "    " .. powerFormat.power(storage.output, snapshot.power, true), colors.orange)
        gui.text(1, 14, tr("common.state") .. "   " .. tv(storage.state or "UNKNOWN"), colors.cyan)
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
                gui = gui, powerFormat = powerFormat, i18n = language,
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
