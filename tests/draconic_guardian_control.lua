local writes, calls = {}, {}
local overrides = { right = false, flow_gate_1 = false }
local overrideFlows = { right = 0, flow_gate_1 = 0 }
local target = {}
for _, method in ipairs({ "setBackgroundColor", "setTextColor", "clear", "setCursorPos", "write" }) do
    target[method] = function() end
end
target.getSize = function() return 60, 40 end
local monitorTarget = {}
for _, method in ipairs({ "setBackgroundColor", "setTextColor", "clear", "setCursorPos", "write" }) do
    monitorTarget[method] = target[method]
end
monitorTarget.getSize = target.getSize

colors = { white = 1, black = 2, yellow = 4, orange = 8, cyan = 16, lime = 32,
    lightGray = 64, gray = 128, blue = 256, red = 512 }
keys = { q = 1, one = 2, two = 3, three = 4, m = 5, o = 6, n = 7, d = 8, x = 9, v = 10 }
rs = { getSides = function() return { "back", "right", "bottom", "top" } end }
fs = {
    exists = function() return false end,
    open = function() return { write = function() end, close = function() end } end,
}
textutils = { serialize = function() return "{}" end }
term = { current = function() return target end }
peripheral = {
    isPresent = function(side) return side == "back" or side == "right" or side == "bottom" or side == "top" end,
    getNames = function() return { "back", "right", "bottom", "top", "flow_gate_1" } end,
    getType = function(name)
        if name == "back" then return "draconic_reactor" end
        if name == "right" or name == "flow_gate_1" then return "flow_gate" end
        if name == "top" then return "monitor" end
        return "modem"
    end,
    wrap = function() return monitorTarget end,
    call = function(name, method, argument)
        if method == "getReactorInfo" then return {
            status = "running", generationRate = math.min(overrideFlows.right, 5000000), temperature = 2000,
            fieldStrength = 60, maxFieldStrength = 100, fieldDrainRate = 100,
            fuelConversion = 10, maxFuelConversion = 1000,
            energySaturation = 1, maxEnergySaturation = 100,
        } end
        if method == "getFlow" then return name == "right" and math.min(overrideFlows.right, 5000000) or 0 end
        if method == "getSignalLowFlow" then return name == "right" and 1000000 or 900000 end
        if method == "getOverrideEnabled" then return overrides[name] end
        if method == "getFlowOverride" then return overrideFlows[name] end
        if method == "setOverrideEnabled" then overrides[name] = argument; writes[#writes + 1] = { name, method, argument }; return true end
        if method == "setFlowOverride" then overrideFlows[name] = argument; writes[#writes + 1] = { name, argument }; return true end
        if method == "setSignalLowFlow" then writes[#writes + 1] = { name, argument }; return end
        calls[#calls + 1] = { name, method }
    end,
}

local events = { { "monitor_touch", "top", 1, 33 } } -- start automatic commissioning
-- The simulated output path accepts up to 5M RF/t. Calibration must test
-- beyond its former fixed 4M ceiling, then retain the last proven step.
for _ = 1, 600 do events[#events + 1] = { "timer", 1 } end
events[#events + 1] = { "monitor_touch", "top", 1, 33 } -- enable assisted manual
events[#events + 1] = { "monitor_touch", "top", 1, 33 } -- select OFF
events[#events + 1] = { "key", keys.q }
os = {
    startTimer = function() return 1 end,
    pullEvent = function()
        local event = table.remove(events, 1)
        return table.unpack(event)
    end,
}

dofile("draconic_guardian.lua")

local sawStop, sawCommissionFlow, sawBeyondFormerCap = false, false, false
for _, entry in ipairs(calls) do if entry[2] == "stopReactor" then sawStop = true end end
for _, entry in ipairs(writes) do if entry[1] == "right" and entry[2] == 50000 then sawCommissionFlow = true end end
for _, entry in ipairs(writes) do if entry[1] == "right" and type(entry[2]) == "number" and entry[2] > 4000000 then sawBeyondFormerCap = true end end
assert(sawStop, "manual OFF must request a controlled reactor stop")
assert(sawCommissionFlow, "automatic commissioning must apply its conservative export")
assert(sawBeyondFormerCap, "automatic calibration must not impose the former fixed 4M RF/t ceiling")
assert(overrides.right and overrides.flow_gate_1, "Guardian must acquire direct override of both gates")
print("draconic guardian control tests passed")

