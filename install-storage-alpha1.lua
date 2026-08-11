-- HELIOS single-file installer
-- Milestone 3.2: universal energy-storage telemetry and Mekanism adapter.

local VERSION = "0.3.2-alpha.1"
local INSTALL_DIR = "/helios"
local STAGE_DIR = "/.helios-install"

local function clear()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
end

local function title(subtitle)
    clear()
    term.setTextColor(colors.yellow)
    print("HELIOS")
    term.setTextColor(colors.lightGray)
    print("Industrial Power Management Suite")
    term.setTextColor(colors.gray)
    print(subtitle or "")
    term.setTextColor(colors.white)
    print("")
end

local function choose(prompt, options)
    while true do
        print(prompt)
        for index, option in ipairs(options) do
            print(("  [%d] %s"):format(index, option.label))
        end
        term.setTextColor(colors.yellow)
        write("> ")
        term.setTextColor(colors.white)
        local answer = read()
        local selected = tonumber(answer)
        if selected and options[selected] then
            return options[selected].value
        end
        term.setTextColor(colors.red)
        print("Please enter a number from the list.")
        term.setTextColor(colors.white)
    end
end

local function confirm(prompt)
    write(prompt .. " [y/N] ")
    local answer = read():lower()
    return answer == "y" or answer == "yes"
end

local function writeFile(path, contents)
    local parent = fs.getDir(path)
    if parent ~= "" and not fs.exists(parent) then
        fs.makeDir(parent)
    end
    local handle, reason = fs.open(path, "w")
    if not handle then error("Could not write " .. path .. ": " .. tostring(reason), 0) end
    handle.write(contents)
    handle.close()
end

local FILES = {
    ["helios.lua"] = [=[
local args = { ... }
local config = dofile("/helios/core/config.lua").load()

if args[1] == "status" then
    print("HELIOS " .. tostring(config.version))
    print("Role: " .. tostring(config.role))
    if config.role == "terminal" then
        print("Display: " .. tostring(config.display))
    end
    print("Computer ID: " .. tostring(config.computerId))
    return
end

if args[1] == "scan" then
    if config.role ~= "mainframe" then
        error("Only the HELIOS mainframe can scan attached hardware.", 0)
    end
    local registry = dofile("/helios/mainframe/device_registry.lua")
    local devices = registry.scan()
    registry.save(devices)
    registry.printReport(devices)
    return
end

if args[1] == "reactors" then
    if config.role ~= "mainframe" then
        error("Only the HELIOS mainframe can read reactor telemetry.", 0)
    end
    local registry = dofile("/helios/mainframe/device_registry.lua")
    local adapter = dofile("/helios/mainframe/reactor_adapter.lua")
    local formatter = dofile("/helios/core/power_format.lua")
    local devices = registry.scan()
    adapter.printReport(adapter.readAll(devices), config, formatter)
    return
end

if args[1] == "turbines" then
    if config.role ~= "mainframe" then
        error("Only the HELIOS mainframe can read turbine telemetry.", 0)
    end
    local registry = dofile("/helios/mainframe/device_registry.lua")
    local adapter = dofile("/helios/mainframe/turbine_adapter.lua")
    local formatter = dofile("/helios/core/power_format.lua")
    local devices = registry.scan()
    adapter.printReport(adapter.readAll(devices), config, formatter)
    return
end

if args[1] == "storage" or args[1] == "batteries" then
    if config.role ~= "mainframe" then
        error("Only the HELIOS mainframe can read energy-storage telemetry.", 0)
    end
    local registry = dofile("/helios/mainframe/device_registry.lua")
    local adapter = dofile("/helios/mainframe/storage_adapter.lua")
    local formatter = dofile("/helios/core/power_format.lua")
    local devices = registry.scan()
    adapter.printReport(adapter.readAll(devices, config.power), config, formatter)
    return
end

if config.role == "mainframe" then
    dofile("/helios/mainframe/main.lua").run(config)
elseif config.role == "terminal" then
    dofile("/helios/terminal/main.lua").run(config)
else
    error("Unknown HELIOS role in /helios/config.lua: " .. tostring(config.role), 0)
end
]=],

    ["core/config.lua"] = [=[
local config = {}

function config.load()
    if not fs.exists("/helios/config.lua") then
        error("HELIOS configuration is missing. Run the installer again.", 0)
    end
    local loaded = dofile("/helios/config.lua")
    if type(loaded) ~= "table" then
        error("HELIOS configuration is invalid.", 0)
    end
    if loaded.role ~= "mainframe" and loaded.role ~= "terminal" then
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
    loaded.ui = loaded.ui or {}
    loaded.ui.showPeripheralNames = loaded.ui.showPeripheralNames == true
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
    return loaded
end

function config.save(loaded)
    local handle, reason = fs.open("/helios/config.lua", "w")
    if not handle then return false, reason end
    handle.write("return " .. textutils.serialize(loaded))
    handle.close()
    return true
end

return config
]=],

    ["core/power_format.lua"] = [=[
local formatter = {}

local function addCommas(value)
    local sign = value < 0 and "-" or ""
    local digits = tostring(math.floor(math.abs(value) + 0.5))
    local changed
    repeat
        digits, changed = digits:gsub("^(%d+)(%d%d%d)", "%1,%2")
    until changed == 0
    return sign .. digits
end

function formatter.convert(value, powerConfig)
    value = tonumber(value)
    if not value then return nil end
    local unit = powerConfig.unit or "FE"
    local ratio = tonumber((powerConfig.ratios or {})[unit]) or 1
    return value * ratio
end

function formatter.number(value, powerConfig)
    value = tonumber(value)
    if not value then return "N/A" end
    if powerConfig.numberFormat == "full" then return addCommas(value) end
    local absolute = math.abs(value)
    local scale, suffix = 1, ""
    if absolute >= 1e12 then scale, suffix = 1e12, "T"
    elseif absolute >= 1e9 then scale, suffix = 1e9, "B"
    elseif absolute >= 1e6 then scale, suffix = 1e6, "M"
    elseif absolute >= 1e3 then scale, suffix = 1e3, "k"
    end
    if scale == 1 then
        local rounded = value >= 0 and math.floor(value + 0.5) or math.ceil(value - 0.5)
        return tostring(rounded)
    end
    local decimals = math.max(1, math.min(2, math.floor(tonumber(powerConfig.decimals) or 1)))
    return (("%." .. decimals .. "f%s"):format(value / scale, suffix))
end

function formatter.power(value, powerConfig, perTick)
    local converted = formatter.convert(value, powerConfig)
    if converted == nil then return "N/A" end
    return formatter.number(converted, powerConfig) .. " " .. (powerConfig.unit or "FE") .. (perTick and "/t" or "")
end

return formatter
]=],

    ["core/ui.lua"] = [=[
local ui = {}

function ui.prepare()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
end

function ui.header(role, subtitle)
    ui.prepare()
    term.setTextColor(colors.yellow)
    print("HELIOS // " .. string.upper(role))
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
        elseif event == "term_resize" then
            render()
        end
    end
end

return ui
]=],

    ["mainframe/device_registry.lua"] = [=[
local registry = {}
local REGISTRY_FILE = "/helios/data/devices.lua"

local function contains(value, fragment)
    return string.find(string.lower(value or ""), fragment, 1, true) ~= nil
end

local function methodSet(methods)
    local set = {}
    for _, method in ipairs(methods) do set[method] = true end
    return set
end

local function classify(name, types, methods)
    if contains(name, "turbine") then return "turbine" end
    if contains(name, "reactor") then return "reactor" end
    for _, peripheralType in ipairs(types) do
        if contains(peripheralType, "turbine") then return "turbine" end
    end
    for _, peripheralType in ipairs(types) do
        if contains(peripheralType, "reactor") then return "reactor" end
    end
    for _, peripheralType in ipairs(types) do
        if peripheralType == "monitor" then return "monitor" end
        if peripheralType == "modem" then return "modem" end
    end

    local available = methodSet(methods)
    local inductionIdentity = contains(name, "inductionport") or contains(name, "induction_port")
    for _, peripheralType in ipairs(types) do
        if contains(peripheralType, "inductionport") or contains(peripheralType, "induction_port") then
            inductionIdentity = true
        end
    end
    local inductionSignature = available.getEnergy and available.getMaxEnergy and
        (available.getLastInput or available.getLastOutput or available.getTransferCap or
         available.getInstalledCells or available.getInstalledProviders)
    if inductionIdentity and inductionSignature then return "battery" end

    local energyReader =
        (available.getEnergyStored and available.getMaxEnergyStored) or
        (available.getEnergy and available.getEnergyCapacity) or
        (available.getStoredEnergy and available.getEnergyCapacity) or
        (available.getStored and available.getCapacity)
    if energyReader then return "battery" end

    return "unknown"
end

function registry.scan()
    local devices = {}
    local names = peripheral.getNames()
    table.sort(names)

    for _, name in ipairs(names) do
        local types = { peripheral.getType(name) }
        local methods = peripheral.getMethods(name) or {}
        table.sort(types)
        table.sort(methods)
        devices[#devices + 1] = {
            name = name,
            types = types,
            methods = methods,
            category = classify(name, types, methods),
        }
    end
    return devices
end

function registry.save(devices)
    if not fs.exists("/helios/data") then fs.makeDir("/helios/data") end
    local handle, reason = fs.open(REGISTRY_FILE, "w")
    if not handle then return false, reason end
    handle.write("return " .. textutils.serialize({
        scannedAt = os.epoch("utc"),
        devices = devices,
    }))
    handle.close()
    return true
end

function registry.countByCategory(devices)
    local counts = { reactor = 0, turbine = 0, battery = 0, monitor = 0, modem = 0, unknown = 0 }
    for _, device in ipairs(devices) do
        counts[device.category] = (counts[device.category] or 0) + 1
    end
    return counts
end

function registry.printReport(devices)
    print("HELIOS hardware scan")
    print("Devices found: " .. #devices)
    print("")
    for _, device in ipairs(devices) do
        print(("[%s] %s"):format(string.upper(device.category), device.name))
        print("  Types: " .. (#device.types > 0 and table.concat(device.types, ", ") or "unreported"))
    end
    print("")
    print("Registry saved to " .. REGISTRY_FILE)
end

return registry
]=],

    ["mainframe/reactor_adapter.lua"] = [=[
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
    local reactor = { name = name, available = peripheral.isPresent(name) }
    if not reactor.available then
        reactor.error = "Peripheral unavailable"
        return reactor
    end

    local availableMethods = {}
    for _, method in ipairs(peripheral.getMethods(name) or {}) do
        availableMethods[method] = true
    end

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

    ["mainframe/turbine_adapter.lua"] = [=[
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
            print("  Inductor: " .. (turbine.inductorEngaged == true and "ENGAGED" or turbine.inductorEngaged == false and "DISENGAGED" or "N/A"))
        end
        print("")
    end
end

return adapter
]=],

    ["mainframe/storage_adapter.lua"] = [=[
local adapter = {}
local previousSamples = {}

local function contains(value, fragment)
    return string.find(string.lower(value or ""), fragment, 1, true) ~= nil
end

local function methodSet(methods)
    local set = {}
    for _, method in ipairs(methods or {}) do set[method] = true end
    return set
end

local function number(value)
    if type(value) == "number" then return value end
    if type(value) == "string" then return tonumber(value) end
    if type(value) == "table" then
        return tonumber(value.value or value.amount or value.energy or value.stored)
    end
    return nil
end

local function readAny(name, available, candidates)
    for _, method in ipairs(candidates) do
        if available[method] then
            local ok, result = pcall(peripheral.call, name, method)
            if ok and result ~= nil then return result, method end
        end
    end
    return nil, nil
end

local function hasPair(available, storedMethods, capacityMethods)
    local stored, capacity = false, false
    for _, method in ipairs(storedMethods) do stored = stored or available[method] == true end
    for _, method in ipairs(capacityMethods) do capacity = capacity or available[method] == true end
    return stored and capacity
end

local STORED_METHODS = { "getEnergyStored", "getEnergy", "getStoredEnergy", "getStored", "getEnergyStorage" }
local CAPACITY_METHODS = { "getMaxEnergyStored", "getMaxEnergy", "getEnergyCapacity", "getCapacity", "getMaxStored" }
local INPUT_METHODS = { "getLastInput", "getEnergyInput", "getInputRate", "getInput" }
local OUTPUT_METHODS = { "getLastOutput", "getEnergyOutput", "getOutputRate", "getOutput" }

local function inductionIdentity(device)
    if contains(device.name, "inductionport") or contains(device.name, "induction_port") then return true end
    for _, peripheralType in ipairs(device.types or {}) do
        if contains(peripheralType, "inductionport") or contains(peripheralType, "induction_port") then return true end
    end
    return false
end

local function genericSupported(available)
    return hasPair(available, STORED_METHODS, CAPACITY_METHODS)
end

local function mekanismSupported(device, available)
    if not inductionIdentity(device) then return false end
    if not (available.getEnergy and available.getMaxEnergy) then return false end
    return available.getLastInput or available.getLastOutput or available.getTransferCap or
        available.getInstalledCells or available.getInstalledProviders
end

local function toBaseFE(value, nativeUnit, powerConfig)
    value = number(value)
    if value == nil then return nil end
    if nativeUnit == "J" then
        local joulesPerFE = tonumber(((powerConfig or {}).ratios or {}).J) or 2.5
        if joulesPerFE > 0 then return value / joulesPerFE end
    end
    return value
end

local function percentage(stored, capacity, reported)
    reported = number(reported)
    if reported ~= nil then
        if reported >= 0 and reported <= 1 then return reported * 100 end
        return reported
    end
    if stored ~= nil and capacity and capacity > 0 then return stored / capacity * 100 end
    return nil
end

local function readGeneric(device, available, powerConfig)
    local stored = number(readAny(device.name, available, STORED_METHODS))
    local capacity = number(readAny(device.name, available, CAPACITY_METHODS))
    if stored == nil or capacity == nil then return nil end
    return {
        name = device.name,
        adapter = "generic",
        adapterName = "GENERIC",
        stored = toBaseFE(stored, "FE", powerConfig),
        capacity = toBaseFE(capacity, "FE", powerConfig),
        input = toBaseFE(readAny(device.name, available, INPUT_METHODS), "FE", powerConfig),
        output = toBaseFE(readAny(device.name, available, OUTPUT_METHODS), "FE", powerConfig),
        nativeUnit = "FE",
        telemetryOk = true,
        details = {},
    }
end

local function readMekanism(device, available, powerConfig)
    local formed = readAny(device.name, available, { "isFormed" })
    if formed == false then
        return {
            name = device.name,
            adapter = "mekanism_induction",
            adapterName = "MEKANISM MATRIX",
            nativeUnit = "J",
            telemetryOk = false,
            error = "Induction Matrix is not formed",
            details = {},
        }
    end

    local stored = toBaseFE(readAny(device.name, available, { "getEnergy" }), "J", powerConfig)
    local capacity = toBaseFE(readAny(device.name, available, { "getMaxEnergy" }), "J", powerConfig)
    if stored == nil or capacity == nil then return nil end

    local result = {
        name = device.name,
        adapter = "mekanism_induction",
        adapterName = "MEKANISM MATRIX",
        stored = stored,
        capacity = capacity,
        input = toBaseFE(readAny(device.name, available, { "getLastInput" }), "J", powerConfig),
        output = toBaseFE(readAny(device.name, available, { "getLastOutput" }), "J", powerConfig),
        nativeUnit = "J",
        telemetryOk = true,
        details = {
            transferCap = toBaseFE(readAny(device.name, available, { "getTransferCap" }), "J", powerConfig),
            cells = number(readAny(device.name, available, { "getInstalledCells" })),
            providers = number(readAny(device.name, available, { "getInstalledProviders" })),
            formed = formed,
        },
    }
    result.reportedPercent = number(readAny(device.name, available, { "getEnergyFilledPercentage" }))
    return result
end

local function finalize(storage)
    storage.percent = percentage(storage.stored, storage.capacity, storage.reportedPercent)
    storage.reportedPercent = nil

    if storage.input ~= nil and storage.output ~= nil then
        storage.net = storage.input - storage.output
    else
        local now = os.epoch("utc") / 1000
        local previous = previousSamples[storage.name]
        if previous and now > previous.time and storage.stored ~= nil then
            local elapsedSeconds = now - previous.time
            storage.net = (storage.stored - previous.stored) / (elapsedSeconds * 20)
        end
        if storage.stored ~= nil then
            previousSamples[storage.name] = { stored = storage.stored, time = now }
        end
    end

    local epsilon = 0.5
    if storage.capacity and storage.capacity > 0 and storage.stored and storage.stored >= storage.capacity then
        storage.state = "FULL"
    elseif storage.stored and storage.stored <= 0 then
        storage.state = "EMPTY"
    elseif storage.net and storage.net > epsilon then
        storage.state = "CHARGING"
    elseif storage.net and storage.net < -epsilon then
        storage.state = "DRAINING"
    elseif storage.net ~= nil then
        storage.state = "STABLE"
    else
        storage.state = "UNKNOWN"
    end

    if storage.net and storage.capacity and storage.stored then
        if storage.net > epsilon then
            storage.etaSeconds = math.max(0, (storage.capacity - storage.stored) / (storage.net * 20))
        elseif storage.net < -epsilon then
            storage.etaSeconds = math.max(0, storage.stored / (-storage.net * 20))
        end
    end
    return storage
end

function adapter.read(device, powerConfig)
    if not peripheral.isPresent(device.name) then
        return { name = device.name, adapterName = "UNKNOWN", telemetryOk = false, error = "Peripheral unavailable", details = {} }
    end
    local methods = peripheral.getMethods(device.name) or device.methods or {}
    local available = methodSet(methods)
    local storage

    if mekanismSupported(device, available) then
        local ok, specialized = pcall(readMekanism, device, available, powerConfig)
        if ok then storage = specialized end
        if not storage then
            storage = readGeneric(device, available, powerConfig)
            if storage then
                storage.fallback = true
                storage.adapterName = "GENERIC (FALLBACK)"
            end
        end
    elseif genericSupported(available) then
        storage = readGeneric(device, available, powerConfig)
    end

    if not storage then return nil end
    return finalize(storage)
end

function adapter.readAll(devices, powerConfig)
    local storages = {}
    local present = {}
    for _, device in ipairs(devices or {}) do
        if device.category ~= "reactor" and device.category ~= "turbine" and
           device.category ~= "monitor" and device.category ~= "modem" then
            local ok, storage = pcall(adapter.read, device, powerConfig)
            if ok and storage then
                storages[#storages + 1] = storage
                present[storage.name] = true
            elseif not ok and device.category == "battery" then
                storages[#storages + 1] = {
                    name = device.name,
                    adapterName = "UNKNOWN",
                    telemetryOk = false,
                    error = "Storage adapter failed",
                    details = {},
                }
            end
        end
    end
    for name in pairs(previousSamples) do
        if not present[name] then previousSamples[name] = nil end
    end
    table.sort(storages, function(a, b) return a.name < b.name end)
    return storages
end

local function eta(value)
    if value == nil or value ~= value or value == math.huge then return "N/A" end
    value = math.max(0, math.floor(value + 0.5))
    local days = math.floor(value / 86400)
    local hours = math.floor((value % 86400) / 3600)
    local minutes = math.floor((value % 3600) / 60)
    local seconds = value % 60
    if days > 0 then return ("%dd %dh"):format(days, hours) end
    if hours > 0 then return ("%dh %dm"):format(hours, minutes) end
    if minutes > 0 then return ("%dm %ds"):format(minutes, seconds) end
    return seconds .. "s"
end

function adapter.formatETA(storage)
    return eta(storage and storage.etaSeconds)
end

function adapter.printReport(storages, config, formatter)
    print("HELIOS energy-storage telemetry")
    print("Storage devices found: " .. #storages)
    print("")
    for _, storage in ipairs(storages) do
        local alias = config.deviceAliases[storage.name]
        print("[" .. storage.adapterName .. "] " .. (alias or storage.name))
        if config.ui.showPeripheralNames and alias then print("  Peripheral: " .. storage.name) end
        if storage.error then
            print("  ERROR: " .. storage.error)
        else
            print("  Stored: " .. formatter.power(storage.stored, config.power, false) .. " / " .. formatter.power(storage.capacity, config.power, false))
            print("  Charge: " .. (storage.percent and ("%.1f%%"):format(storage.percent) or "N/A"))
            print("  Input: " .. formatter.power(storage.input, config.power, true))
            print("  Output: " .. formatter.power(storage.output, config.power, true))
            print("  Net: " .. formatter.power(storage.net, config.power, true))
            print("  State: " .. storage.state)
            if storage.state == "CHARGING" then print("  Full in: " .. eta(storage.etaSeconds)) end
            if storage.state == "DRAINING" then print("  Empty in: " .. eta(storage.etaSeconds)) end
        end
        print("")
    end
end

return adapter
]=],

    ["mainframe/main.lua"] = [=[
local mainframe = {}

function mainframe.run(config)
    local ui = dofile("/helios/core/ui.lua")
    local configStore = dofile("/helios/core/config.lua")
    local registry = dofile("/helios/mainframe/device_registry.lua")
    local reactorAdapter = dofile("/helios/mainframe/reactor_adapter.lua")
    local turbineAdapter = dofile("/helios/mainframe/turbine_adapter.lua")
    local storageAdapter = dofile("/helios/mainframe/storage_adapter.lua")
    local powerFormat = dofile("/helios/core/power_format.lua")
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

    local timeoutChoices = { 300, 900, 1800, 3600 }

    local function modeName()
        if maintenance then return "MANUAL - MAINTENANCE" end
        if config.discovery.defaultMode == "manual" then return "MANUAL" end
        return "AUTOMATIC"
    end

    local function rescan()
        devices = registry.scan()
        registry.save(devices)
        reactors = reactorAdapter.readAll(devices)
        turbines = turbineAdapter.readAll(devices)
        storages = storageAdapter.readAll(devices, config.power)
        registryStale = false
    end

    local function playSound(sound, pitch)
        if not config.alarms.enabled then return end
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
        local function add(level, key, message)
            activeKeys[key] = true
            conditionSamples[key] = (conditionSamples[key] or 0) + 1
            if conditionSamples[key] >= 3 then
                candidates[#candidates + 1] = { level = level, key = key, message = message }
            end
        end

        for _, reactor in ipairs(reactors) do
            if reactor.error then
                add(3, reactor.name .. ":telemetry", reactor.name .. " TELEMETRY LOST")
            elseif reactor.fuelPercent then
                if reactor.fuelPercent <= config.alarms.criticalFuel then
                    add(3, reactor.name .. ":fuel-critical", reactor.name .. " FUEL CRITICAL")
                elseif reactor.fuelPercent <= config.alarms.lowFuel then
                    add(1, reactor.name .. ":fuel-low", reactor.name .. " FUEL LOW")
                end
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
        local repeatAfter = currentAlarm.level >= 3 and 5 or 30
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
        updateAlarm()
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
        rescan()
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

    local function render()
        ui.header("MAINFRAME", "Central control authority")
        ui.status("System", "ONLINE", colors.lime)
        ui.status("Computer ID", config.computerId)
        ui.status("Attached hardware", #devices, #devices > 0 and colors.lime or colors.orange)
        ui.status("Discovery", modeName(), maintenance and colors.orange or colors.cyan)
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
            ui.status("Reactor alarms", "CLEAR", colors.lime)
        end

        local width, height = term.getSize()
        local availableRows = math.max(0, height - 16)
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
        term.setTextColor(colors.gray)
        print("V reactors | G turbines | E storage")
        print("R rescan | S settings | Q exit")
    end

    local function restoreTimersAfterTextInput()
        if reactorTimer then os.cancelTimer(reactorTimer) end
        pollReactors()
        reactorTimer = os.startTimer(1)
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
            print("<- / ->  Select device")
            print("E  Edit name")
            print("C  Clear name")
            print("B  Back")

            local event, value = os.pullEvent()
            if event == "key" and value == keys.b then
                return
            elseif event == "key" and value == keys.left and #devices > 0 then
                selected = ((selected - 2) % #devices) + 1
            elseif event == "key" and value == keys.right and #devices > 0 then
                selected = (selected % #devices) + 1
            elseif event == "key" and value == keys.c and #devices > 0 then
                config.deviceAliases[devices[selected].name] = nil
                saveConfig()
            elseif event == "key" and value == keys.e and #devices > 0 then
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
            elseif event == "peripheral" or event == "peripheral_detach" then
                if maintenance or config.discovery.defaultMode == "manual" then registryStale = true else rescan() end
            elseif event == "timer" then
                if maintenance and value == maintenanceTimer then
                    stopMaintenance()
                elseif maintenance and value == countdownTimer then
                    countdownTimer = os.startTimer(1)
                elseif value == reactorTimer then
                    pollReactors()
                    reactorTimer = os.startTimer(1)
                end
            end
        end
    end

    local function powerSettings()
        local units = { "FE", "RF", "J", "EU" }
        while true do
            ui.header("POWER DISPLAY", "Global energy formatting")
            ui.status("Display unit", config.power.unit, colors.cyan)
            ui.status("Conversion", ("1 FE = %g %s"):format(config.power.ratios[config.power.unit], config.power.unit))
            ui.status("Number format", string.upper(config.power.numberFormat))
            ui.status("Compact precision", config.power.decimals .. " decimal" .. (config.power.decimals == 1 and "" or "s"))
            ui.status("Example", powerFormat.power(2347819624112, config.power, true), colors.lime)
            print("")
            print("U  Change unit")
            print("N  Compact / full")
            print("P  Change precision")
            print("R  Set conversion ratio")
            print("B  Back")

            local event, value = os.pullEvent()
            if event == "key" and value == keys.b then
                return
            elseif event == "key" and value == keys.u then
                local current = 1
                for index, unit in ipairs(units) do if unit == config.power.unit then current = index end end
                config.power.unit = units[(current % #units) + 1]
                saveConfig()
            elseif event == "key" and value == keys.n then
                config.power.numberFormat = config.power.numberFormat == "compact" and "full" or "compact"
                saveConfig()
            elseif event == "key" and value == keys.p then
                config.power.decimals = config.power.decimals == 1 and 2 or 1
                saveConfig()
            elseif event == "key" and value == keys.r then
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
            elseif event == "peripheral" or event == "peripheral_detach" then
                if maintenance or config.discovery.defaultMode == "manual" then registryStale = true else rescan() end
            elseif event == "timer" then
                if maintenance and value == maintenanceTimer then
                    stopMaintenance()
                elseif maintenance and value == countdownTimer then
                    countdownTimer = os.startTimer(1)
                elseif value == reactorTimer then
                    pollReactors()
                    reactorTimer = os.startTimer(1)
                end
            end
        end
    end

    local function settings()
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
            print("D  Change default mode")
            print("<- / ->  Change timeout")
            if maintenance then
                print("F  Finish maintenance")
            else
                print("M  Begin manual maintenance")
            end
            print("H  Show/hide peripheral names")
            print("N  Name devices")
            print("P  Power display")
            print("B  Back")
        end

        while true do
            renderSettings()
            local event, value = os.pullEvent()
            if event == "key" and value == keys.b then
                return
            elseif event == "key" and value == keys.d then
                config.discovery.defaultMode = config.discovery.defaultMode == "event" and "manual" or "event"
                saveConfig()
                if not maintenance and config.discovery.defaultMode == "event" and registryStale then
                    rescan()
                end
            elseif event == "key" and (value == keys.left or value == keys.right) then
                local currentIndex = 1
                for index, timeout in ipairs(timeoutChoices) do
                    if timeout == config.discovery.maintenanceTimeout then
                        currentIndex = index
                        break
                    end
                end
                local direction = value == keys.right and 1 or -1
                local nextIndex = ((currentIndex - 1 + direction) % #timeoutChoices) + 1
                local nextTimeout = timeoutChoices[nextIndex]
                config.discovery.maintenanceTimeout = nextTimeout
                saveConfig()
                if maintenance then
                    if maintenanceTimer then os.cancelTimer(maintenanceTimer) end
                    startMaintenance()
                end
            elseif event == "key" and value == keys.m and not maintenance then
                startMaintenance()
            elseif event == "key" and value == keys.f and maintenance then
                stopMaintenance()
            elseif event == "key" and value == keys.h then
                config.ui.showPeripheralNames = not config.ui.showPeripheralNames
                saveConfig()
            elseif event == "key" and value == keys.n then
                namingSettings()
            elseif event == "key" and value == keys.p then
                powerSettings()
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
                    reactorTimer = os.startTimer(1)
                end
            end
        end
    end

    local function reactorView()
        local selected = 1
        local viewSilenceButton

        local function formatValue(value, suffix)
            if value == nil then return "N/A" end
            return ("%.1f%s"):format(value, suffix or "")
        end

        local function draw()
            ui.header("REACTORS", "Read-only live telemetry")
            if #reactors == 0 then
                ui.status("Status", "NO REACTORS FOUND", colors.orange)
                print("")
                print("B  Back")
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
                ui.status("Fuel", formatValue(reactor.fuelPercent, "%"))
                ui.status("Fuel use", formatValue(reactor.fuelUse, " mB/t"))
                ui.status("Fuel temp", formatValue(reactor.fuelTemperature, " C"))
                ui.status("Casing temp", formatValue(reactor.casingTemperature, " C"))
                if reactor.mode == "steam" then
                    ui.status("Steam output", formatValue(reactor.steamProduction, " mB/t"), colors.cyan)
                    ui.status("Coolant", formatValue(reactor.coolantPercent, "%"))
                    ui.status("Hot fluid", formatValue(reactor.hotFluidPercent, "%"))
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
            print("<- / -> reactor | B back")
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
            elseif event == "mouse_click" and viewSilenceButton and
                   y == viewSilenceButton.y and x >= viewSilenceButton.x1 and x <= viewSilenceButton.x2 then
                silenceCurrentAlarm()
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
                    reactorTimer = os.startTimer(1)
                end
            end
        end
    end

    local function turbineView()
        local selected = 1

        local function formatValue(value, suffix)
            if value == nil then return "N/A" end
            return ("%.1f%s"):format(value, suffix or "")
        end

        local function draw()
            ui.header("TURBINES", "Read-only live telemetry")
            if #turbines == 0 then
                ui.status("Status", "NO TURBINES FOUND", colors.orange)
                print("")
                print("B  Back")
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
                ui.status("Power output", powerFormat.power(turbine.energyProduction, config.power, true), colors.cyan)
                ui.status("Energy buffer", formatValue(turbine.energyPercent, "%"))
                ui.status("Fluid flow", formatValue(turbine.flowRate, " mB/t"))
                ui.status("Max flow", formatValue(turbine.flowRateMax, " mB/t"))
                ui.status("Input tank", formatValue(turbine.inputPercent, "%"))
                ui.status("Output tank", formatValue(turbine.outputPercent, "%"))
                ui.status("Inductor", turbine.inductorEngaged == true and "ENGAGED" or turbine.inductorEngaged == false and "DISENGAGED" or "N/A")
                if turbine.ventMode ~= nil then ui.status("Vent mode", tostring(turbine.ventMode)) end
            end
            print("")
            print("<- / -> turbine | B back")
        end

        while true do
            draw()
            local event, value = os.pullEvent()
            if event == "key" and value == keys.b then
                return
            elseif event == "key" and value == keys.left and #turbines > 0 then
                selected = ((selected - 2) % #turbines) + 1
            elseif event == "key" and value == keys.right and #turbines > 0 then
                selected = (selected % #turbines) + 1
            elseif event == "peripheral" or event == "peripheral_detach" then
                if maintenance or config.discovery.defaultMode == "manual" then registryStale = true else rescan() end
            elseif event == "timer" then
                if maintenance and value == maintenanceTimer then
                    stopMaintenance()
                elseif maintenance and value == countdownTimer then
                    countdownTimer = os.startTimer(1)
                elseif value == reactorTimer then
                    pollReactors()
                    reactorTimer = os.startTimer(1)
                end
            end
        end
    end

    local function storageView()
        local selected = 1

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
                print("B  Back")
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
            print("<- / -> storage | B back")
        end

        while true do
            draw()
            local event, value = os.pullEvent()
            if event == "key" and value == keys.b then
                return
            elseif event == "key" and value == keys.left and #storages > 0 then
                selected = ((selected - 2) % #storages) + 1
            elseif event == "key" and value == keys.right and #storages > 0 then
                selected = (selected % #storages) + 1
            elseif event == "peripheral" or event == "peripheral_detach" then
                if maintenance or config.discovery.defaultMode == "manual" then registryStale = true else rescan() end
            elseif event == "timer" then
                if maintenance and value == maintenanceTimer then
                    stopMaintenance()
                elseif maintenance and value == countdownTimer then
                    countdownTimer = os.startTimer(1)
                elseif value == reactorTimer then
                    pollReactors()
                    reactorTimer = os.startTimer(1)
                end
            end
        end
    end

    rescan()
    pollReactors()
    reactorTimer = os.startTimer(1)
    render()
    while true do
        local event, value, x, y = os.pullEvent()
        if event == "key" and value == keys.q then
            ui.prepare()
            return
        elseif event == "key" and value == keys.r then
            rescan()
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
        elseif event == "mouse_click" and silenceButton and
               y == silenceButton.y and x >= silenceButton.x1 and x <= silenceButton.x2 then
            silenceCurrentAlarm()
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
                reactorTimer = os.startTimer(1)
                render()
            end
        elseif event == "term_resize" then
            render()
        end
    end
end

return mainframe
]=],

    ["terminal/main.lua"] = [=[
local terminal = {}

function terminal.run(config)
    local ui = dofile("/helios/core/ui.lua")
    local function render()
        ui.header("REMOTE TERMINAL", "Mainframe-restricted display")
        ui.status("System", "ONLINE", colors.lime)
        ui.status("Computer ID", config.computerId)
        ui.status("Display assignment", string.upper(config.display or "all"), colors.cyan)
        ui.status("Mainframe link", "Awaiting protocol", colors.orange)
        print("")
        term.setTextColor(colors.gray)
        print("This terminal has no device-control authority.")
        print("Press Q to exit HELIOS.")
    end
    render()
    ui.waitForExit(render)
end

return terminal
]=],
}

local function installStartup()
    if fs.exists("/startup") and not fs.isDir("/startup") then
        print("An existing /startup program was found.")
        print("HELIOS can preserve it as /startup/00-user.lua.")
        if not confirm("Convert startup to a startup directory?") then
            return false, "Autostart was skipped; run 'helios' manually."
        end
        local oldStartup = "/.helios-existing-startup.lua"
        if fs.exists(oldStartup) then fs.delete(oldStartup) end
        fs.move("/startup", oldStartup)
        fs.makeDir("/startup")
        fs.move(oldStartup, "/startup/00-user.lua")
    elseif not fs.exists("/startup") then
        fs.makeDir("/startup")
    end

    writeFile("/startup/99-helios.lua", [=[
if fs.exists("/helios/helios.lua") then
    shell.run("/helios/helios.lua")
end
]=])
    return true
end

local function buildConfig(role, display, existing)
    existing = type(existing) == "table" and existing or {}
    local discovery = type(existing.discovery) == "table" and existing.discovery or {}
    local alarms = type(existing.alarms) == "table" and existing.alarms or {}
    local uiSettings = type(existing.ui) == "table" and existing.ui or {}
    local power = type(existing.power) == "table" and existing.power or {}
    local ratios = type(power.ratios) == "table" and power.ratios or {}
    local aliases = type(existing.deviceAliases) == "table" and existing.deviceAliases or {}
    local merged = {
        version = VERSION,
        role = role,
        display = display,
        computerId = os.getComputerID(),
        discovery = {
            defaultMode = discovery.defaultMode == "manual" and "manual" or "event",
            maintenanceTimeout = tonumber(discovery.maintenanceTimeout) or 1800,
        },
        alarms = {
            enabled = alarms.enabled ~= false,
            lowFuel = tonumber(alarms.lowFuel) or 20,
            criticalFuel = tonumber(alarms.criticalFuel) or 5,
            volume = tonumber(alarms.volume) or 1.5,
        },
        ui = {
            showPeripheralNames = uiSettings.showPeripheralNames == true,
        },
        power = {
            unit = ({ FE = true, RF = true, J = true, EU = true })[power.unit] and power.unit or "FE",
            numberFormat = power.numberFormat == "full" and "full" or "compact",
            decimals = math.max(1, math.min(2, math.floor(tonumber(power.decimals) or 1))),
            ratios = {
                FE = tonumber(ratios.FE) or 1,
                RF = tonumber(ratios.RF) or 1,
                J = tonumber(ratios.J) or 2.5,
                EU = tonumber(ratios.EU) or 0.25,
            },
        },
        deviceAliases = aliases,
    }
    return "return " .. textutils.serialize(merged)
end

local function runInstaller()
    local existingConfig
    if fs.exists(INSTALL_DIR .. "/config.lua") then
        local ok, loaded = pcall(dofile, INSTALL_DIR .. "/config.lua")
        if ok and type(loaded) == "table" then existingConfig = loaded end
    end
    title("Installer " .. VERSION)
    local role = choose("Select this computer's role:", {
        { label = "Mainframe", value = "mainframe" },
        { label = "Remote Terminal", value = "terminal" },
    })

    local display
    if role == "terminal" then
        title("Remote Terminal Configuration")
        display = choose("Select the information this terminal will request:", {
            { label = "Reactor", value = "reactor" },
            { label = "Turbine", value = "turbine" },
            { label = "Battery", value = "battery" },
            { label = "All systems overview", value = "all" },
        })
    end

    title("Ready to Install")
    print("Role: " .. role)
    if display then print("Display: " .. display) end
    print("Location: " .. INSTALL_DIR)
    print("")
    if not confirm("Install HELIOS?") then
        print("Installation cancelled.")
        return
    end

    if fs.exists(STAGE_DIR) then fs.delete(STAGE_DIR) end
    fs.makeDir(STAGE_DIR)
    for relativePath, contents in pairs(FILES) do
        writeFile(fs.combine(STAGE_DIR, relativePath), contents)
    end
    writeFile(fs.combine(STAGE_DIR, "config.lua"), buildConfig(role, display, existingConfig))

    local previousInstall
    if fs.exists(INSTALL_DIR) then
        previousInstall = "/helios.previous"
        local backupNumber = 2
        while fs.exists(previousInstall) do
            previousInstall = "/helios.previous." .. backupNumber
            backupNumber = backupNumber + 1
        end
        fs.move(INSTALL_DIR, previousInstall)
    end

    local ok, reason = pcall(function()
        fs.move(STAGE_DIR, INSTALL_DIR)
        writeFile("/helios.lua", [=[
shell.run("/helios/helios.lua", ...)
]=])
    end)
    if not ok then
        if fs.exists(INSTALL_DIR) then fs.delete(INSTALL_DIR) end
        if previousInstall and fs.exists(previousInstall) then fs.move(previousInstall, INSTALL_DIR) end
        error("Installation failed and the previous install was restored: " .. tostring(reason), 0)
    end

    local autoStarted, startupNote = installStartup()

    title("Installation Complete")
    term.setTextColor(colors.lime)
    print("HELIOS " .. VERSION .. " installed successfully.")
    term.setTextColor(colors.white)
    print("Role: " .. role)
    if display then print("Display: " .. display) end
    if previousInstall then print("Previous version: " .. previousInstall) end
    if autoStarted then
        print("HELIOS will start automatically after reboot.")
    else
        print(startupNote)
    end
    print("")
    print("Run now with: helios")
    print("Check setup with: helios status")
end

local ok, reason = pcall(runInstaller)
if not ok then
    term.setTextColor(colors.red)
    print("")
    print("HELIOS installation failed:")
    print(tostring(reason))
    term.setTextColor(colors.white)
end
