local writes, calls = {}, {}
local target = {}
for _, method in ipairs({ "setBackgroundColor", "setTextColor", "clear", "setCursorPos", "write" }) do
    target[method] = function() end
end
target.getSize = function() return 60, 40 end

colors = { white = 1, black = 2, yellow = 4, orange = 8, cyan = 16, lime = 32,
    lightGray = 64, gray = 128, blue = 256, red = 512 }
keys = { q = 1, one = 2, two = 3, three = 4, m = 5, o = 6, n = 7, d = 8, x = 9, v = 10 }
rs = { getSides = function() return { "back", "right", "bottom" } end }
fs = {
    exists = function() return false end,
    open = function() return { write = function() end, close = function() end } end,
}
textutils = { serialize = function() return "{}" end }
term = { current = function() return target end }
peripheral = {
    isPresent = function(side) return side == "back" or side == "right" or side == "bottom" end,
    getNames = function() return { "back", "right", "bottom", "flow_gate_1" } end,
    getType = function(name)
        if name == "back" then return "draconic_reactor" end
        if name == "right" or name == "flow_gate_1" then return "flow_gate" end
        return "modem"
    end,
    call = function(name, method, argument)
        if method == "getReactorInfo" then return {
            status = "online", generationRate = 1000000, temperature = 2000,
            fieldStrength = 60, maxFieldStrength = 100, fieldDrainRate = 100,
            fuelConversion = 10, maxFuelConversion = 1000,
            energySaturation = 1, maxEnergySaturation = 100,
        } end
        if method == "getFlow" then return 0 end
        if method == "getSignalLowFlow" then return name == "right" and 1000000 or 900000 end
        if method == "getOverrideEnabled" then return false end
        if method == "setSignalLowFlow" then writes[#writes + 1] = { name, argument }; return end
        calls[#calls + 1] = { name, method }
    end,
}

local events = {
    { "key", keys.m }, -- opt into manual mode (starts safely at OFF)
    { "key", keys.d }, -- MED should request 50% of the learned 1,000,000 ceiling
    { "key", keys.q },
}
os = {
    startTimer = function() return 1 end,
    pullEvent = function()
        local event = table.remove(events, 1)
        return table.unpack(event)
    end,
}

dofile("draconic_guardian.lua")

local sawStop, sawMedium = false, false
for _, entry in ipairs(calls) do if entry[2] == "stopReactor" then sawStop = true end end
for _, entry in ipairs(writes) do if entry[1] == "right" and entry[2] == 500000 then sawMedium = true end end
assert(sawStop, "manual OFF must request a controlled reactor stop")
assert(not sawMedium, "uncommissioned output must not be applied")
print("draconic guardian control tests passed")
