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
    local function tr(key, fallback)
        return services.i18n and services.i18n.get(key, nil, fallback) or fallback
    end
    local function tv(value)
        return services.i18n and services.i18n.value(value) or tostring(value or "UNKNOWN")
    end
    local width, height = term.getSize()
    state.page = state.page or "home"
    state.selected = state.selected or { reactors = 1, turbines = 1, power = 1 }
    gui.prepare()
    gui.text(1, 1, tr("dashboard.control_room", "HELIOS // CONTROL ROOM"), colors.yellow)
    gui.text(math.max(1, width - 15), 1, "GUI v1 / " .. tostring(snapshot.version), colors.yellow)
    local alarm = snapshot.alarm
    local alarmLevel = alarm and tonumber(alarm.level) or 0
    local status = alarm and (alarmLevel >= 3 and tr("dashboard.fault", "FAULT") or tr("dashboard.warning", "WARNING")) or tr("dashboard.system_ready", "SYSTEM READY")
    gui.text(1, 2, " " .. status .. " ", colors.black,
        alarm and (alarmLevel >= 3 and colors.red or colors.orange) or colors.lime)
    local buttons, x = {}, 1
    buttons.home = gui.button(x, 4, tr("nav.home", "HOME"), colors.white, state.page == "home" and colors.gray or colors.black)
    x = buttons.home.x2 + 2
    buttons.reactors = gui.button(x, 4, tr("nav.reactors", "REACTORS"), colors.red, state.page == "reactors" and colors.gray or colors.black)
    x = buttons.reactors.x2 + 2
    buttons.turbines = gui.button(x, 4, tr("nav.turbines", "TURBINES"), colors.cyan, state.page == "turbines" and colors.gray or colors.black)
    x = buttons.turbines.x2 + 2
    buttons.power = gui.button(x, 4, tr("nav.power", "POWER"), colors.yellow, state.page == "power" and colors.gray or colors.black)
    buttons.advanced = gui.button(1, height, tr("nav.advanced", "ADVANCED"), colors.white, colors.gray)
    if services.allowEmergency and alarm and alarm.facilityNodeId then
        buttons.scram = gui.button(math.max(12, width - 8), height,
            tr("alarm.scram", "SCRAM"), colors.white, colors.red)
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
        instrument(gui, 1, 6, left, tr("dashboard.power_storage", "POWER STORAGE"), reserve,
            ("%.1f%%  %s"):format(reserve, formatter.power(stored, snapshot.power, false)),
            reserve < 20 and colors.orange or colors.lime)
        local steamScale = maximumKnown and steamMaximum > 0 and steamMaximum or math.max(1, steam)
        local steamPercent = math.min(100, steam / steamScale * 100)
        local steamRatio = demand > 0 and steam / demand or 0
        local steamColour = demand > 0 and steamRatio >= 0.95 and steamRatio <= 1.10 and
            colors.cyan or colors.orange
        instrument(gui, 1, 12, left, tr("dashboard.steam_production", "STEAM PRODUCTION"), steamPercent,
            maximumKnown and ("%.0f / %.0f mB/t"):format(steam, steamMaximum) or
                (("%.0f / LEARNING"):format(steam)), steamColour,
            maximumKnown and steamMaximum > 0 and math.min(100, demand / steamMaximum * 100) or nil)
        instrument(gui, 1, 18, left, tr("dashboard.power_production", "POWER PRODUCTION"), math.min(100, generation / math.max(1, generation + draw) * 100),
            formatter.power(generation, snapshot.power, true), colors.lime)
        instrument(gui, 1, 24, left, tr("dashboard.net_power_flow", "NET POWER FLOW"), net >= 0 and math.min(100, 50 + net / math.max(1, fill + draw) * 50) or math.max(0, 50 + net / math.max(1, fill + draw) * 50),
            (net >= 0 and "+" or "") .. formatter.power(net, snapshot.power, true), net >= 0 and colors.lime or colors.orange)
        gui.text(rightX, 6, "+" .. string.rep("-", rightWidth - 2) .. "+", colors.gray)
        gui.text(rightX + 2, 7, tr("dashboard.activity", "HELIOS ACTIVITY"), colors.cyan)
        local row = 9
        local function line(text, colour)
            if row < height - 1 then gui.text(rightX + 2, row, text, colour or colors.white, colors.black, rightWidth - 4); row = row + 1 end
        end
        if alarm then line("! " .. tostring(alarm.message), alarmLevel >= 3 and colors.red or colors.orange) end
        for _, reactor in ipairs(snapshot.reactors or {}) do
            local plan = reactor.governor or {}
            line("R " .. nameOf(reactor.name, snapshot) .. ": " .. tv(plan.state or "MONITORING"), colors.orange)
            local dispatch = plan.dispatchRequested == true and tv("DISPATCHED") or
                (reactor.mode == "power" and tv("STANDBY") or nil)
            line("  " .. (dispatch and (dispatch .. " - ") or "") ..
                (plan.reason and tv(plan.reason) or tv(reactor.active and "ONLINE" or "OFFLINE")), colors.lightGray)
        end
        for _, reactor in ipairs(snapshot.facilityReactors or {}) do
            line("F " .. nameOf(reactor.name, snapshot) .. ": " ..
                (reactor.online and tv(reactor.state or "ONLINE") or tv("STALE")),
                reactor.online and colors.magenta or colors.orange)
            line("  DRACONIC " .. tr("common.guardian", "GUARDIAN") .. " - " ..
                tv(reactor.guardianMessage or reactor.mode or "MONITORING"), colors.lightGray)
        end
        for _, turbine in ipairs(snapshot.turbines or {}) do
            local plan = turbine.governor or {}
            line("T " .. nameOf(turbine.name, snapshot) .. ": " .. tv(plan.state or "MONITORING"), colors.cyan)
            line("  " .. tv(plan.dispatchMode or turbine.dispatchMode or "UNKNOWN") ..
                " - " .. tv(plan.reason or (turbine.active and "ONLINE" or "OFFLINE")), colors.lightGray)
        end
        line(tr("dashboard.storage_reserve", "Storage reserve {percent}%"):gsub("{percent}", ("%.1f"):format(reserve)), reserve < 20 and colors.orange or colors.lime)
        gui.text(rightX, height - 1, "+" .. string.rep("-", rightWidth - 2) .. "+", colors.gray)
    else
        local list = state.page == "reactors" and allReactors or
            state.page == "turbines" and (snapshot.turbines or {}) or (snapshot.storages or {})
        local key = state.page == "power" and "power" or state.page
        if #list == 0 then gui.text(1, 7, tr("dashboard.no_devices", "NO DEVICES REPORTED"), colors.orange) else
            state.selected[key] = math.max(1, math.min(state.selected[key] or 1, #list))
            local item = list[state.selected[key]]
            gui.text(1, 7, ("%d/%d  %s"):format(state.selected[key], #list, nameOf(item.name, snapshot)), colors.cyan)
            local row = 9
            if item.facility then
                local fieldPercent = percent(item.fieldStrength, item.maxFieldStrength)
                local saturationPercent = percent(item.energySaturation, item.maxEnergySaturation)
                local fuelPercent = percent(item.fuelConversion, item.maxFuelConversion)
                local details = {
                    {tr("common.type", "TYPE"), "DRACONIC / " .. tr("common.guardian", "GUARDIAN"), colors.magenta},
                    {tr("common.link", "LINK"), tv(item.online and "ONLINE" or "STALE"), item.online and colors.lime or colors.orange},
                    {tr("common.state", "STATE"), tv(item.state or "UNKNOWN"), colors.white},
                    {tr("common.generation", "GENERATION"), formatter.power(item.generationRate, snapshot.power, true), colors.cyan},
                    {tr("common.core_temperature", "CORE"), item.temperature and ("%.2f C"):format(item.temperature) or "N/A", colors.orange},
                    {tr("common.field_strength", "FIELD"), fieldPercent and ("%.1f%%"):format(fieldPercent) or "N/A", colors.white},
                    {tr("common.saturation", "SATURATION"), saturationPercent and ("%.1f%%"):format(saturationPercent) or "N/A", colors.white},
                    {tr("common.fuel_conversion", "FUEL CONVERSION"), fuelPercent and ("%.1f%%"):format(fuelPercent) or "N/A", colors.white},
                    {tr("common.field_gate", "FIELD GATE"), formatter.power(item.fieldGate, snapshot.power, true), colors.lime},
                    {tr("common.export_gate", "EXPORT GATE"), formatter.power(item.exportGate, snapshot.power, true), colors.lime},
                    {tr("common.guardian", "GUARDIAN"), tv(item.mode or "UNKNOWN") .. " / " .. tv(item.request or "UNKNOWN"), colors.orange},
                    {tr("common.version", "VERSION"), tostring(item.softwareVersion or "UNKNOWN"), colors.lightGray},
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
                local labels = {
                    active = "common.state", state = "common.state", rotorSpeed = "common.rotor_speed",
                    energyProduction = "common.generation", input = "common.input", output = "common.output",
                    stored = "common.stored", capacity = "common.capacity", percent = "common.charge",
                    fuelPercent = "common.fuel",
                }
                for _, field in ipairs({"active", "state", "dispatchMode", "powerDispatchRequested", "rotorSpeed", "steamProduction", "energyProduction", "fuelPercent", "waste", "percent", "input", "output", "stored", "capacity"}) do
                    if item[field] ~= nil then
                        local value = (field == "active" or field == "state" or field == "dispatchMode") and tv(item[field]) or tostring(item[field])
                        gui.text(1, row, tr(labels[field] or ("telemetry." .. field), string.upper(field)) .. ": " .. value, colors.white)
                        row = row + 1
                    end
                end
            end
            local plan = item.governor or {}
            if plan.state then gui.text(1, row + 1, tr("common.governor", "GOVERNOR") .. ": " .. tv(plan.state), colors.orange) end
            if plan.reason then gui.text(1, row + 2, tv(plan.reason), colors.lightGray, colors.black, width) end
            buttons.previous = gui.button(1, height - 2, "< " .. tr("common.previous", "PREVIOUS"), colors.cyan, colors.black)
            buttons.next = gui.button(16, height - 2, tr("common.next", "NEXT") .. " >", colors.cyan, colors.black)
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
