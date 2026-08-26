-- @section PERIPHERAL DISCOVERY AND REGISTRY
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
    for _, peripheralType in ipairs(types) do
        if contains(peripheralType, "turbine") then return "turbine" end
    end
    if contains(name, "turbine") then return "turbine" end
    for _, peripheralType in ipairs(types) do
        if contains(peripheralType, "reactor") then return "reactor" end
    end
    if contains(name, "reactor") then return "reactor" end
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
        (available.getEnergy and available.getMaxEnergy) or
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
