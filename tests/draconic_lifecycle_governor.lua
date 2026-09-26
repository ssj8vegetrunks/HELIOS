HELIOS_GUARDIAN_TEST = true
fs = { exists = function() return false end }

local governor = assert(dofile("draconic_guardian.lua"))
assert(governor.chargeableStatus("cold") and governor.chargeableStatus("offline"),
    "both Draconic stopped-state names must enter the charging sequence")
assert(not governor.chargeableStatus("cooling"),
    "a cooling reactor must finish stopping before it is charged")
assert(governor.commissionFieldFloor >= 70,
    "commissioning must abort with substantial containment margin")
local bootstrap = { commissioned = true, rated = 9000000, request = "MAX" }
assert(governor.adoptInjectorBaseline({ inputSet = 0, inputFlow = 0,
    reactor = { status = "cold", fieldDrainRate = 0 } }, bootstrap) == 1900000,
    "a new cold installation must receive the conservative injector baseline")
assert(not bootstrap.commissioned and bootstrap.rated == nil and bootstrap.request == "OFF",
    "automatic injector initialization must invalidate old output authority")
local liveBootstrap = {}
assert(governor.adoptInjectorBaseline({ inputSet = 0, inputFlow = 0,
    reactor = { status = "running", fieldDrainRate = 1400000 } }, liveBootstrap) == 2800000,
    "a live recovery baseline must cover twice the measured field drain")
assert(not governor.lifecycleUnsafe(89, 7700),
    "strong containment may use the proven 7,500-7,750 C lifecycle leeway")
assert(governor.lifecycleUnsafe(39, 7700),
    "the temperature leeway must close when containment falls below 40%")
local thermal = {}
assert(governor.thermalHoldRequired(thermal, 8050),
    "crossing the thermal limit must enter a gate hold")
assert(governor.thermalHoldRequired(thermal, 7600),
    "thermal gate hold must use hysteresis instead of immediately resuming")
assert(not governor.thermalHoldRequired(thermal, 7500),
    "a cooled, contained reactor may resume without a stop/start cycle")
assert(governor.mailboxHasRemoteDemand({
    lastCommandStatus = "accepted", remoteLevel = "MAX", request = "OFF",
}), "legacy shutdown cleanup must not erase an accepted remote demand")
assert(not governor.mailboxHasRemoteDemand({
    lastCommandStatus = "accepted", request = "IDLE",
}), "an accepted idle request must remain idle")
local function reactor(conversion, field, generation, temperature, sampleTime)
    return {
        status = "running",
        fuelConversion = conversion, maxFuelConversion = 100,
        fieldStrength = field, maxFieldStrength = 100,
        generationRate = generation, temperature = temperature or 3000,
        sampleTime = sampleTime,
    }
end

-- A refuel transition must not reuse the late-cycle 9M profile.
local controls = {
    rated = 1000000, injectorBaseline = 1600000, lastFuelConversion = 82,
    lifecycleCeilings = { ["80"] = { export = 9000000, fieldInput = 1600000 } },
    currentCycleCeilings = { ["80"] = 9000000 }, lifecycleApplied = 9000000,
    lifecycleBandKey = "80",
}
local target = governor.lifecycleTarget(controls, reactor(1, 80, 1000000))
assert(target == 1000000, "fresh core must return to commissioned export")
assert(next(controls.currentCycleCeilings) == nil, "fresh core must clear current-cycle proofs")

-- Unattended adaptive ceiling experiments remain disabled until live gate
-- response can be verified independently of reactor telemetry.
controls = { rated = 1000000, injectorBaseline = 1600000, lifecycleCeilings = {},
    currentCycleCeilings = {}, lifecycleBandKey = "10", lifecycleNextProbeAt = 0 }
for second = 1, 1020 do
    target = governor.lifecycleTarget(controls, reactor(10, 70, 1050000, nil, second))
end
assert(target == 1000000 and next(controls.currentCycleCeilings) == nil,
    "unattended operation must hold the commissioned ceiling without probing")

-- The lifecycle governor may use the 7,500-7,750 C efficiency band only when
-- containment is at least 40%; 7,750 C remains an unconditional ceiling.
controls = { rated = 1000000, lifecycleCeilings = { ["10"]={export=1050000} }, currentCycleCeilings = {}, lifecycleApplied = 1050000 }
target = governor.lifecycleTarget(controls, reactor(10, 39, 1050000, 7600))
assert(target == 1000000, "hot probing below 40% containment must roll back")

-- Excess containment alone must never justify reducing injector power. A trim
-- is permitted only once generation covers containment with margin while the
-- field is full and stable.
controls.lifecycleFieldApplied = 1600000
for _ = 1, 150 do governor.lifecycleFieldTarget(controls, reactor(10, 95, 1000000), 1600000) end
assert(controls.lifecycleFieldApplied == 1600000,
    "containment must remain at its proven input until generation reaches breakeven")
for _ = 1, 150 do governor.lifecycleFieldTarget(controls, reactor(10, 95, 2000000), 1600000) end
assert(controls.lifecycleFieldApplied == 1568000,
    "stable full containment with generation surplus should trim field input by two percent")

-- Falling below the emergency band must request enough positive field flow to
-- recover online; it must not remain pinned to an insufficient calibration
-- baseline and force a stop/start cycle.
controls.lifecycleFieldApplied = 1600000
local recovery = governor.emergencyFieldTarget(controls, {
    fieldDrainRate = 1900000,
}, 1600000)
assert(recovery == 3800000,
    "emergency containment recovery must exceed measured field drain")

-- Late-cycle heat is expected and must not be mislabeled as an imminent
-- meltdown while containment remains healthy. A cascade requires both a hot,
-- rising core and a low, falling field for consecutive samples.
local trend = {}
for _, sample in ipairs({
    reactor(80, 66, 20000000, 7145),
    reactor(80, 60, 20000000, 7600),
    reactor(80, 55, 20000000, 7900),
}) do governor.updateMeltdownTrend(sample, trend) end
assert(not governor.imminentMeltdown(reactor(80, 55, 20000000, 7900), trend),
    "healthy late-cycle operation must not raise a meltdown alarm")
trend = {}
local cascade
for _, sample in ipairs({
    reactor(80, 30, 20000000, 7900),
    reactor(80, 24, 20000000, 8060),
    reactor(80, 23, 20000000, 8070),
    reactor(80, 22, 20000000, 8080),
}) do
    governor.updateMeltdownTrend(sample, trend)
    cascade = governor.imminentMeltdown(sample, trend)
end
assert(cascade, "a hot rising core with low falling containment must raise a meltdown alarm")

print("draconic lifecycle governor tests passed")
