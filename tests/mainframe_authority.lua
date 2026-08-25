local authority = dofile("src/core/mainframe_authority.lua")

local single = authority.new("auto", 10)
assert(authority.canControl(single), "a lone auto mainframe should control")

local first = authority.new("auto", 10)
local second = authority.new("auto", 20)
authority.observe(first, 20, { kind = "mainframe_presence", authority = "auto" }, 1)
authority.observe(second, 10, { kind = "mainframe_presence", authority = "auto" }, 1)
assert(authority.needsSelection(first) and authority.needsSelection(second),
    "two automatic mainframes should require selection")
assert(not authority.canControl(first) and not authority.canControl(second),
    "neither mainframe may control before selection")

authority.select(first, "control")
assert(authority.canControl(first), "selected mainframe should control")
local changed = authority.observe(second, 10,
    { kind = "mainframe_presence", authority = "control" }, 2)
assert(changed and second.mode == "monitor", "peer should default to monitoring")

local higher = authority.new("control", 20)
authority.observe(higher, 10, { kind = "mainframe_presence", authority = "control" }, 1)
assert(higher.mode == "monitor", "lower computer ID should win simultaneous control")
authority.select(higher, "control")
assert(higher.mode == "monitor", "selection must not override an existing lower-ID controller")
authority.expire(higher, 10, 5)
assert(not authority.canControl(higher), "monitoring mode must persist after peer loss")

print("mainframe authority tests passed")
