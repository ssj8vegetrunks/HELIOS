local calls = {}
local levels = { [0] = 40, [1] = 40, [2] = 40 }
local stuck = false

peripheral = {
    isPresent = function(name) return name == "reactor_0" end,
    getMethods = function(name)
        if name ~= "reactor_0" then return {} end
        return { "setAllControlRodLevels", "getControlRodsLevels",
            "getNumberOfControlRods" }
    end,
    call = function(name, method, value)
        calls[#calls + 1] = { name = name, method = method, value = value }
        if method == "setAllControlRodLevels" then
            for index = 0, 2 do
                if not stuck or index ~= 2 then levels[index] = value end
            end
            return
        end
        if method == "getControlRodsLevels" then return levels end
        if method == "getNumberOfControlRods" then return 3 end
        error("unexpected method")
    end,
}

local adapter = dofile("src/mainframe/reactor_adapter.lua")
local reactor = { name = "reactor_0", controlRods = 3 }

local ok, applied, reason = adapter.setAllControlRodLevels(reactor, 35)
assert(ok, tostring(reason))
assert(applied == 35, "rod level was not verified")
assert(calls[1].method == "setAllControlRodLevels", "wrong actuator method")
assert(calls[2].method == "getControlRodsLevels", "missing read-back verification")

ok, applied, reason = adapter.setAllControlRodLevels(reactor, 150)
assert(ok, tostring(reason))
assert(applied == 100, "rod level was not clamped")

stuck = true
ok, applied, reason = adapter.setAllControlRodLevels(reactor, 60)
assert(ok == false, "mismatched rods should fail verification")
assert(reason and reason:find("reactor reports", 1, true),
    "mismatch reason was not reported")
stuck = false

local missing = adapter.setAllControlRodLevels({ name = "missing" }, 50)
assert(missing == false, "missing reactor write should fail")

print("reactor actuator tests passed")
