local engine = dofile("src/draconic/profiler_engine.lua")

local function telemetry(field, temperature, export)
    return {
        state = "running",
        generationRate = export,
        temperature = temperature,
        fieldStrength = field,
        maxFieldStrength = 100,
        energySaturation = 20,
        maxEnergySaturation = 100,
        fuelConversion = 10,
        maxFuelConversion = 100,
        fieldInput = 1000000,
        fieldDrainRate = 900000,
        exportFlow = export,
    }
end

local stable = engine.new({ bracketSize = 250000 })
for second = 0, 120, 5 do engine.add(stable, telemetry(50, 5000, 6000000), second) end
local classification = engine.classify(stable, 120)
assert(classification == "STABLE", "a settled operating point should classify as stable")

local improving = engine.new({ bracketSize = 250000 })
for second = 0, 120, 5 do
    engine.add(improving, telemetry(40 + second / 60, 5000 - second, 6000000), second)
end
assert(engine.classify(improving, 120) == "IMPROVING", "a recovering field should classify as improving")

local deteriorating = engine.new({ bracketSize = 250000 })
for second = 0, 120, 5 do
    engine.add(deteriorating, telemetry(50 - second / 30, 5000 + second, 6000000), second)
end
assert(engine.classify(deteriorating, 120) == "DETERIORATING", "a falling field should classify as deteriorating")

local sample = stable.samples[#stable.samples]
local profiles = engine.updateProfile({}, stable, sample, "STABLE", 5)
local profile = profiles[tostring(sample.bracket)]
assert(profile and profile.samples == 1 and profile.stableSeconds == 5,
    "stable observations should be accumulated in their output bracket")

engine.add(stable, telemetry(50, 5000, 7000000), 125)
assert(engine.classify(stable, 125) == "SETTLING", "an output-bracket change must restart settling")

print("draconic profiler engine tests passed")
