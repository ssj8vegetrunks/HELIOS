local calls = {}
local levels = { [0] = 40, [1] = 40, [2] = 40 }
local stuck = false

peripheral = {
    isPresent = function(name) return name == "reactor_0" end,
    getMethods = function(name)
        if name ~= "reactor_0" then return {} end
        return { "setControlRodLevel", "getControlRodLevel",
            "getNumberOfControlRods" }
    end,
    call = function(name, method, first, second)
        calls[#calls + 1] = {
            name = name, method = method, first = first, second = second,
        }
        if method == "setControlRodLevel" then
            if not stuck or first ~= 1 then levels[first] = second end
            return
        end
        if method == "getControlRodLevel" then return levels[first] end
        if method == "getNumberOfControlRods" then return 3 end
        error("unexpected method")
    end,
}

local adapter = dofile("src/mainframe/reactor_adapter.lua")
local reactor = { name = "reactor_0", controlRods = 3 }

local ok, applied, reason = adapter.setControlRodExposure(reactor, 1.35)
assert(ok, tostring(reason))
assert(math.abs(applied - 1.35) < 0.001, "exposure was not verified")
assert(levels[0] == 0 and levels[1] == 65 and levels[2] == 100,
    "rod-equivalent layout is incorrect")
assert(calls[4].method == "setControlRodLevel" and calls[4].first == 1,
    "safer insertions should be issued before withdrawals")

ok, applied, reason = adapter.setControlRodExposure(reactor, 99)
assert(ok, tostring(reason))
assert(applied == 3, "exposure should be clamped to the rod count")

stuck = true
ok, applied, reason = adapter.setControlRodExposure(reactor, 0.5)
assert(ok == false, "mismatched rods should fail verification")
assert(reason and reason:find("Rod 1", 1, true),
    "mismatched rod index was not reported")
stuck = false

local missing = adapter.setControlRodExposure({ name = "missing", controlRods = 3 }, 1)
assert(missing == false, "missing reactor write should fail")

print("reactor actuator tests passed")
