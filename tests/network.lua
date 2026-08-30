local calls = {}

rednet = {
    send = function(target, message, protocol)
        calls[#calls + 1] = { operation = "send", target = target,
            message = message, protocol = protocol }
        return true
    end,
    broadcast = function(message, protocol)
        calls[#calls + 1] = { operation = "broadcast", message = message,
            protocol = protocol }
    end,
}

peripheral = {
    getNames = function() return {} end,
    getType = function() return nil end,
}

local network = dofile("src/core/network.lua")

assert(network.send(12, { kind = "hello" }) == true)
assert(calls[1].protocol == "helios.v1", "legacy terminal traffic must retain helios.v1")

assert(network.sendOn("helios.facility.v1", 25, { kind = "heartbeat" }) == true)
assert(calls[2].target == 25 and calls[2].protocol == "helios.facility.v1",
    "facility traffic must use its separate protocol")

assert(network.broadcastOn("helios.facility.v1", { kind = "hello" }) == true)
assert(calls[3].operation == "broadcast" and calls[3].protocol == "helios.facility.v1")

assert(network.sendOn("", 1, {}) == false, "empty protocol names must be rejected")
assert(network.sendOn("helios.facility.v1", "1", {}) == false,
    "non-numeric destinations must be rejected")

print("network transport tests passed")
