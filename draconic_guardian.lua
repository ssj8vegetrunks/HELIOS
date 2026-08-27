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
    local inputSetting = call(binding.inputGate, "getSignalLowFlow")
    local outputSetting = call(binding.outputGate, "getSignalLowFlow")
    local inputOverride = call(binding.inputGate, "getOverrideEnabled")
    local outputOverride = call(binding.outputGate, "getOverrideEnabled")
    return {
        reactor = reactor,
        inputFlow = inputFlow, outputFlow = outputFlow,
        inputSetting = inputSetting, outputSetting = outputSetting,
        inputOverride = inputOverride, outputOverride = outputOverride,
    }
end

-- These are intentionally hard limits.  The selector may request more or
-- less power, but it may never weaken these containment protections.
local FIELD_TARGET = 50
local FIELD_EMERGENCY = 15
local MAX_TEMPERATURE = 8000
local SAFE_RESTART_TEMPERATURE = 3000
local MINIMUM_FUEL = 10
local REQUEST_FRACTIONS = { OFF = 0, MIN = 0.25, MED = 0.50, MAX = 0.75, OVERDRIVE = 1.00 }

local function percent(current, maximum)
    if not tonumber(current) or not tonumber(maximum) or tonumber(maximum) <= 0 then return nil end
    return tonumber(current) / tonumber(maximum) * 100
end

local function setGate(name, flow)
    flow = math.max(0, math.floor(tonumber(flow) or 0))
    return pcall(peripheral.call, name, "setSignalLowFlow", flow)
end

local function callReactor(name, method)
    return pcall(peripheral.call, name, method)
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

local button
local hit

local function draw(target, binding, data, page, message, controls, safety, overdriveConfirm, buttons)
    local width, height = target.getSize()
    target.setBackgroundColor(colors.black)
    target.setTextColor(colors.white)
    target.clear()
    line(target, 1, "HELIOS // DRACONIC GUARDIAN", colors.yellow)
    line(target, 2, "GUARDED CONTROL  |  HARD CONTAINMENT LIMITS ACTIVE", colors.orange)
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

    if height < 29 then
        line(target, height - 4, "Manual output controls require a larger monitor.", colors.orange)
        return
    end
    local controlRow = height - 7
    line(target, controlRow, "OUTPUT REQUEST: " .. tostring(controls.requested) ..
        "  |  PERMITTED: SAFETY CONTROLLER ONLY", colors.yellow)
    if not controls.manualEnabled then
        buttons[#buttons + 1] = button(target, 1, controlRow + 2, "ENABLE MANUAL OUTPUT", colors.orange)
        line(target, controlRow + 4, "Manual requests are recorded only until commissioning is complete.", colors.lightGray)
    elseif overdriveConfirm then
        line(target, controlRow + 2, "OVERDRIVE stays within hard containment limits.", colors.red)
        buttons[#buttons + 1] = button(target, 1, controlRow + 4, "ENABLE OVERDRIVE", colors.red)
        buttons[#buttons + 1] = button(target, 20, controlRow + 4, "CANCEL", colors.lightGray)
    else
        local x = 1
        for _, choice in ipairs({ "OFF", "MIN", "MED", "MAX", "OVERDRIVE" }) do
            local colour = choice == "OVERDRIVE" and colors.red or colors.cyan
            local item = button(target, x, controlRow + 2, choice, colour)
            buttons[#buttons + 1] = item
            x = item.x2 + 2
        end
        buttons[#buttons + 1] = button(target, 1, controlRow + 4, "DISABLE MANUAL", colors.lightGray)
        line(target, controlRow + 5, "Guardian: " .. tostring(safety.last or controls.lastAction), colors.lightGray)
    end
end

local function chooseTarget(binding)
    -- A direct monitor is preferred.  A remote monitor is intentionally not
    -- selected: mainframes on that same bus could repaint it.
    if binding.monitor then return peripheral.wrap(binding.monitor) end
    return term.current()
end

local SETTINGS_FILE = ".helios-draconic-guardian.lua"
local saveControls

local function loadControls()
    if not fs.exists(SETTINGS_FILE) then
        return { manualEnabled = false, requested = "AUTO", overdriveEnabled = false,
            lastAction = "Automatic safe supervision selected", ratedOutput = nil }
    end
    local ok, saved = pcall(dofile, SETTINGS_FILE)
    if not ok or type(saved) ~= "table" then return loadControls() end
    return {
        manualEnabled = saved.manualEnabled == true,
        requested = ({ OFF = true, MIN = true, MED = true, MAX = true, OVERDRIVE = true })[saved.requested]
            and saved.requested or "AUTO",
        overdriveEnabled = saved.overdriveEnabled == true,
        lastAction = tostring(saved.lastAction or "Restored Guardian control preference"),
        ratedOutput = tonumber(saved.ratedOutput),
    }
end

local function control(binding, data, controls, safety)
    local reactor = data.reactor
    local fieldPercent = percent(reactor.fieldStrength, reactor.maxFieldStrength)
    local fuelPercent = percent((tonumber(reactor.maxFuelConversion) or 0) -
        (tonumber(reactor.fuelConversion) or 0), reactor.maxFuelConversion)
    local temperature = tonumber(reactor.temperature) or math.huge
    local status = string.lower(tostring(reactor.status or "unknown"))
    local outputCeiling = tonumber(controls.ratedOutput)
    if not outputCeiling or outputCeiling <= 0 then
        outputCeiling = math.max(tonumber(data.outputSetting) or 0, tonumber(reactor.generationRate) or 0)
        if outputCeiling > 0 then
            controls.ratedOutput = outputCeiling
            saveControls(controls)
        end
    end

    -- Safeguards always take priority, including when manual output is off.
    if fuelPercent and fuelPercent <= MINIMUM_FUEL then
        setGate(binding.outputGate, 0)
        callReactor(binding.reactor, "stopReactor")
        safety.last = "EMERGENCY: fuel reserve below " .. MINIMUM_FUEL .. "%"
        safety.stopForFuel = true
        return safety
    end
    if fieldPercent and fieldPercent <= FIELD_EMERGENCY and status == "online" then
        setGate(binding.outputGate, 0)
        callReactor(binding.reactor, "stopReactor")
        callReactor(binding.reactor, "chargeReactor")
        setGate(binding.inputGate, 900000)
        safety.chargeField = true
        safety.last = "EMERGENCY: containment field below " .. FIELD_EMERGENCY .. "%"
        return safety
    end
    if temperature > MAX_TEMPERATURE then
        setGate(binding.outputGate, 0)
        callReactor(binding.reactor, "stopReactor")
        safety.cooling = true
        safety.last = "EMERGENCY: temperature above " .. MAX_TEMPERATURE .. " C"
        return safety
    end

    if controls.manualEnabled and controls.requested == "OFF" then
        setGate(binding.outputGate, 0)
        callReactor(binding.reactor, "stopReactor")
        safety.last = "Manual OFF applied: export closed and reactor stopping"
        return safety
    end

    if status == "charging" then
        setGate(binding.inputGate, 900000)
        safety.last = "Charging containment energy"
        return safety
    end

    if safety.cooling and temperature < SAFE_RESTART_TEMPERATURE then
        safety.cooling = false
        if controls.manualEnabled and controls.requested ~= "OFF" then
            callReactor(binding.reactor, "activateReactor")
            safety.last = "Temperature recovered; restarting requested output"
        end
    end

    if controls.manualEnabled and controls.requested ~= "OFF" then
        if status == "offline" or status == "stopping" then
            callReactor(binding.reactor, "chargeReactor")
            setGate(binding.inputGate, 900000)
            safety.last = "Charging reactor for requested output"
            return safety
        elseif status == "charged" then
            callReactor(binding.reactor, "activateReactor")
            safety.last = "Starting reactor for requested output"
            return safety
        end
    end

    if status == "online" then
        local drain = tonumber(reactor.fieldDrainRate) or 0
        -- Holds the field around FIELD_TARGET percent (same control equation
        -- used by the established Draconic monitor controller).
        setGate(binding.inputGate, math.max(1, drain / (1 - FIELD_TARGET / 100)))
        if controls.manualEnabled then
            local fraction = REQUEST_FRACTIONS[controls.requested] or 0
            setGate(binding.outputGate, (outputCeiling or 0) * fraction)
            safety.last = "Manual " .. controls.requested .. " output applied"
        else
            safety.last = "Automatic safe supervision; output unchanged"
        end
    end
    return safety
end

saveControls = function(controls)
    local handle = fs.open(SETTINGS_FILE, "w")
    if not handle then return end
    handle.write("return " .. textutils.serialize(controls))
    handle.close()
end

button = function(target, x, y, label, colour)
    target.setCursorPos(x, y)
    target.setTextColor(colour or colors.cyan)
    local text = "[" .. label .. "]"
    target.write(text)
    return { x1 = x, x2 = x + #text - 1, y = y, label = label }
end

hit = function(buttons, x, y)
    for _, item in ipairs(buttons or {}) do
        if y == item.y and x >= item.x1 and x <= item.x2 then return item.label end
    end
end

local binding = inspect()
local target = chooseTarget(binding)
local page = "overview"
local controls = loadControls()
local overdriveConfirm = false
local buttons = {}
local safety = { last = "Awaiting telemetry" }

local function selectOutput(choice)
    if choice == "ENABLE MANUAL OUTPUT" then
        controls.manualEnabled = true
        controls.requested = "OFF"
        controls.lastAction = "Manual output enabled; request set to OFF"
    elseif choice == "DISABLE MANUAL" then
        controls.manualEnabled = false
        controls.requested = "AUTO"
        controls.lastAction = "Manual output disabled; automatic request restored"
        overdriveConfirm = false
    elseif choice == "OVERDRIVE" then
        overdriveConfirm = true
        controls.lastAction = "Overdrive confirmation requested"
    elseif choice == "ENABLE OVERDRIVE" then
        controls.overdriveEnabled = true
        controls.requested = "OVERDRIVE"
        controls.lastAction = "Overdrive requested; hard safety limits remain active"
        overdriveConfirm = false
    elseif choice == "CANCEL" then
        overdriveConfirm = false
        controls.lastAction = "Overdrive confirmation cancelled"
    elseif choice == "OFF" or choice == "MIN" or choice == "MED" or choice == "MAX" then
        controls.requested = choice
        controls.lastAction = "Manual " .. choice .. " output requested"
    else
        return false
    end
    saveControls(controls)
    return true
end

while true do
    local data, reason
    if binding.ready then data, reason = read(binding) end
    if data then safety = control(binding, data, controls, safety) end
    buttons = {}
    draw(target, binding, data, page, reason, controls, safety, overdriveConfirm, buttons)
    local timer = os.startTimer(1)
    while true do
        local event, a, b, c = os.pullEvent()
        if event == "timer" and a == timer then break end
        if event == "key" then
            if a == keys.q then return end
            if a == keys.one then page = "overview" break end
            if a == keys.two then page = "raw" break end
            if a == keys.three then page = "setup" break end
            if a == keys.m then selectOutput("ENABLE MANUAL OUTPUT"); break end
            if controls.manualEnabled then
                local choices = {
                    [keys.o] = "OFF", [keys.n] = "MIN", [keys.d] = "MED",
                    [keys.x] = "MAX", [keys.v] = "OVERDRIVE",
                }
                if choices[a] and selectOutput(choices[a]) then break end
            end
        elseif event == "monitor_touch" and target ~= term.current() then
            local x, y = b, c
            if y == 3 then
                if x <= 10 then page = "overview" elseif x <= 21 then page = "raw" else page = "setup" end
                break
            end
            local choice = hit(buttons, x, y)
            if choice and selectOutput(choice) then break end
        elseif event == "peripheral" or event == "peripheral_detach" then
            binding = inspect()
            target = chooseTarget(binding)
            break
        end
    end
end
