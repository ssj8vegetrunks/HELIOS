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

-- Sustained excess containment permits a small field-input trim.
controls.lifecycleFieldApplied = 1600000
for _ = 1, 150 do governor.lifecycleFieldTarget(controls, reactor(10, 70, 1000000), 1600000) end
assert(controls.lifecycleFieldApplied == 1568000, "stable high containment should trim field input by two percent")

print("draconic lifecycle governor tests passed")
