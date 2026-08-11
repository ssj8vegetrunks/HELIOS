local calls = {}
local currentFlow = 1000
local currentInductor = true

peripheral = {
    isPresent = function(name) return name == "turbine_0" end,
    getMethods = function(name)
        if name ~= "turbine_0" then return {} end
        return { "setFluidFlowRateMax", "getFluidFlowRateMax",
            "setInductorEngaged", "getInductorEngaged" }
    end,
    call = function(name, method, value)
        calls[#calls + 1] = { name = name, method = method, value = value }
        if method == "setFluidFlowRateMax" then currentFlow = value return end
        if method == "getFluidFlowRateMax" then return currentFlow end
        if method == "setInductorEngaged" then currentInductor = value return end
        if method == "getInductorEngaged" then return currentInductor end
        error("unexpected method")
    end,
}

local adapter = dofile("src/mainframe/turbine_adapter.lua")
local turbine = { name = "turbine_0", flowRateLimit = 2000 }

local ok, applied, reason = adapter.setFlowLimit(turbine, 1100)
assert(ok, tostring(reason))
assert(applied == 1100, "flow limit was not verified")
assert(calls[1].method == "setFluidFlowRateMax", "wrong actuator method")
assert(calls[2].method == "getFluidFlowRateMax", "missing read-back verification")

ok, applied, reason = adapter.setFlowLimit(turbine, 2500)
assert(ok, tostring(reason))
assert(applied == 2000, "hard flow limit was not enforced")

local missing = adapter.setFlowLimit({ name = "missing", flowRateLimit = 2000 }, 1000)
assert(missing == false, "missing turbine write should fail")

ok, applied, reason = adapter.setInductor(turbine, false)
assert(ok, tostring(reason))
assert(applied == false, "inductor state was not verified")
assert(currentInductor == false, "inductor was not disengaged")

ok, applied, reason = adapter.setInductor(turbine, true)
assert(ok, tostring(reason))
assert(applied == true, "inductor re-engagement was not verified")

print("turbine actuator tests passed")
