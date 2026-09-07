HELIOS_GUARDIAN_TEST = true
fs = { exists = function() return false end }

local governor = assert(dofile("draconic_guardian.lua"))
local function reactor(conversion, field, generation, temperature)
    return {
        fuelConversion = conversion, maxFuelConversion = 100,
        fieldStrength = field, maxFieldStrength = 100,
        generationRate = generation, temperature = temperature or 3000,
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

-- A healthy point becomes proven only after the full observation window.
controls = { rated = 1000000, injectorBaseline = 1600000, lifecycleCeilings = {}, currentCycleCeilings = {} }
for _ = 1, 149 do target = governor.lifecycleTarget(controls, reactor(10, 70, 1000000)) end
assert(target == 1000000, "unproven output must remain at the current point")
target = governor.lifecycleTarget(controls, reactor(10, 70, 1000000))
assert(target == 1050000, "stable output must advance by the conservative minimum step")
assert(controls.currentCycleCeilings["10"] == 1000000, "stable point must be recorded for this cycle")

-- The lifecycle governor may use the 7,500-7,750 C efficiency band only when
-- containment is at least 40%; 7,750 C remains an unconditional ceiling.
controls = { rated = 1000000, lifecycleCeilings = {}, currentCycleCeilings = {}, lifecycleApplied = 1050000 }
target = governor.lifecycleTarget(controls, reactor(10, 39, 1050000, 7600))
assert(target == 1000000, "hot probing below 40% containment must roll back")
controls = { rated = 1000000, lifecycleCeilings = {}, currentCycleCeilings = {}, lifecycleApplied = 1050000 }
target = governor.lifecycleTarget(controls, reactor(10, 40, 1050000, 7600))
assert(target == 1050000, "40% containment may use the conditional temperature leeway")
controls = { rated = 1000000, lifecycleCeilings = {}, currentCycleCeilings = {}, lifecycleApplied = 1050000 }
target = governor.lifecycleTarget(controls, reactor(10, 60, 1050000, 7751))
assert(target == 1000000, "adaptive probing must always roll back above 7,750 C")

-- Sustained excess containment permits a small field-input trim.
controls.lifecycleFieldApplied = 1600000
for _ = 1, 150 do governor.lifecycleFieldTarget(controls, reactor(10, 70, 1000000), 1600000) end
assert(controls.lifecycleFieldApplied == 1568000, "stable high containment should trim field input by two percent")

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
