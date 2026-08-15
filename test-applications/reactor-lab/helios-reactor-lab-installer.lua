-- HELIOS Reactor Lab single-file installer
local VERSION = "0.1.0-test"
local ROOT = "/helios-reactor-lab"
local FILES = {
    ["core/display.lua"] = [=[
local display = {}

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
    ["core/ui.lua"] = [=[
local ui = {}
local idConflicts = {}
local systemVersion

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

function ui.prepare()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
end

function ui.header(role, subtitle)
    ui.prepare()
    if #idConflicts > 0 then
        local width = select(1, term.getSize())
        term.setBackgroundColor(colors.red)
        term.setTextColor(colors.white)
        local warning = " ID CONFLICT: " .. table.concat(idConflicts, ", ") .. " "
        print(string.sub(warning .. string.rep(" ", width), 1, width))
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
    term.setTextColor(colors.gray)
    print(string.rep("-", math.min(select(1, term.getSize()), 40)))
    term.setTextColor(colors.white)
end

function ui.status(label, value, colour)
    term.setTextColor(colors.lightGray)
    write(label .. ": ")
    term.setTextColor(colour or colors.white)
    print(tostring(value))
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
    ["reactor/reactor_adapter.lua"] = [=[
local adapter = {}

local function readAny(name, availableMethods, candidates)
    for _, method in ipairs(candidates) do
        if availableMethods[method] then
            local ok, value = pcall(peripheral.call, name, method)
            if ok and value ~= nil then return value, method end
        end
    end
    return nil, nil
end

local function number(value)
    value = tonumber(value)
    if value ~= value then return nil end
    return value
end

local function percent(amount, maximum)
    amount, maximum = number(amount), number(maximum)
    if not amount or not maximum or maximum <= 0 then return nil end
    return math.max(0, math.min(100, amount / maximum * 100))
end

local function availableMethods(name)
    local methods = {}
    for _, method in ipairs(peripheral.getMethods(name) or {}) do
        methods[method] = true
    end
    return methods
end

local function rodLevels(name, methods, count)
    local levels
    if methods.getControlRodLevel and count and count > 0 then
        levels = {}
        for index = 0, count - 1 do
            local ok, value = pcall(peripheral.call, name, "getControlRodLevel", index)
            if not ok or tonumber(value) == nil then return nil end
            levels[index] = tonumber(value)
        end
    end
    if not levels and methods.getControlRodsLevels then
        local ok, values = pcall(peripheral.call, name, "getControlRodsLevels")
        if ok and type(values) == "table" then
            levels = {}
            local zeroBased = values[0] ~= nil
            for index = 0, (count or #values) - 1 do
                levels[index] = tonumber(values[zeroBased and index or (index + 1)])
                if levels[index] == nil then return nil end
            end
        end
    end
    return levels
end

local function rodSummary(levels)
    if type(levels) ~= "table" then return nil, nil, nil end
    local total, count, minimum, maximum = 0, 0
    for _, value in pairs(levels) do
        value = number(value)
        if value then
            total, count = total + value, count + 1
            minimum = minimum and math.min(minimum, value) or value
            maximum = maximum and math.max(maximum, value) or value
        end
    end
    if count == 0 then return nil, nil, nil end
    return total / count, minimum, maximum
end

function adapter.read(device)
    local name = device.name
    local reactor = { name = name, available = peripheral.isPresent(name) }
    if not reactor.available then
        reactor.error = "Peripheral unavailable"
        return reactor
    end

    local availableMethods = availableMethods(name)

    reactor.connected = readAny(name, availableMethods, { "getConnected", "isConnected", "mbIsConnected", "mbIsAssembled", "connected" })
    reactor.active = readAny(name, availableMethods, { "getActive", "isActive", "active" })
    reactor.activelyCooled = readAny(name, availableMethods, { "isActivelyCooled" })
    reactor.fuel = number(readAny(name, availableMethods, { "getFuelAmount", "fuelAmount" }))
    reactor.fuelMax = number(readAny(name, availableMethods, { "getFuelAmountMax", "getFuelCapacity", "fuelAmountMax" }))
    reactor.waste = number(readAny(name, availableMethods, { "getWasteAmount", "wasteAmount" }))
    reactor.fuelUse = number(readAny(name, availableMethods, { "getFuelConsumedLastTick", "getFuelConsumptionRate", "fuelConsumedLastTick" }))
    reactor.fuelTemperature = number(readAny(name, availableMethods, { "getFuelTemperature", "fuelTemperature" }))
    reactor.casingTemperature = number(readAny(name, availableMethods, { "getCasingTemperature", "casingTemperature" }))
    reactor.energy = number(readAny(name, availableMethods, { "getEnergyStored", "getEnergy", "energyStored" }))
    reactor.energyMax = number(readAny(name, availableMethods, { "getEnergyCapacity", "getMaxEnergyStored", "energyCapacity" }))
    reactor.energyProduction = number(readAny(name, availableMethods, { "getEnergyProducedLastTick", "getEnergyProductionRate", "energyProducedLastTick" }))
    reactor.coolant = number(readAny(name, availableMethods, { "getCoolantAmount", "coolantAmount" }))
    reactor.coolantMax = number(readAny(name, availableMethods, { "getCoolantAmountMax", "getCoolantCapacity", "coolantAmountMax" }))
    reactor.hotFluid = number(readAny(name, availableMethods, { "getHotFluidAmount", "hotFluidAmount" }))
    reactor.hotFluidMax = number(readAny(name, availableMethods, { "getHotFluidAmountMax", "getHotFluidCapacity", "hotFluidAmountMax" }))
    reactor.steamProduction = number(readAny(name, availableMethods, { "getHotFluidProducedLastTick", "getSteamProducedLastTick", "hotFluidProducedLastTick" }))
    reactor.controlRods = number(readAny(name, availableMethods, { "getNumberOfControlRods", "getControlRodCount" }))
    reactor.controlRodLevels = rodLevels(name, availableMethods, reactor.controlRods)
    reactor.controlRodLevel, reactor.controlRodMinimum, reactor.controlRodMaximum =
        rodSummary(reactor.controlRodLevels)
    if reactor.controlRodLevel and reactor.controlRods then
        reactor.controlRodExposure = reactor.controlRods *
            (100 - reactor.controlRodLevel) / 100
    end

    reactor.fuelPercent = percent(reactor.fuel, reactor.fuelMax)
    reactor.energyPercent = percent(reactor.energy, reactor.energyMax)
    reactor.coolantPercent = percent(reactor.coolant, reactor.coolantMax)
    reactor.hotFluidPercent = percent(reactor.hotFluid, reactor.hotFluidMax)

    if reactor.activelyCooled == true then
        reactor.mode = "steam"
    elseif reactor.activelyCooled == false then
        reactor.mode = "power"
    elseif (reactor.coolantMax and reactor.coolantMax > 0) or
       (reactor.hotFluidMax and reactor.hotFluidMax > 0) then
        reactor.mode = "steam"
    elseif reactor.energyMax or reactor.energyProduction then
        reactor.mode = "power"
    else
        reactor.mode = "unknown"
    end

    local useful = reactor.active ~= nil or reactor.fuel ~= nil or
        reactor.energyProduction ~= nil or reactor.steamProduction ~= nil
    if reactor.connected == false then
        reactor.error = "Reactor is not connected"
    elseif not useful then
        reactor.error = "No supported telemetry methods"
    end
    return reactor
end

function adapter.setAllControlRodLevels(reactor, requested)
    if type(reactor) ~= "table" or type(reactor.name) ~= "string" then
        return false, nil, "Invalid reactor identity"
    end
    if not peripheral.isPresent(reactor.name) then
        return false, nil, "Peripheral unavailable"
    end

    local methods = availableMethods(reactor.name)
    if not methods.setAllControlRodLevels or
       (not methods.getControlRodsLevels and not methods.getControlRodLevel) then
        return false, nil, "Verified control-rod control is unavailable"
    end

    requested = tonumber(requested)
    if not requested then return false, nil, "Invalid control-rod level" end
    requested = math.max(0, math.min(100, math.floor(requested + 0.5)))

    local ok, reason = pcall(peripheral.call, reactor.name,
        "setAllControlRodLevels", requested)
    if not ok then return false, nil, tostring(reason) end

    local count = tonumber(reactor.controlRods)
    if not count and methods.getNumberOfControlRods then
        local countOk, value = pcall(peripheral.call, reactor.name,
            "getNumberOfControlRods")
        if countOk then count = tonumber(value) end
    end
    local levels = rodLevels(reactor.name, methods, count)
    local average, minimum, maximum = rodSummary(levels)
    if average == nil then return false, nil, "Control-rod verification failed" end
    if minimum ~= requested or maximum ~= requested then
        return false, average, ("Requested %d%%; reactor reports %.0f-%.0f%%"):format(
            requested, minimum, maximum)
    end
    return true, average
end

function adapter.setActive(reactor, requested)
    if type(reactor) ~= "table" or type(reactor.name) ~= "string" then
        return false, nil, "Invalid reactor identity"
    end
    if not peripheral.isPresent(reactor.name) then
        return false, nil, "Peripheral unavailable"
    end

    local methods = availableMethods(reactor.name)
    if not methods.setActive then
        return false, nil, "Verified reactor activation control is unavailable"
    end
    local readMethod
    for _, candidate in ipairs({ "getActive", "isActive", "active" }) do
        if methods[candidate] then readMethod = candidate break end
    end
    if not readMethod then
        return false, nil, "Reactor active-state read-back is unavailable"
    end

    requested = requested == true
    local ok, reason = pcall(peripheral.call, reactor.name, "setActive", requested)
    if not ok then return false, nil, tostring(reason) end

    local readOk, actual = pcall(peripheral.call, reactor.name, readMethod)
    if not readOk or type(actual) ~= "boolean" then
        return false, nil, "Reactor activation verification failed"
    end
    if actual ~= requested then
        return false, actual, ("Requested reactor %s; reactor reports %s"):format(
            requested and "active" or "inactive",
            actual and "active" or "inactive")
    end
    return true, actual
end

local function exposureLevels(count, exposure)
    count = math.max(0, math.floor(tonumber(count) or 0))
    exposure = math.max(0, math.min(count, tonumber(exposure) or 0))
    if count < 1 then return {} end
    local exposurePoints = math.floor(exposure * 100 + 0.5)
    local pointsPerRod = math.floor(exposurePoints / count)
    local remainder = exposurePoints % count
    local levels = {}
    for index = 0, count - 1 do
        local exposedPercent = pointsPerRod + (index < remainder and 1 or 0)
        levels[index] = 100 - exposedPercent
    end
    return levels
end

local function exposureFromLevels(levels, count)
    local exposure = 0
    for index = 0, count - 1 do
        local level = tonumber(levels and levels[index])
        if level == nil then return nil end
        exposure = exposure + (100 - math.max(0, math.min(100, level))) / 100
    end
    return exposure
end

function adapter.setControlRodExposure(reactor, requestedExposure)
    if type(reactor) ~= "table" or type(reactor.name) ~= "string" then
        return false, nil, "Invalid reactor identity"
    end
    if not peripheral.isPresent(reactor.name) then
        return false, nil, "Peripheral unavailable"
    end

    local methods = availableMethods(reactor.name)
    if not methods.setControlRodLevel or not methods.getControlRodLevel then
        return false, nil, "Verified individual control-rod control is unavailable"
    end
    local count = math.floor(tonumber(reactor.controlRods) or 0)
    if count < 1 then return false, nil, "Control-rod count is unavailable" end

    local current = rodLevels(reactor.name, methods, count)
    if not current then return false, nil, "Control-rod read failed" end
    local wanted = exposureLevels(count, requestedExposure)

    -- Insert rods first, then withdraw rods. A partial failure therefore reduces
    -- reactor output instead of briefly exposing more fuel than requested.
    for pass = 1, 2 do
        for index = 0, count - 1 do
            local before, after = tonumber(current[index]), wanted[index]
            local safer = pass == 1 and after > before
            local stronger = pass == 2 and after < before
            if safer or stronger then
                local ok, reason = pcall(peripheral.call, reactor.name,
                    "setControlRodLevel", index, after)
                if not ok then
                    return false, exposureFromLevels(current, count), tostring(reason)
                end
                current[index] = after
            end
        end
    end

    local reported = rodLevels(reactor.name, methods, count)
    if not reported then return false, nil, "Control-rod verification failed" end
    for index = 0, count - 1 do
        if tonumber(reported[index]) ~= wanted[index] then
            return false, exposureFromLevels(reported, count),
                ("Rod %d requested %d%%; reactor reports %s%%"):format(
                    index, wanted[index], tostring(reported[index]))
        end
    end
    return true, exposureFromLevels(reported, count), wanted
end

function adapter.readAll(devices)
    local reactors = {}
    for _, device in ipairs(devices or {}) do
        if device.category == "reactor" then
            reactors[#reactors + 1] = adapter.read(device)
        end
    end
    return reactors
end

local function value(numberValue, suffix)
    if numberValue == nil then return "N/A" end
    return ("%.1f%s"):format(numberValue, suffix or "")
end

function adapter.printReport(reactors, config, formatter)
    print("HELIOS reactor telemetry")
    print("Reactors found: " .. #reactors)
    print("")
    for _, reactor in ipairs(reactors) do
        local alias = config.deviceAliases[reactor.name]
        local displayName = alias or reactor.name
        print(("[%s] %s"):format(string.upper(reactor.mode or "unknown"), displayName))
        if config.ui.showPeripheralNames and alias then print("  Peripheral: " .. reactor.name) end
        if reactor.error then
            print("  ERROR: " .. reactor.error)
        else
            print("  State: " .. (reactor.active == true and "ACTIVE" or reactor.active == false and "OFFLINE" or "UNKNOWN"))
            print("  Fuel: " .. value(reactor.fuelPercent, "%"))
            print("  Fuel use: " .. value(reactor.fuelUse, " mB/t"))
            print("  Fuel temp: " .. value(reactor.fuelTemperature, " C"))
            print("  Casing temp: " .. value(reactor.casingTemperature, " C"))
            if reactor.mode == "steam" then
                print("  Steam: " .. value(reactor.steamProduction, " mB/t"))
                print("  Coolant: " .. value(reactor.coolantPercent, "%"))
                print("  Hot fluid: " .. value(reactor.hotFluidPercent, "%"))
                print("  Rod insertion: " .. value(reactor.controlRodLevel, "%"))
                print("  Rod exposure: " .. value(reactor.controlRodExposure, " equivalents"))
            else
                print("  Power: " .. formatter.power(reactor.energyProduction, config.power, true))
                print("  Buffer: " .. value(reactor.energyPercent, "%"))
            end
        end
        print("")
    end
end

return adapter
]=],
    ["reactor/reactor_governor.lua"] = [=[
local governor = {}
local clearCooldown
local saveProfile

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
    local total = 0
    for _, sample in ipairs(samples) do total = total + sample end
    return total / #samples, #samples, #samples >= wanted
end

function governor.new()
    return { reactors = {}, profileDirty = false }
end

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
    }
end

clearCooldown = function(previous)
    previous.cooldownStartedAt = nil
    previous.cooldownReferenceAt = nil
    previous.cooldownReferenceSteam = nil
    previous.cooldownReferenceTemperature = nil
    previous.cooldownLastProgressAt = nil
end

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

local function observeResponse(previous, reactor, control, context, production)
    local now = tonumber(context and context.now) or 0
    local temperature = tonumber(reactor.casingTemperature)
    local buffer = tonumber(reactor.hotFluidPercent)
    local prior = previous.observation
    local steamDelta = math.max(1, tonumber(control.reactorLearningSteamDelta) or 10)
    local temperatureDelta = math.max(0.01,
        tonumber(control.reactorLearningTemperatureDelta) or 0.1)
    local bufferDelta = math.max(0.01,
        tonumber(control.reactorLearningBufferDelta) or 0.1)
    local minimumResponse = math.max(5,
        tonumber(control.reactorMinimumResponseTime) or 15)
    local processMoving, temperatureMoving = false, false

    if prior then
        processMoving = math.abs(production - prior.production) > steamDelta
        if buffer and prior.buffer then
            processMoving = processMoving or
                math.abs(buffer - prior.buffer) > bufferDelta
        end
        if temperature and prior.temperature then
            temperatureMoving =
                math.abs(temperature - prior.temperature) > temperatureDelta
        end
    end
    local waiting = previous.lastAppliedAt and now - previous.lastAppliedAt < minimumResponse
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
        buffer = buffer,
    }
    return not processMoving and not temperatureMoving and not waiting,
        processMoving or temperatureMoving or waiting, {
            waiting = waiting == true,
            processMoving = processMoving,
            temperatureMoving = temperatureMoving,
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

saveProfile = function(memory, control, name, exposure, production, target, context)
    control.reactorProfiles = control.reactorProfiles or {}
    local old = control.reactorProfiles[name]
    if not old or math.abs((tonumber(old.exposure) or -1) - exposure) >= 0.01 or
       math.abs((tonumber(old.targetSteam) or -1) - target) >= 1 then
        control.reactorProfiles[name] = {
            exposure = round(exposure, 2),
            steam = round(production, 1),
            targetSteam = round(target, 1),
            updatedAt = tonumber(context and context.now) or 0,
        }
        memory.profileDirty = true
    end
end

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
            tonumber(control.reactorSteamReserveMargin) or 0.025))
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
                clearCooldown(previous)
            end
            previous.observedRodExposure = exposure
            local production, averageSamples, averageReady = rollingSteam(previous,
                rawProduction, control)
            local requestedSteam = math.max(0, tonumber(targetSteam))
            local reserveMargin = math.max(0, math.min(0.25,
                tonumber(control.reactorSteamReserveMargin) or 0.025))
            local target = requestedSteam > 0 and
                requestedSteam * (1 + reserveMargin) or 0
            local hotFluid = tonumber(reactor.hotFluidPercent)
            local highBuffer = tonumber(control.reactorHotFluidHigh) or 85
            local lowBuffer = tonumber(control.reactorHotFluidLow) or 15
            local deadband = math.max(tonumber(control.reactorSteamDeadbandMin) or 25,
                target * (tonumber(control.reactorSteamDeadband) or 0.01))
            local maxStep = math.max(0.01, math.min(1,
                tonumber(control.maxRodEquivalentStep) or 0.25))
            local stableRequired = math.max(3,
                math.floor(tonumber(control.reactorLearningSamples) or 8))
            local profile = (control.reactorProfiles or {})[name]
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
                context, production)
            local stable = (previous.stableSamples or 0) >= stableRequired
            -- During an explicit recalibration test, steam output and hot-fluid
            -- response are sufficient to advance after the normal post-write
            -- delay. A massive casing may keep drifting long after production
            -- has settled, so temperature motion remains diagnostic but cannot
            -- hold a bounded calibration step forever.
            local calibrationStable = calibrationPhase == "ADJUSTING" and
                averageReady and not response.waiting and
                (previous.processStableSamples or 0) >= stableRequired
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
            elseif exposure <= 0.005 and production < requestedSteam - deadband and
                   type(profile) == "table" and tonumber(profile.exposure) and
                   tonumber(profile.exposure) > 0 then
                local estimate = learnedExposure(previous, profile, exposure,
                    production, target, rodCount)
                proposed = math.min(maxStep, math.max(0.01, estimate))
                state, action = "RECOVERING", "INCREASE EXPOSURE"
                reason = ("Steam is below demand; restore learned %.2f rod-equivalents"):
                    format(tonumber(profile.exposure))
            elseif (responding or not stable) and not calibrationStable then
                state = "RESPONDING"
                reason = "Waiting for steam, buffer, and casing temperature to settle"
            else
                clearCooldown(previous)
                local bufferUsable = hotFluid == nil or
                    (hotFluid > lowBuffer and hotFluid < highBuffer)
                if bufferUsable then addLearningPoint(previous, exposure, production) end

                if hotFluid and hotFluid >= highBuffer then
                    proposed = math.max(0, exposure - maxStep)
                    state, action = "BUFFER HIGH", "REDUCE EXPOSURE"
                    reason = ("Hot-fluid buffer is %.1f%%; reduce exposed fuel"):
                        format(hotFluid)
                elseif production < target - deadband then
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
                elseif production > target + deadband then
                    local estimate = learnedExposure(previous, profile, exposure,
                        production, target, rodCount)
                    proposed = math.max(exposure - maxStep,
                        math.min(exposure - 0.01, estimate))
                    state, action = "STEAM HIGH", "REDUCE EXPOSURE"
                    reason = ("Formula estimate %.2f rod-equivalents; reduce gradually"):
                        format(estimate)
                elseif bufferUsable then
                    saveProfile(memory, control, name, exposure, production, target,
                        context)
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
                steamProduction = rawProduction,
                averageSteamProduction = round(production, 1),
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
                temperatureMoving = response.temperatureMoving == true,
                hotFluidPercent = hotFluid,
                learnedProfile = profile,
                recalibrating = previous.recalibrating == true,
                calibrationPhase = previous.calibrationPhase,
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

function governor.evaluateAll(memory, reactors, turbines, control, context)
    local demand, activeTurbines, demandError = governor.steamDemand(turbines, control)
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
        reactor.governor = governor.evaluate(memory, reactor, control, reactorContext,
            demand, activeTurbines)
    end
    for name in pairs(memory.reactors or {}) do
        if not present[name] then memory.reactors[name] = nil end
    end
    return reactors, demand, activeTurbines, demandError
end

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
            if needsActive then
                previous.lastAppliedActive = applied == true
                plan.appliedActive = previous.lastAppliedActive
            else
                previous.lastAppliedRodExposure = tonumber(applied) or proposed
                plan.appliedRodExposure = previous.lastAppliedRodExposure
            end
            previous.lastError = nil
            previous.stableSamples = 0
            previous.processStableSamples = 0
            previous.productionSamples = {}
            previous.observation = nil
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
    ["main.lua"] = [=[
local lab = {}

local VERSION = "0.1.0-test"
local ROOT = "/helios-reactor-lab"
local CONFIG_PATH = ROOT .. "/config.lua"
local LOG_PATH = ROOT .. "/reactor-lab.log"

local function defaultControl()
    return {
        actuatorsEnabled = true,
        reactorAdjustmentInterval = 5,
        reactorCommandSamples = 3,
        reactorSteamDeadband = 0.01,
        reactorSteamDeadbandMin = 25,
        reactorSteamReserveMargin = 0.025,
        reactorSteamAverageSamples = 10,
        reactorHotFluidHigh = 85,
        reactorHotFluidLow = 15,
        maxRodEquivalentStep = 0.25,
        reactorLearningSamples = 8,
        reactorLearningSteamDelta = 10,
        reactorLearningTemperatureDelta = 0.1,
        reactorLearningBufferDelta = 0.1,
        reactorMinimumResponseTime = 15,
        reactorCooldownWindow = 10,
        reactorCooldownStallTimeout = 180,
        reactorCooldownSteamDelta = 2,
        reactorCooldownTemperatureDelta = 0.05,
        reactorCalibrationMaxTemperature = 150,
        reactorProfiles = {},
    }
end

local function loadConfig()
    local loaded
    if fs.exists(CONFIG_PATH) then
        local ok, value = pcall(dofile, CONFIG_PATH)
        if ok and type(value) == "table" then loaded = value end
    end
    loaded = loaded or {}
    loaded.version = VERSION
    loaded.ui = loaded.ui or { monitorTextScale = 0.5 }
    loaded.targets = loaded.targets or {}
    loaded.control = loaded.control or defaultControl()
    local defaults = defaultControl()
    for key, value in pairs(defaults) do
        if loaded.control[key] == nil then loaded.control[key] = value end
    end
    loaded.control.actuatorsEnabled = true
    loaded.control.reactorProfiles = loaded.control.reactorProfiles or {}
    return loaded
end

local function saveConfig(config)
    if not fs.exists(ROOT) then fs.makeDir(ROOT) end
    local handle, reason = fs.open(CONFIG_PATH, "w")
    if not handle then return false, reason end
    handle.write("return " .. textutils.serialize(config))
    handle.close()
    return true
end

local function appendLog(message)
    if not fs.exists(ROOT) then fs.makeDir(ROOT) end
    local handle = fs.open(LOG_PATH, "a")
    if not handle then return end
    local timestamp = os.date and os.date("!%Y-%m-%d %H:%M:%S") or tostring(os.epoch("utc"))
    handle.writeLine(("[%s] %s"):format(timestamp, tostring(message)))
    handle.close()
end

local function peripheralTypes(name)
    local result = {}
    for _, kind in ipairs({ peripheral.getType(name) }) do
        result[string.lower(tostring(kind))] = true
    end
    return result
end

local function methodsFor(name)
    local result = {}
    for _, method in ipairs(peripheral.getMethods(name) or {}) do result[method] = true end
    return result
end

local function discoverReactors()
    local devices = {}
    for _, name in ipairs(peripheral.getNames()) do
        local types = peripheralTypes(name)
        local methods = methodsFor(name)
        local named = false
        for kind in pairs(types) do
            if string.find(kind, "reactor", 1, true) then named = true break end
        end
        if named or (methods.getNumberOfControlRods and
                (methods.getCasingTemperature or methods.getFuelTemperature)) then
            devices[#devices + 1] = { name = name, category = "reactor" }
        end
    end
    table.sort(devices, function(a, b) return a.name < b.name end)
    return devices
end

local function formatNumber(value, suffix)
    if value == nil then return "N/A" end
    return ("%.1f%s"):format(value, suffix or "")
end

local function clip(value, maximum)
    local text = tostring(value or "")
    maximum = math.max(4, tonumber(maximum) or 40)
    if #text <= maximum then return text end
    return text:sub(1, maximum - 3) .. "..."
end

local function formatRodLayout(reactor, exposure)
    local minimum, maximum = tonumber(reactor.controlRodMinimum),
        tonumber(reactor.controlRodMaximum)
    local range = "N/A"
    if minimum and maximum then
        range = math.abs(maximum - minimum) < 0.05 and
            ("%.0f%%"):format(minimum) or
            ("%.0f-%.0f%%"):format(minimum, maximum)
    end
    return ("%s / %s eq"):format(range,
        exposure ~= nil and ("%.2f"):format(exposure) or "N/A")
end

function lab.run()
    local config = loadConfig()
    local display = dofile(ROOT .. "/core/display.lua")
    display.start(config)
    local ui = dofile(ROOT .. "/core/ui.lua")
    ui.setVersion("LAB " .. VERSION)
    local adapter = dofile(ROOT .. "/reactor/reactor_adapter.lua")
    local governor = dofile(ROOT .. "/reactor/reactor_governor.lua")
    local memory = governor.new()
    local devices, reactors = {}, {}
    local selected, maintenance = 1, true
    local timer
    local buttons = {}
    local lastSignature = {}

    local function selectedReactor()
        return reactors[selected]
    end

    local function targetFor(name)
        local target = tonumber(config.targets[name]) or 2000
        config.targets[name] = math.max(0, math.floor(target + 0.5))
        return config.targets[name]
    end

    local function logChanges()
        for _, reactor in ipairs(reactors) do
            local plan = reactor.governor or {}
            local signature = table.concat({
                tostring(plan.calibrationPhase or "-"),
                tostring(plan.state or "-"),
                tostring(plan.actuatorState or "-"),
                tostring(plan.currentRodExposure or "-"),
                tostring(plan.recommendedRodExposure or "-"),
                tostring(plan.actuatorError or "-"),
            }, "|")
            if lastSignature[reactor.name] ~= signature then
                appendLog(("%s phase=%s state=%s actuator=%s rods=%s->%s steam=%s target=%s reason=%s error=%s"):
                    format(reactor.name, tostring(plan.calibrationPhase or "-"),
                        tostring(plan.state or "-"), tostring(plan.actuatorState or "-"),
                        tostring(plan.currentRodExposure or "-"),
                        tostring(plan.recommendedRodExposure or "-"),
                        tostring(plan.averageSteamProduction or reactor.steamProduction or "-"),
                        tostring(plan.targetSteam or "-"), tostring(plan.reason or "-"),
                        tostring(plan.actuatorError or "-")))
                lastSignature[reactor.name] = signature
            end
        end
    end

    local function poll()
        devices = discoverReactors()
        reactors = adapter.readAll(devices)
        if selected > #reactors then selected = math.max(1, #reactors) end
        local now = os.epoch("utc") / 1000
        for _, reactor in ipairs(reactors) do
            local target = reactor.mode == "steam" and targetFor(reactor.name) or nil
            reactor.governor = governor.evaluate(memory, reactor, config.control, {
                maintenance = maintenance,
                now = now,
            }, target, target and 1 or 0)
            governor.apply(memory, reactor, config.control, {
                maintenance = maintenance,
                now = now,
            }, {
                setActive = adapter.setActive,
                setControlRodExposure = adapter.setControlRodExposure,
            })
        end
        if governor.consumeProfileChanges(memory) then saveConfig(config) end
        logChanges()
    end

    local function draw()
        ui.header("REACTOR LAB", "Isolated steam-reactor calibration")
        ui.status("Authority", maintenance and "HOLD — NO WRITES" or "AUTOMATIC TEST",
            maintenance and colors.orange or colors.lime)
        if #reactors == 0 then
            print("")
            print("Attach a wired/wireless modem network to a reactor computer port.")
            buttons = { rescan = ui.button("RESCAN", colors.cyan),
                quit = ui.button("QUIT", colors.red) }
            return
        end

        local reactor = selectedReactor()
        local plan = reactor.governor or {}
        ui.status("Reactor", ("%d/%d %s"):format(selected, #reactors, reactor.name), colors.cyan)
        ui.status("Mode / state", string.upper(reactor.mode or "unknown") .. " / " ..
            (reactor.active == true and "ACTIVE" or reactor.active == false and "OFFLINE" or "UNKNOWN"),
            reactor.mode == "steam" and colors.lime or colors.orange)
        ui.status("Target / steam avg", reactor.mode == "steam" and
            (("%.0f / %s"):format(targetFor(reactor.name),
                formatNumber(plan.averageSteamProduction, " mB/t"))) or "MONITOR ONLY")
        ui.status("Steam raw", ("%s"):format(
            formatNumber(reactor.steamProduction, ""),
            formatNumber(plan.averageSteamProduction, " mB/t")), colors.cyan)
        ui.status("Rods", formatRodLayout(reactor, plan.currentRodExposure))
        ui.status("Case / hot buffer", formatNumber(reactor.casingTemperature, " C") ..
            " / " .. formatNumber(reactor.hotFluidPercent, "%"))
        ui.status("Calibration", tostring(plan.calibrationPhase or
            (plan.learnedProfile and "LEARNED" or "NOT STARTED")) .. " / " ..
            tostring(plan.state or "WAITING"), plan.actuatorState == "FAULT" and colors.red or colors.orange)
        ui.status("Actuator", clip(tostring(plan.actuatorState or "HOLD") ..
            (plan.actuatorError and (" — " .. plan.actuatorError) or ""),
            39), plan.actuatorState == "FAULT" and colors.red or colors.lightGray)
        ui.status("Samples avg / response", ("%d/%d / %d/%d"):format(
            tonumber(plan.averageSteamSamples) or 0,
            tonumber(config.control.reactorSteamAverageSamples) or 10,
            tonumber(plan.processStableSamples) or 0,
            tonumber(config.control.reactorLearningSamples) or 8))
        if plan.reason then ui.status("Reason", clip(plan.reason, 42), colors.lightGray) end

        buttons.previous = ui.inlineButton("< PREV", colors.cyan)
        write(" ")
        buttons.next = ui.inlineButton("NEXT >", colors.cyan)
        write(" ")
        buttons.rescan = ui.inlineButton("RESCAN", colors.cyan)
        print("")
        buttons.down = ui.inlineButton("TARGET -100", colors.cyan)
        write(" ")
        buttons.up = ui.inlineButton("TARGET +100", colors.cyan)
        print("")
        buttons.calibrate = ui.button("START FRESH CALIBRATION", colors.orange)
        buttons.hold = ui.button(maintenance and "ENABLE AUTOMATIC TEST" or
            "EMERGENCY HOLD", maintenance and colors.lime or colors.red)
        buttons.save = ui.inlineButton("SAVE CURRENT", colors.lime)
        write(" ")
        buttons.quit = ui.inlineButton("QUIT", colors.red)
        print("")
    end

    local function hit(button, x, y)
        return ui.hit(button, x, y)
    end

    devices = discoverReactors()
    poll()
    timer = os.startTimer(1)
    appendLog("Reactor Lab started in HOLD mode")
    while true do
        draw()
        local event, first, second, third = os.pullEvent()
        local x, y = ui.eventPoint(event, first, second, third)
        local reactor = selectedReactor()
        if event == "key" and first == keys.q or hit(buttons.quit, x, y) then
            maintenance = true
            appendLog("Reactor Lab closed; actuator writes held")
            display.stop()
            term.clear()
            term.setCursorPos(1, 1)
            return
        elseif event == "key" and first == keys.left or hit(buttons.previous, x, y) then
            if #reactors > 0 then selected = ((selected - 2) % #reactors) + 1 end
        elseif event == "key" and first == keys.right or hit(buttons.next, x, y) then
            if #reactors > 0 then selected = (selected % #reactors) + 1 end
        elseif hit(buttons.rescan, x, y) then
            devices = discoverReactors()
            poll()
        elseif reactor and reactor.mode == "steam" and hit(buttons.down, x, y) then
            config.targets[reactor.name] = math.max(0, targetFor(reactor.name) - 100)
            saveConfig(config)
            appendLog(reactor.name .. " target changed to " .. config.targets[reactor.name])
        elseif reactor and reactor.mode == "steam" and hit(buttons.up, x, y) then
            config.targets[reactor.name] = targetFor(reactor.name) + 100
            saveConfig(config)
            appendLog(reactor.name .. " target changed to " .. config.targets[reactor.name])
        elseif reactor and reactor.mode == "steam" and hit(buttons.calibrate, x, y) then
            governor.beginRecalibration(memory, config.control, reactor.name)
            maintenance = false
            saveConfig(config)
            appendLog(reactor.name .. " fresh calibration started")
            poll()
        elseif hit(buttons.hold, x, y) then
            maintenance = not maintenance
            appendLog(maintenance and "Emergency HOLD enabled" or "Automatic test enabled")
        elseif reactor and reactor.mode == "steam" and hit(buttons.save, x, y) then
            local ok, reason = governor.saveCurrentCalibration(memory, config.control,
                reactor, { now = os.epoch("utc") / 1000 })
            if ok then
                saveConfig(config)
                appendLog(reactor.name .. " current setup saved")
            else
                appendLog(reactor.name .. " save rejected: " .. tostring(reason))
            end
        elseif event == "timer" and first == timer then
            poll()
            timer = os.startTimer(1)
        elseif event == "peripheral" or event == "peripheral_detach" then
            devices = discoverReactors()
            poll()
        end
    end
end

return lab
]=],
}

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
print("HELIOS REACTOR LAB " .. VERSION)
print("Isolated reactor calibration test build")
print("")

if fs.exists(ROOT) then
    local backup = ROOT .. ".previous"
    if fs.exists(backup) then fs.delete(backup) end
    fs.move(ROOT, backup)
end
fs.makeDir(ROOT)

for path, content in pairs(FILES) do
    local full = fs.combine(ROOT, path)
    local directory = fs.getDir(full)
    if not fs.exists(directory) then fs.makeDir(directory) end
    local handle, reason = fs.open(full, "w")
    if not handle then error("Could not install " .. path .. ": " .. tostring(reason), 0) end
    handle.write(content)
    handle.close()
end

local launcher = fs.open("/reactorlab.lua", "w")
if not launcher then error("Could not create /reactorlab.lua", 0) end
launcher.write('dofile("/helios-reactor-lab/main.lua").run()\n')
launcher.close()

print("Installed successfully.")
print("Run: reactorlab")
print("")
print("The lab always starts in HOLD mode.")
