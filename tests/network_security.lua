bit32 = bit32 or require("bit32")
os.getComputerID = os.getComputerID or function() return 10 end
os.epoch = os.epoch or function() return 1000000 end

local security = dofile("src/core/network_security.lua")
local protected = { network = { securityEnabled = true, securityKey = "correct horse battery" } }
local other = { network = { securityEnabled = true, securityKey = "different network key" } }
local open = { network = { securityEnabled = false, securityKey = "" } }

assert(security.enabled(protected), "a valid enabled key must activate protection")
assert(not security.enabled(open), "open networks must remain supported")
assert(#security.networkId(protected) == 12, "protected networks need a short public identity")
local message = assert(security.sign({ helios=true, kind="hello", payload={ b=2, a=1 } },
    protected, "helios.v1"))
assert(security.verify(message, protected, "helios.v1", message.networkSentAt),
    "the matching network must accept an intact packet")
local numeric = assert(security.sign({ helios=true, kind="snapshot", value=1 / 3 },
    protected, "helios.v1"))
assert(security.verify(numeric, protected, "helios.v1", numeric.networkSentAt / 1000),
    "telemetry numbers and millisecond timestamps must verify")
assert(not security.verify(message, other, "helios.v1", message.networkSentAt),
    "a different network key must be rejected")
message.payload.a = 9
assert(not security.verify(message, protected, "helios.v1", message.networkSentAt),
    "altered packets must be rejected")
assert(security.verify({ any="legacy packet" }, open, "helios.v1"),
    "protection disabled must preserve legacy compatibility")
assert(security.validKey(security.generateKey()), "generated pairing keys must be valid")
print("network security tests passed")
