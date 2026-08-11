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
    if methods.getControlRodsLevels then
        local ok, values = pcall(peripheral.call, name, "getControlRodsLevels")
        if ok and type(values) == "table" then levels = values end
    end
    if not levels and methods.getControlRodLevel and count and count > 0 then
        levels = {}
        for index = 0, count - 1 do
            local ok, value = pcall(peripheral.call, name, "getControlRodLevel", index)
            if not ok or tonumber(value) == nil then return nil end
            levels[index] = tonumber(value)
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
            else
                print("  Power: " .. formatter.power(reactor.energyProduction, config.power, true))
                print("  Buffer: " .. value(reactor.energyPercent, "%"))
            end
        end
        print("")
    end
end

return adapter
