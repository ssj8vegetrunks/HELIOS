local calls = {}
local currentFlow = 1000
local currentInductor = true
local telemetry = {
    active = true,
    rpm = 900,
    flow = 2000,
    capacity = 4000,
    input = 3400,
}

peripheral = {
    isPresent = function(name) return name == "turbine_0" end,
    getMethods = function(name)
        if name ~= "turbine_0" then return {} end
        return { "setFluidFlowRateMax", "getFluidFlowRateMax",
            "getFluidFlowRateMaxMax", "getFluidFlowRate", "getActive",
            "setActive",
            "getRotorSpeed", "getInputAmount", "getFluidAmountMax",
            "setInductorEngaged", "getInductorEngaged" }
    end,
    call = function(name, method, value)
        calls[#calls + 1] = { name = name, method = method, value = value }
        if method == "setFluidFlowRateMax" then currentFlow = value return end
        if method == "getFluidFlowRateMax" then return currentFlow end
        if method == "getFluidFlowRateMaxMax" then return 2000 end
        if method == "getFluidFlowRate" then return telemetry.flow end
        if method == "getActive" then return telemetry.active end
        if method == "setActive" then telemetry.active = value return end
        if method == "getRotorSpeed" then return telemetry.rpm end
        if method == "getInputAmount" then return telemetry.input end
        if method == "getFluidAmountMax" then return telemetry.capacity end
        if method == "setInductorEngaged" then currentInductor = value return end
        if method == "getInductorEngaged" then return currentInductor end
        error("unexpected method")
    end,
}

local adapter = dofile("module-pack/extreme_reactors/turbine_adapter.lua")
local turbine = { name = "turbine_0", flowRateLimit = 2000 }

local reading = adapter.read(turbine)
assert(reading.inputMax == 4000, "shared turbine fluid capacity was not read")
assert(reading.inputPercent == 85, "turbine steam-buffer percentage was not calculated")
calls = {}

local activeOk, activeState, activeReason = adapter.setActive(turbine, false)
assert(activeOk, tostring(activeReason))
assert(activeState == false and telemetry.active == false,
    "turbine shutdown was not verified")
assert(calls[1].method == "setActive", "wrong turbine power method")
assert(calls[2].method == "getActive", "missing turbine power read-back")

activeOk, activeState, activeReason = adapter.setActive(turbine, true)
assert(activeOk, tostring(activeReason))
assert(activeState == true and telemetry.active == true,
    "turbine startup was not verified")
calls = {}

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
