local contract = dofile("src/core/ui_contract.lua")

local source = {
    helios = true,
    reactors = { { name = "reactor_0", active = true } },
    unsafe = function() error("must not cross UI boundary") end,
}
local snapshot = contract.attach(source)
assert(snapshot.helios == true and snapshot.reactors[1].name == "reactor_0",
    "safe telemetry must survive contract normalization")
assert(snapshot.unsafe == nil, "functions must never cross the UI contract")
assert(snapshot.uiContract.name == "helios.ui" and snapshot.uiContract.version == 1,
    "snapshot must advertise its UI contract")

local command, reason = contract.validateCommand({
    name = "turbine.adjust_flow",
    target = "turbine_0",
    arguments = { delta = 100 },
})
assert(command and reason == nil, "known command must validate")
assert(contract.authorize(command, { controlMode = "automatic" }) == false,
    "manual commands must be rejected in automatic authority")
assert(contract.authorize(command, { controlMode = "manual", remote = true }) == false,
    "remote commands must remain read-only")
assert(contract.authorize(command, { controlMode = "manual", idConflict = true }) == false,
    "ID conflicts must block commands")

local navigation = assert(contract.validateCommand({ name = "navigate" }))
assert(contract.authorize(navigation, { remote = true, idConflict = true }) == true,
    "local navigation must remain available on read-only or conflicted displays")

local called = false
local ok = contract.dispatch({
    name = "turbine.adjust_flow",
    target = "turbine_0",
    arguments = { delta = 100 },
}, { controlMode = "manual" }, {
    ["turbine.adjust_flow"] = function(target, arguments)
        called = target == "turbine_0" and arguments.delta == 100
        return called
    end,
})
assert(ok == true and called == true, "authorized commands must use registered guarded handlers")

ok, reason = contract.dispatch({ name = "unknown" }, {}, {})
assert(ok == false and string.find(reason, "Unsupported", 1, true),
    "unknown commands must fail closed")

print("ui contract tests passed")
