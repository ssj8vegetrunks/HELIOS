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
        local generation = sum(snapshot.reactors, "energyProduction") + sum(snapshot.turbines, "energyProduction")
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
            line("  " .. tostring(plan.reason or (reactor.active and "ONLINE" or "OFFLINE")), colors.lightGray)
        end
        for _, turbine in ipairs(snapshot.turbines or {}) do
            local plan = turbine.governor or {}
            line("T " .. nameOf(turbine.name, snapshot) .. ": " .. tostring(plan.state or "MONITORING"), colors.cyan)
            line("  " .. tostring(plan.reason or (turbine.active and "ONLINE" or "OFFLINE")), colors.lightGray)
        end
        line(("Storage reserve %.1f%%"):format(reserve), reserve < 20 and colors.orange or colors.lime)
        gui.text(rightX, height - 1, "+" .. string.rep("-", rightWidth - 2) .. "+", colors.gray)
    else
        local list = state.page == "reactors" and (snapshot.reactors or {}) or
            state.page == "turbines" and (snapshot.turbines or {}) or (snapshot.storages or {})
        local key = state.page == "power" and "power" or state.page
        if #list == 0 then gui.text(1, 7, "NO DEVICES REPORTED", colors.orange) else
            state.selected[key] = math.max(1, math.min(state.selected[key] or 1, #list))
            local item = list[state.selected[key]]
            gui.text(1, 7, ("%d/%d  %s"):format(state.selected[key], #list, nameOf(item.name, snapshot)), colors.cyan)
            local row = 9
            for _, field in ipairs({"active", "state", "rotorSpeed", "steamProduction", "energyProduction", "fuelPercent", "waste", "percent", "input", "output", "stored", "capacity"}) do
                if item[field] ~= nil then gui.text(1, row, string.upper(field) .. ": " .. tostring(item[field]), colors.white); row = row + 1 end
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
