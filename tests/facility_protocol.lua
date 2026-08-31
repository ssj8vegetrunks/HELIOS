local protocol = dofile("src/core/facility_protocol.lua")

local guardian = assert(protocol.identity({
    computerId = 25,
    nodeId = "guardian:draconic-1",
    sessionId = "guardian-session-1",
    role = "guardian",
    software = "draconic_guardian",
    softwareVersion = "0.1.0-alpha.1",
}))

local mainframe = assert(protocol.identity({
    computerId = 1,
    nodeId = "mainframe:1",
    sessionId = "mainframe-session-1",
    role = "mainframe",
    software = "helios",
    softwareVersion = "1.6.0-alpha.4",
}))

local hello = assert(protocol.make("hello", guardian, 1, {
    facilityType = "draconic_reactor",
    capabilities = { "telemetry", "local_guardian", "ui_profile" },
    ui = { profile = "draconic", version = 1, format = "helios.ui" },
}, 1000))

local collector = assert(protocol.make("collector_presence", mainframe, 1, {
    siteId = "default",
    collectorPriority = 50,
    leaseSeconds = 5,
}, 1000))
assert(protocol.validate(collector, "collector_presence"),
    "collector-presence envelopes must validate")

assert(hello.messageId == "guardian-session-1:1", "message IDs must be deterministic")
local validated = assert(protocol.validate(hello, "hello"))
assert(validated.source.computerId == 25 and validated.payload.facilityType == "draconic_reactor",
    "valid registration must survive normalization")

local tracker = protocol.newSequenceTracker()
assert(protocol.acceptSequence(tracker, hello) == true, "first sequence must be accepted")
local accepted, reason = protocol.acceptSequence(tracker, hello)
assert(accepted == false and reason == "duplicate", "duplicate sequence must be rejected")

local older = assert(protocol.make("heartbeat", guardian, 0, {}, 1001))
accepted, reason = protocol.acceptSequence(tracker, older)
assert(accepted == false and reason == "stale", "older sequence must be rejected")

local ack = assert(protocol.acknowledge(hello, mainframe, 1, "accepted", "registered", 1001))
assert(ack.kind == "acknowledgement" and ack.payload.messageId == hello.messageId,
    "acknowledgements must reference the original message")

local unsafe, unsafeReason = protocol.make("telemetry", guardian, 2, {
    reactor = function() error("hardware handles must not cross the network") end,
}, 1002)
assert(unsafe and unsafe.payload.reactor == nil and unsafeReason == nil,
    "non-serializable payload members must be removed")

local command, commandReason = protocol.make("command", mainframe, 2, {}, 1002)
assert(command == nil and commandReason, "facility v1 must expose no remote command kind")

local flood = {}
for index = 1, 513 do flood[index] = index end
local flooded, floodReason = protocol.make("telemetry", guardian, 2, flood, 1002)
assert(flooded == nil and string.find(floodReason, "512", 1, true),
    "oversized payloads must be rejected instead of truncated")

local cyclic = {}
cyclic.self = cyclic
local cycled, cycleReason = protocol.make("telemetry", guardian, 2, cyclic, 1002)
assert(cycled == nil and string.find(cycleReason, "cycle", 1, true),
    "cyclic payloads must be rejected")

local forged = assert(protocol.make("heartbeat", guardian, 3, {}, 1003))
forged.messageId = "forged"
assert(protocol.validate(forged) == nil, "forged message IDs must be rejected")

local description = protocol.describe()
assert(description.remoteCommands == false and description.rednetProtocol == "helios.facility.v1",
    "contract must advertise a read-only first release")

print("facility protocol tests passed")
