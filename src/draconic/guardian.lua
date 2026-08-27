-- HELIOS Draconic Guardian v0.1
-- This first release is deliberately telemetry-only.  It validates the local
-- installation contract and never calls an actuator method on a reactor or
-- flow gate.

local guardian = {}

local function contains(value, fragment)
    return string.find(string.lower(tostring(value or "")), fragment, 1, true) ~= nil
end

local function hasType(name, fragment)
    for _, peripheralType in ipairs({ peripheral.getType(name) }) do
        if contains(peripheralType, fragment) then return true end
    end
    return false
end

local function sortNames(names)
    table.sort(names, function(a, b) return tostring(a) < tostring(b) end)
    return names
end

local function localNames()
    local result = {}
    for _, side in ipairs(rs.getSides()) do
        if peripheral.isPresent(side) then result[side] = true end
    end
    return result
end

local function namesText(names)
    return #names > 0 and table.concat(names, ", ") or "none"
end

function guardian.inspect()
    local localPresent = localNames()
    local localReactors, localGates, localModems, localMonitors = {}, {}, {}, {}
    for side in pairs(localPresent) do
        if hasType(side, "draconic_reactor") then localReactors[#localReactors + 1] = side end
        if hasType(side, "flow_gate") then localGates[#localGates + 1] = side end
        if hasType(side, "modem") then localModems[#localModems + 1] = side end
        if hasType(side, "monitor") then localMonitors[#localMonitors + 1] = side end
    end
    sortNames(localReactors)
    sortNames(localGates)
    sortNames(localModems)
    sortNames(localMonitors)

    local remoteGates, remoteMonitors = {}, {}
    for _, name in ipairs(peripheral.getNames()) do
        if not localPresent[name] then
            if hasType(name, "flow_gate") then remoteGates[#remoteGates + 1] = name end
            if hasType(name, "monitor") then remoteMonitors[#remoteMonitors + 1] = name end
        end
    end
    sortNames(remoteGates)
    sortNames(remoteMonitors)

    local reasons = {}
    if #localReactors ~= 1 then
        reasons[#reasons + 1] = "Require exactly one local Draconic reactor-side component"
    end
    if #localGates ~= 1 then
        reasons[#reasons + 1] = "Require exactly one local output flow gate"
    end
    if #localModems < 1 then
        reasons[#reasons + 1] = "Require a local wired modem/peripheral hub"
    end
    if #remoteGates ~= 1 then
        reasons[#reasons + 1] = "Require exactly one remote field-input flow gate"
    end

    local reactorSide = localReactors[1]
    if reactorSide then
        local methods = peripheral.getMethods(reactorSide) or {}
        local readable = false
        for _, method in ipairs(methods) do
            if method == "getReactorInfo" then readable = true end
        end
        if not readable then reasons[#reasons + 1] = "Local reactor component lacks getReactorInfo" end
    end

    return {
        ready = #reasons == 0,
        reasons = reasons,
        reactorSide = reactorSide,
        outputGateSide = localGates[1],
        modemSide = localModems[1],
        inputGateName = remoteGates[1],
        monitorName = remoteMonitors[1] or localMonitors[1],
        localReactors = localReactors,
        localGates = localGates,
        remoteGates = remoteGates,
    }
end

function guardian.telemetry(binding)
    if not binding or not binding.ready then return nil, "Guardian setup is incomplete" end
    local ok, info = pcall(peripheral.call, binding.reactorSide, "getReactorInfo")
    if not ok or type(info) ~= "table" then
        return nil, "getReactorInfo failed: " .. tostring(info)
    end
    return info
end

local function printBinding(binding)
    print("HELIOS // DRACONIC GUARDIAN v0.1")
    print("MODE: READ-ONLY VALIDATION")
    print("")
    print("Local reactor component: " .. tostring(binding.reactorSide or "MISSING"))
    print("Local output gate:       " .. tostring(binding.outputGateSide or "MISSING"))
    print("Local modem:             " .. tostring(binding.modemSide or "MISSING"))
    print("Remote field-input gate: " .. tostring(binding.inputGateName or "MISSING"))
    print("Monitor:                 " .. tostring(binding.monitorName or "optional / none"))
    print("")
    if binding.ready then
        print("SETUP VALID: no control commands have been sent.")
    else
        print("SETUP INVALID:")
        for _, reason in ipairs(binding.reasons) do print("- " .. reason) end
    end
end

function guardian.run(action)
    local binding = guardian.inspect()
    if action ~= "check" and action ~= "telemetry" then
        error("Usage: helios draconic [check|telemetry]", 0)
    end
    printBinding(binding)
    if action == "telemetry" and binding.ready then
        local info, reason = guardian.telemetry(binding)
        if not info then
            print("Telemetry error: " .. tostring(reason))
            return
        end
        print("")
        print("Live reactor telemetry:")
        for _, key in ipairs({ "status", "generationRate", "temperature", "fieldStrength",
            "maxFieldStrength", "fieldDrainRate", "energySaturation", "maxEnergySaturation",
            "fuelConversion", "maxFuelConversion" }) do
            if info[key] ~= nil then print(key .. ": " .. tostring(info[key])) end
        end
    end
end

return guardian
