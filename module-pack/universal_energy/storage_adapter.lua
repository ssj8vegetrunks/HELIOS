-- @section GENERIC STORAGE PERIPHERAL ADAPTER
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
