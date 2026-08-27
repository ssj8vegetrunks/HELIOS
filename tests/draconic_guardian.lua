local types = {
    right = "draconic_reactor",
    back = "flow_gate",
    bottom = "modem",
    flow_gate_1 = "flow_gate",
    monitor_1 = "monitor",
}
local localDevices = { right = true, back = true, bottom = true }
local calls = {}

rs = { getSides = function() return { "left", "right", "front", "back", "top", "bottom" } end }
peripheral = {
    isPresent = function(name) return localDevices[name] == true end,
    getType = function(name) return types[name] end,
    getNames = function() return { "right", "back", "bottom", "flow_gate_1", "monitor_1" } end,
    getMethods = function(name)
        if name == "right" then return { "getReactorInfo", "activateReactor", "stopReactor" } end
        if name == "back" or name == "flow_gate_1" then return { "getFlow", "setSignalLowFlow" } end
        return {}
    end,
    call = function(name, method)
        calls[#calls + 1] = { name = name, method = method }
        if name == "right" and method == "getReactorInfo" then
            return { status = "offline", temperature = 20, fieldStrength = 1, maxFieldStrength = 1 }
        end
        error("unexpected peripheral call")
    end,
}

local guardian = dofile("src/draconic/guardian.lua")
local binding = guardian.inspect()
assert(binding.ready, "the documented local Guardian layout should validate")
assert(binding.reactorSide == "right" and binding.outputGateSide == "back", "local bindings should be deterministic")
assert(binding.inputGateName == "flow_gate_1", "the sole remote gate should be the field-input gate")
local info = assert(guardian.telemetry(binding))
assert(info.status == "offline", "telemetry should be returned unchanged")
assert(#calls == 1 and calls[1].method == "getReactorInfo", "validation must never invoke actuator methods")

types.flow_gate_2 = "flow_gate"
peripheral.getNames = function() return { "right", "back", "bottom", "flow_gate_1", "flow_gate_2" } end
local invalid = guardian.inspect()
assert(not invalid.ready, "ambiguous remote gates must reject setup")

print("draconic guardian tests passed")
