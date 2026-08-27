-- HELIOS Draconic Guardian v0.1
-- Standalone, read-only commissioning console.  It intentionally performs no
-- reactor or flow-gate write operation.  Install this only on the computer
-- physically attached to the Draconic reactor-side component and output gate.

local function contains(value, fragment)
    return string.find(string.lower(tostring(value or "")), fragment, 1, true) ~= nil
end

local function hasType(name, fragment)
    for _, peripheralType in ipairs({ peripheral.getType(name) }) do
        if contains(peripheralType, fragment) then return true end
    end
    return false
end

local function sorted(values)
    table.sort(values, function(a, b) return tostring(a) < tostring(b) end)
    return values
end

local function localSides()
    local result = {}
    for _, side in ipairs(rs.getSides()) do
        if peripheral.isPresent(side) then result[side] = true end
    end
    return result
end

local function inspect()
    local localPresent = localSides()
    local reactors, outputGates, modems, monitors = {}, {}, {}, {}
    for side in pairs(localPresent) do
        if hasType(side, "draconic_reactor") then reactors[#reactors + 1] = side end
        if hasType(side, "flow_gate") then outputGates[#outputGates + 1] = side end
        if hasType(side, "modem") then modems[#modems + 1] = side end
        if hasType(side, "monitor") then monitors[#monitors + 1] = side end
    end
    local inputGates = {}
    for _, name in ipairs(peripheral.getNames()) do
        if not localPresent[name] and hasType(name, "flow_gate") then
            inputGates[#inputGates + 1] = name
        end
    end
    sorted(reactors); sorted(outputGates); sorted(modems); sorted(monitors); sorted(inputGates)
    local reasons = {}
    if #reactors ~= 1 then reasons[#reasons + 1] = "Exactly one local Draconic reactor component is required" end
    if #outputGates ~= 1 then reasons[#reasons + 1] = "Exactly one local output flow gate is required" end
    if #modems < 1 then reasons[#reasons + 1] = "A local wired modem/peripheral hub is required" end
    if #inputGates ~= 1 then reasons[#reasons + 1] = "Exactly one remote field-input gate is required" end
    return {
        ready = #reasons == 0, reasons = reasons, reactor = reactors[1], outputGate = outputGates[1],
        modem = modems[1], monitor = monitors[1], inputGate = inputGates[1],
    }
end

local function call(name, method)
    if not name then return nil, "missing" end
    local ok, value = pcall(peripheral.call, name, method)
    if not ok then return nil, tostring(value) end
    return value
end

local function read(binding)
    local reactor, errorText = call(binding.reactor, "getReactorInfo")
    if type(reactor) ~= "table" then return nil, errorText or "Reactor telemetry unavailable" end
    local inputFlow = call(binding.inputGate, "getFlow")
    local outputFlow = call(binding.outputGate, "getFlow")
    local inputOverride = call(binding.inputGate, "getOverrideEnabled")
    local outputOverride = call(binding.outputGate, "getOverrideEnabled")
    return {
        reactor = reactor,
        inputFlow = inputFlow, outputFlow = outputFlow,
        inputOverride = inputOverride, outputOverride = outputOverride,
    }
end

local function value(data, key)
    local item = data.reactor[key]
    return item == nil and "N/A" or tostring(item)
end

local function line(target, y, text, colour)
    local width = select(1, target.getSize())
    target.setCursorPos(1, y)
    target.setTextColor(colour or colors.white)
    target.write(string.sub(tostring(text), 1, width))
end

local function bar(target, y, label, current, maximum, colour)
    local width = select(1, target.getSize())
    local usable = math.max(8, width - 2)
    local fraction = 0
    if tonumber(maximum) and tonumber(maximum) > 0 and tonumber(current) then
        fraction = math.max(0, math.min(1, tonumber(current) / tonumber(maximum)))
    end
    line(target, y, label, colors.lightGray)
    target.setCursorPos(1, y + 1)
    target.setBackgroundColor(colors.gray)
    target.write(string.rep(" ", usable))
    target.setCursorPos(1, y + 1)
    target.setBackgroundColor(colour)
    target.write(string.rep(" ", math.max(1, math.floor(usable * fraction))))
    target.setBackgroundColor(colors.black)
    line(target, y + 2, tostring(current or "N/A") .. " / " .. tostring(maximum or "N/A"), colors.white)
end

local function draw(target, binding, data, page, message)
    local width, height = target.getSize()
    target.setBackgroundColor(colors.black)
    target.setTextColor(colors.white)
    target.clear()
    line(target, 1, "HELIOS // DRACONIC GUARDIAN", colors.yellow)
    line(target, 2, "READ-ONLY COMMISSIONING  |  NO ACTUATOR COMMANDS ENABLED", colors.orange)
    line(target, 3, "[OVERVIEW] [RAW DATA] [SETUP]", colors.cyan)
    if not binding.ready then
        line(target, 5, "SETUP INVALID", colors.red)
        for index, reason in ipairs(binding.reasons) do line(target, 5 + index, "- " .. reason, colors.white) end
        return
    end
    if not data then
        line(target, 5, "TELEMETRY LOST: " .. tostring(message), colors.red)
        return
    end
    if page == "setup" then
        line(target, 5, "SETUP VALID", colors.lime)
        line(target, 7, "Local reactor component: " .. binding.reactor, colors.white)
        line(target, 8, "Local output gate:       " .. binding.outputGate, colors.white)
        line(target, 9, "Local wired modem:       " .. binding.modem, colors.white)
        line(target, 10, "Remote field-input gate: " .. binding.inputGate, colors.white)
        line(target, 12, "This computer is the only hardware-control boundary.", colors.orange)
        return
    end
    if page == "raw" then
        line(target, 5, "RAW REACTOR API VALUES", colors.cyan)
        local keys = {}
        for key in pairs(data.reactor) do keys[#keys + 1] = tostring(key) end
        sorted(keys)
        local row = 7
        for _, key in ipairs(keys) do
            if row > height - 2 then break end
            line(target, row, key .. ": " .. tostring(data.reactor[key]), colors.white)
            row = row + 1
        end
        line(target, height - 1, "Input gate flow: " .. tostring(data.inputFlow) .. "  Output gate flow: " .. tostring(data.outputFlow), colors.lightGray)
        return
    end
    line(target, 5, "STATE: " .. value(data, "status"), colors.lime)
    line(target, 6, "Generation: " .. value(data, "generationRate") .. " RF/t", colors.cyan)
    line(target, 7, "Temperature: " .. value(data, "temperature") .. " C", colors.orange)
    bar(target, 9, "ENERGY SATURATION", data.reactor.energySaturation, data.reactor.maxEnergySaturation, colors.blue)
    bar(target, 13, "FIELD STRENGTH", data.reactor.fieldStrength, data.reactor.maxFieldStrength, colors.red)
    if height >= 21 then
        bar(target, 17, "FUEL CONVERSION", data.reactor.fuelConversion, data.reactor.maxFuelConversion, colors.lime)
    end
    line(target, height - 2, "FIELD INPUT: " .. tostring(data.inputFlow) .. "  OUTPUT: " .. tostring(data.outputFlow), colors.yellow)
    line(target, height - 1, "Override input/output: " .. tostring(data.inputOverride) .. " / " .. tostring(data.outputOverride), colors.lightGray)
end

local function chooseTarget(binding)
    -- A direct monitor is preferred.  A remote monitor is intentionally not
    -- selected: mainframes on that same bus could repaint it.
    if binding.monitor then return peripheral.wrap(binding.monitor) end
    return term.current()
end

local binding = inspect()
local target = chooseTarget(binding)
local page = "overview"
while true do
    local data, reason
    if binding.ready then data, reason = read(binding) end
    draw(target, binding, data, page, reason)
    local timer = os.startTimer(1)
    while true do
        local event, a, b, c = os.pullEvent()
        if event == "timer" and a == timer then break end
        if event == "key" then
            if a == keys.q then return end
            if a == keys.one then page = "overview" break end
            if a == keys.two then page = "raw" break end
            if a == keys.three then page = "setup" break end
        elseif event == "monitor_touch" and target ~= term.current() then
            local x, y = b, c
            if y == 3 then
                if x <= 10 then page = "overview" elseif x <= 21 then page = "raw" else page = "setup" end
                break
            end
        elseif event == "peripheral" or event == "peripheral_detach" then
            binding = inspect()
            target = chooseTarget(binding)
            break
        end
    end
end
