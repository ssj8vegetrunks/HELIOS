-- HELIOS Discovery Probe
-- Standalone, read-only peripheral inventory for CC:Tweaked.
-- Run with: wget run <raw GitHub URL>

local VERSION = "0.1.0"

local function contains(value, fragment)
    return string.find(string.lower(tostring(value or "")), fragment, 1, true) ~= nil
end

local function methodSet(methods)
    local set = {}
    for _, method in ipairs(methods or {}) do set[method] = true end
    return set
end

local function hasAny(methods, names)
    for _, name in ipairs(names) do
        if methods[name] then return true end
    end
    return false
end

local function classify(name, types, methods)
    local available = methodSet(methods)
    local reactor = contains(name, "reactor")
    local turbine = contains(name, "turbine")
    local induction = contains(name, "inductionport") or contains(name, "induction_port")
    for _, peripheralType in ipairs(types) do
        reactor = reactor or contains(peripheralType, "reactor")
        turbine = turbine or contains(peripheralType, "turbine")
        induction = induction or contains(peripheralType, "inductionport") or
            contains(peripheralType, "induction_port")
    end
    if reactor then
        local controllable = hasAny(available, { "setActive", "setControlRodLevel", "setAllControlRodLevels" })
        local readable = hasAny(available, { "getActive", "active", "getEnergyProducedLastTick", "getFuelFilledPercentage" })
        return "REACTOR", controllable and readable and "MANAGEABLE" or "TELEMETRY / API CHECK"
    end
    if turbine then
        local controllable = hasAny(available, { "setActive", "setFluidFlowRateMax", "setInductorEngaged" })
        local readable = hasAny(available, { "getRotorSpeed", "getEnergyProducedLastTick", "getFluidFlowRate" })
        return "TURBINE", controllable and readable and "MANAGEABLE" or "TELEMETRY / API CHECK"
    end
    if induction and available.getEnergy and available.getMaxEnergy then
        return "INDUCTION STORAGE", "MANAGEABLE"
    end
    if (available.getEnergyStored and available.getMaxEnergyStored) or
       (available.getEnergy and available.getEnergyCapacity) or
       (available.getStoredEnergy and available.getEnergyCapacity) or
       (available.getStored and available.getCapacity) then
        return "ENERGY STORAGE", "MANAGEABLE"
    end
    for _, peripheralType in ipairs(types) do
        if peripheralType == "monitor" then return "MONITOR", "DISPLAY" end
        if peripheralType == "modem" then return "MODEM", "NETWORK" end
    end
    return "UNRECOGNISED", "INSPECT"
end

local names = peripheral.getNames()
table.sort(names)
local report, counts = {}, { reactor = 0, turbine = 0, storage = 0, unknown = 0 }
local function emit(line)
    report[#report + 1] = line
end

emit("HELIOS DISCOVERY PROBE v" .. VERSION)
emit("Read-only inventory - no device settings will be changed")
emit(string.rep("-", 46))
for _, name in ipairs(names) do
    local types = { peripheral.getType(name) }
    local methods = peripheral.getMethods(name) or {}
    table.sort(types)
    table.sort(methods)
    local category, status = classify(name, types, methods)
    if category == "REACTOR" then counts.reactor = counts.reactor + 1
    elseif category == "TURBINE" then counts.turbine = counts.turbine + 1
    elseif contains(category, "STORAGE") then counts.storage = counts.storage + 1
    elseif category == "UNRECOGNISED" then counts.unknown = counts.unknown + 1 end
    emit(("[%s] %s"):format(status, name))
    emit("  Class: " .. category)
    emit("  Types: " .. (#types > 0 and table.concat(types, ", ") or "unreported"))
    if status ~= "MANAGEABLE" then
        emit("  Methods: " .. (#methods > 0 and table.concat(methods, ", ") or "none reported"))
    end
end
emit(string.rep("-", 46))
emit(("Summary: %d reactor(s), %d turbine(s), %d storage device(s), %d unrecognised"):format(
    counts.reactor, counts.turbine, counts.storage, counts.unknown))
emit("Result: HELIOS can manage devices marked MANAGEABLE after installation.")
emit("Use the detailed method list on API CHECK / INSPECT devices when reporting compatibility.")

local fileName = "helios-discovery-report.txt"
local handle = fs.open(fileName, "w")
if handle then
    handle.write(table.concat(report, "\n") .. "\n")
    handle.close()
end

-- CC:Tweaked terminals do not retain a normal scrollback buffer.  Present the
-- report through its built-in pager, so every line remains readable in-game.
textutils.pagedPrint(table.concat(report, "\n"), 1)
if handle then print("Saved report to " .. fileName) end
