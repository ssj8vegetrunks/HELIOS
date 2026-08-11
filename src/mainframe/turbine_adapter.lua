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

function adapter.read(device)
    local name = device.name
    local turbine = { name = name, available = peripheral.isPresent(name) }
    if not turbine.available then
        turbine.error = "Peripheral unavailable"
        return turbine
    end

    local availableMethods = {}
    for _, method in ipairs(peripheral.getMethods(name) or {}) do
        availableMethods[method] = true
    end

    turbine.connected = readAny(name, availableMethods, { "getConnected", "isConnected", "mbIsConnected", "mbIsAssembled", "connected" })
    turbine.active = readAny(name, availableMethods, { "getActive", "isActive", "active" })
    turbine.rotorSpeed = number(readAny(name, availableMethods, { "getRotorSpeed", "getRotorRPM", "rotorSpeed" }))
    turbine.energyProduction = number(readAny(name, availableMethods, { "getEnergyProducedLastTick", "getEnergyProductionRate", "energyProducedLastTick" }))
    turbine.energy = number(readAny(name, availableMethods, { "getEnergyStored", "getEnergy", "energyStored" }))
    turbine.energyMax = number(readAny(name, availableMethods, { "getEnergyCapacity", "getMaxEnergyStored", "energyCapacity" }))
    turbine.flowRate = number(readAny(name, availableMethods, { "getFluidFlowRate", "getFluidFlowRateLastTick", "getInputFlowRate", "fluidFlowRate" }))
    turbine.flowRateMax = number(readAny(name, availableMethods, { "getFluidFlowRateMax", "getMaxFluidFlowRate", "getMaxIntakeRate", "fluidFlowRateMax" }))
    turbine.flowRateLimit = number(readAny(name, availableMethods, { "getFluidFlowRateMaxMax", "getFluidFlowRateLimit", "getMaxPermittedFlow", "flowRateLimit" }))
    turbine.inputAmount = number(readAny(name, availableMethods, { "getInputAmount", "getInputFluidAmount", "inputAmount" }))
    turbine.inputMax = number(readAny(name, availableMethods, { "getInputAmountMax", "getInputCapacity", "inputAmountMax" }))
    turbine.outputAmount = number(readAny(name, availableMethods, { "getOutputAmount", "getOutputFluidAmount", "outputAmount" }))
    turbine.outputMax = number(readAny(name, availableMethods, { "getOutputAmountMax", "getOutputCapacity", "outputAmountMax" }))
    turbine.inductorEngaged = readAny(name, availableMethods, { "getInductorEngaged", "isInductorEngaged", "inductorEngaged" })
    turbine.ventMode = readAny(name, availableMethods, { "getVentMode", "ventMode" })
    turbine.bladeCount = number(readAny(name, availableMethods, { "getBladeCount", "getNumberOfBlades", "bladeCount" }))
    turbine.coilCount = number(readAny(name, availableMethods, { "getCoilSize", "getCoilCount", "coilSize" }))
    turbine.efficiency = number(readAny(name, availableMethods, { "getRotorEfficiencyLastTick", "getEfficiency", "rotorEfficiencyLastTick" }))

    turbine.energyPercent = percent(turbine.energy, turbine.energyMax)
    turbine.inputPercent = percent(turbine.inputAmount, turbine.inputMax)
    turbine.outputPercent = percent(turbine.outputAmount, turbine.outputMax)

    local useful = turbine.active ~= nil or turbine.rotorSpeed ~= nil or turbine.energyProduction ~= nil
    if turbine.connected == false then
        turbine.error = "Turbine is not connected"
    elseif not useful then
        turbine.error = "No supported telemetry methods"
    end
    return turbine
end

function adapter.readAll(devices)
    local turbines = {}
    for _, device in ipairs(devices or {}) do
        local lowerName = string.lower(device.name or "")
        if device.category == "turbine" or string.find(lowerName, "turbine", 1, true) then
            turbines[#turbines + 1] = adapter.read(device)
        end
    end
    return turbines
end

local function value(numberValue, suffix)
    if numberValue == nil then return "N/A" end
    return ("%.1f%s"):format(numberValue, suffix or "")
end

function adapter.printReport(turbines, config, formatter)
    print("HELIOS turbine telemetry")
    print("Turbines found: " .. #turbines)
    print("")
    for _, turbine in ipairs(turbines) do
        local alias = config.deviceAliases[turbine.name]
        local displayName = alias or turbine.name
        print("[TURBINE] " .. displayName)
        if config.ui.showPeripheralNames and alias then print("  Peripheral: " .. turbine.name) end
        if turbine.error then
            print("  ERROR: " .. turbine.error)
        else
            print("  State: " .. (turbine.active == true and "ACTIVE" or turbine.active == false and "OFFLINE" or "UNKNOWN"))
            print("  Rotor: " .. value(turbine.rotorSpeed, " RPM"))
            print("  Power: " .. formatter.power(turbine.energyProduction, config.power, true))
            print("  Buffer: " .. value(turbine.energyPercent, "%"))
            print("  Flow: " .. value(turbine.flowRate, " mB/t"))
            print("  Flow setting: " .. value(turbine.flowRateMax, " mB/t"))
            print("  Flow limit: " .. value(turbine.flowRateLimit, " mB/t"))
            print("  Inductor: " .. (turbine.inductorEngaged == true and "ENGAGED" or turbine.inductorEngaged == false and "DISENGAGED" or "N/A"))
        end
        print("")
    end
end

return adapter
