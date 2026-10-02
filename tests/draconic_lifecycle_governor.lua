HELIOS_GUARDIAN_TEST = true
fs = { exists = function() return false end }

local governor = assert(dofile("draconic_guardian.lua"))
local missingGateOk, missingGateReason = governor.gate(nil, 1900000)
assert(missingGateOk == false and missingGateReason == "flow gate unavailable",
    "detaching a flow gate must pause control instead of crashing Guardian")
local missingRead, missingReadReason = governor.read({ reactor = "reactor" })
assert(missingRead == nil and missingReadReason == "required reactor or flow gate is unavailable",
    "incomplete hardware bindings must be treated as recoverable telemetry loss")
local replacementGate = {}
assert(governor.adoptInjectorBaseline({ reactor={status="cold"}, inputSet=0, inputFlow=0 }, replacementGate)==1900000,
    "a cold reactor must let Guardian seed a factory-new injector gate")
local unsafeReplacement = {}
assert(governor.adoptInjectorBaseline({ reactor={status="running"}, inputSet=0, inputFlow=0 }, unsafeReplacement)==nil,
    "Guardian must not invent an injector baseline for a live reactor")
assert(governor.chargeableStatus("cold") and governor.chargeableStatus("offline"),
    "both Draconic stopped-state names must enter the charging sequence")
assert(not governor.chargeableStatus("cooling"),
    "a cooling reactor must finish stopping before it is charged")
assert(governor.requiresContainment("beyond_hope") and governor.requiresContainment("explosion_imminent"),
    "terminal reactor states must retain maximum injector support")
assert(not governor.requiresContainment("cold"),
    "a fully cold reactor no longer requires containment input")
local assisted = { injectorBaseline=1900000 }
governor.enterAssisted(assisted, {
    reactor={status="running"}, inputSet=1900000, outputSet=3900000,
})
assert(assisted.mode=="ASSISTED" and assisted.request=="MANUAL" and
    assisted.manualField==1900000 and assisted.manualExport==3900000,
    "entering assisted manual on a live reactor must adopt its gates without shutdown")
assisted = { injectorBaseline=1900000 }
governor.enterAssisted(assisted, { reactor={status="cold"}, inputSet=1900000, outputSet=0 })
assert(assisted.request=="OFF",
    "entering assisted manual must not start an inactive reactor")
local manualEfficiency = { mode="UNRESTRICTED", manualField=1900000, manualExport=3900000 }
local enabled = governor.setManualEfficiency(manualEfficiency, { inputSet=2000000, outputSet=3900000 }, true)
assert(enabled and manualEfficiency.manualEfficiencyEnabled and manualEfficiency.request=="MANUAL",
    "the manual efficiency Guardian must start from the live manual gate pair")
assert(manualEfficiency.overdriveField==1900000 and manualEfficiency.overdriveExport==3900000,
    "enabling the manual efficiency Guardian must seed its Overdrive recovery preset")
local lowManual = { mode="UNRESTRICTED", manualField=9900, manualExport=5050000 }
governor.setManualEfficiency(lowManual, {
    inputSet=1900000,inputFlow=9900,outputSet=5050000,outputFlow=5050000,
    reactor={status="running",sampleTime=0},
}, true)
assert(lowManual.efficiencyFieldCommand==9900,
    "enabling manual efficiency must not replace a low manual injector command with the stale 1.9M fallback")
local staleExport = { mode="UNRESTRICTED", manualField=1800000, manualExport=8000000 }
governor.setManualEfficiency(staleExport, {
    inputSet=1900000,inputFlow=1800000,outputSet=0,outputFlow=8000000,
    reactor={status="running",sampleTime=0},
}, true)
local _,staleTarget,_,staleReasons = governor.manualEfficiencyTargets(staleExport, {
    reactor={status="running",fieldStrength=70,maxFieldStrength=100,temperature=5400,
        energySaturation=50,maxEnergySaturation=100,generationRate=8000000,sampleTime=0},
    inputSet=1900000,inputFlow=1800000,outputSet=0,outputFlow=8000000,
})
assert(staleTarget==8000000 and #staleReasons==0,
    "delivery checks must trust Guardian's 8M command when the gate API reports a stale zero fallback")
local fieldTarget,outputTarget,status = governor.manualEfficiencyTargets(manualEfficiency, {
    reactor={status="running",fieldStrength=80,maxFieldStrength=100,temperature=4000,
        energySaturation=70,maxEnergySaturation=100,generationRate=3900000,sampleTime=0},
    inputSet=2000000,inputFlow=2000000,outputSet=3900000,outputFlow=3900000,
})
assert(fieldTarget==1900000 and outputTarget==3900000 and status:find("next increase",1,true),
    "healthy rules must begin a dwell interval without immediately changing gates")
fieldTarget,outputTarget,status = governor.manualEfficiencyTargets(manualEfficiency, {
    reactor={status="running",fieldStrength=80,maxFieldStrength=100,temperature=4000,
        energySaturation=70,maxEnergySaturation=100,generationRate=3900000,sampleTime=30},
    inputSet=2000000,inputFlow=2000000,outputSet=3900000,outputFlow=3900000,
})
assert(outputTarget==3939000 and status:find("INCREASED",1,true),
    "a full healthy interval must increase output by the configured percentage without a ceiling")
fieldTarget,outputTarget,status = governor.manualEfficiencyTargets(manualEfficiency, {
    reactor={status="running",fieldStrength=80,maxFieldStrength=100,temperature=4000,
        energySaturation=70,maxEnergySaturation=100,generationRate=3939000,sampleTime=31},
    inputSet=1900000,inputFlow=1900000,outputSet=0,outputFlow=3939000,
})
assert(manualEfficiency.overdriveExport==3900000 and manualEfficiency.efficiencyLastStep==39000 and
    status:find("THERMAL SOAK",1,true),
    "electrical confirmation must begin a thermal soak before advancing the Overdrive preset")
fieldTarget,outputTarget,status = governor.manualEfficiencyTargets(manualEfficiency, {
    reactor={status="running",fieldStrength=79,maxFieldStrength=100,temperature=4000,
        energySaturation=70,maxEnergySaturation=100,generationRate=3939000,sampleTime=32},
    inputSet=1900000,inputFlow=1900000,outputSet=0,outputFlow=3939000,
})
assert(outputTarget==3939000 and status:find("SUPPORTING FIELD",1,true),
    "a later injector-related field dip must hold, but must not undo a confirmed export point")
assert(fieldTarget==1950000 and manualEfficiency.overdriveField==1950000,
    "a falling field immediately after an export increase must add one injector step and save the supported recovery point")
fieldTarget,outputTarget,status = governor.manualEfficiencyTargets(manualEfficiency, {
    reactor={status="running",fieldStrength=79,maxFieldStrength=100,temperature=4000,
        energySaturation=70,maxEnergySaturation=100,generationRate=3939000,sampleTime=121},
    inputSet=1950000,inputFlow=1950000,outputSet=0,outputFlow=3939000,
})
assert(manualEfficiency.overdriveExport==3939000 and manualEfficiency.efficiencyLastStep==0,
    "a completed thermal soak must save the proven output and clear its rollback step")
governor.setManualEfficiency(manualEfficiency, { inputSet=2100000, outputSet=4200000 }, false)
assert(not manualEfficiency.manualEfficiencyEnabled and manualEfficiency.request=="MANUAL" and
    manualEfficiency.manualField==1950000 and manualEfficiency.manualExport==3939000,
    "disabling the governor must freeze the current live gates without a jump")
local tolerantCandidate = {mode="UNRESTRICTED",manualField=1900000,manualExport=3900000,
    manualEfficiencyEnabled=true,efficiencyFieldCommand=1900000,efficiencyOutputCommand=4000000,
    efficiencyTempLimit=8000,efficiencyThermalCandidateOutput=4000000,efficiencyThermalSoakUntil=10,
    efficiencyLastStep=100000,overdriveField=1900000,overdriveExport=3900000}
local _,tolerantOutput,tolerantStatus = governor.manualEfficiencyTargets(tolerantCandidate, {
    reactor={status="running",fieldStrength=70,maxFieldStrength=100,temperature=8080,
        energySaturation=60,maxEnergySaturation=100,generationRate=4000000,sampleTime=10},
    inputSet=1900000,inputFlow=1900000,outputSet=0,outputFlow=4000000,
})
assert(tolerantOutput==4000000 and tolerantCandidate.overdriveExport==4000000 and
    tolerantStatus:find("above probe threshold",1,true),
    "a candidate inside the 2% thermal tolerance may be accepted but must remain probe-locked above the nominal limit")
_,tolerantOutput,tolerantStatus = governor.manualEfficiencyTargets(tolerantCandidate, {
    reactor={status="running",fieldStrength=70,maxFieldStrength=100,temperature=8080,
        energySaturation=60,maxEnergySaturation=100,generationRate=4000000,sampleTime=40},
    inputSet=1900000,inputFlow=1900000,outputSet=0,outputFlow=4000000,
})
assert(tolerantOutput==4000000 and tolerantCandidate.efficiencyPendingExport==nil,
    "temperature above the nominal threshold must prevent further probes even inside tolerance")
local thermalProbe = { mode="UNRESTRICTED",manualField=1900000,manualExport=3900000 }
governor.setManualEfficiency(thermalProbe, {inputSet=1900000,outputSet=3900000,
    reactor={status="running",sampleTime=0}}, true)
for strike=1,3 do
    thermalProbe.efficiencyOutputCommand=4000000;thermalProbe.efficiencyThermalCandidateOutput=4000000
    thermalProbe.efficiencyThermalSoakUntil=100;thermalProbe.efficiencyLastStep=100000
    local _,held,thermalStatus = governor.manualEfficiencyTargets(thermalProbe, {
        reactor={status="running",fieldStrength=70,maxFieldStrength=100,temperature=8001,
            energySaturation=60,maxEnergySaturation=100,generationRate=4000000,sampleTime=strike},
        inputSet=1900000,inputFlow=1900000,outputSet=0,outputFlow=4000000,
    })
    assert(held==3900000 and thermalProbe.efficiencyThermalStrikes==strike,
        "each overheated probe must restore the verified Overdrive point and record a strike")
    if strike==3 then assert(thermalStatus:find("15m",1,true) and thermalProbe.efficiencyCooldownUntil==903,
        "three thermal rejections must begin a fifteen-minute cooldown") end
end
local _,cooldownOutput,cooldownStatus = governor.manualEfficiencyTargets(thermalProbe, {
    reactor={status="running",fieldStrength=70,maxFieldStrength=100,temperature=7000,
        energySaturation=60,maxEnergySaturation=100,generationRate=3900000,sampleTime=4},
    inputSet=1900000,inputFlow=1900000,outputSet=0,outputFlow=3900000,
})
assert(cooldownOutput==3900000 and cooldownStatus:find("retry in",1,true),
    "thermal cooldown must hold the last verified output instead of probing every interval")
local transient = {};transient.self=transient
local checkpoint = governor.persistentState({
    mode="UNRESTRICTED",manualField=9900,efficiencyFieldTarget=10,
    manualEfficiencyEnabled=true,efficiencyOutputCommand=13420000,efficiencyFieldCommand=1320000,
    efficiencyThermalCandidateOutput=13420000,efficiencyThermalSoakUntil=500,
    efficiencyThermalStrikes=2,efficiencyCooldownUntil=1200,
    transientRuntime=transient,efficiencyPendingTelemetry=transient,
})
assert(checkpoint.mode=="UNRESTRICTED" and checkpoint.manualField==9900 and checkpoint.efficiencyFieldTarget==10,
    "durable manual-efficiency settings must survive a checkpoint")
assert(checkpoint.manualEfficiencyEnabled==true and checkpoint.efficiencyOutputCommand==13420000 and
    checkpoint.efficiencyFieldCommand==1320000,
    "enabled governor and its live ramp commands must survive a controller restart")
assert(checkpoint.efficiencyThermalCandidateOutput==13420000 and checkpoint.efficiencyThermalStrikes==2 and
    checkpoint.efficiencyCooldownUntil==1200,
    "thermal candidates, strikes, and cooldowns must survive a controller restart")
assert(checkpoint.transientRuntime==nil and checkpoint.efficiencyPendingTelemetry==nil,
    "checkpoint serialization must exclude cyclic or growing transient controller state")
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
local maintenance = { request="REMOTE", commissioned=true, rated=9000000,
    remoteLevel="MAX", remoteTarget=9000000, initialRequested=true }
governor.beginRefuelMaintenance(maintenance, true)
assert(maintenance.refuelMaintenance and maintenance.refuelPhase=="shutdown" and maintenance.request=="OFF",
    "automatic refuel maintenance must latch and cancel generation demand")
assert(maintenance.remoteLevel==nil and not maintenance.initialRequested,
    "maintenance lock must clear stale Mainframe and restart intent")
governor.resetAfterRefuel(maintenance)
assert(not maintenance.refuelMaintenance and not maintenance.commissioned and maintenance.rated==nil,
    "confirmed refueling must clear the learned reactor profile")
assert(maintenance.injectorBaseline==1900000 and maintenance.mode=="AUTO" and maintenance.request=="OFF",
    "a fresh fuel cycle must return to the conservative uncommissioned baseline")
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

-- A healthy point becomes proven only after the full observation window.
controls = { rated = 1000000, injectorBaseline = 1600000, lifecycleCeilings = {},
    currentCycleCeilings = {}, lifecycleBandKey = "10", lifecycleNextProbeAt = 0 }
for second = 1, 119 do
    target = governor.lifecycleTarget(controls, reactor(10, 70, 1050000, nil, second))
end
assert(target == 1050000 and controls.lifecycleSamples == 119,
    "adaptive proof must collect no faster than one sample per second")
target = governor.lifecycleTarget(controls, reactor(10, 70, 1050000, nil, 120))
assert(target == 1050000, "120 stable seconds must prove the adaptive trial")
assert(controls.currentCycleCeilings["10"] == 1050000,
    "stable trial must be recorded for this fuel band")
target = governor.lifecycleTarget(controls, reactor(10, 70, 1050000, nil, 121))
assert(target == 1050000, "a new adaptive trial must not begin immediately")
target = governor.lifecycleTarget(controls, reactor(10, 70, 1100000, nil, 1020))
assert(target > 1050000, "the next adaptive trial may begin after fifteen minutes")

-- The lifecycle governor may use the 7,500-7,750 C efficiency band only when
-- containment is at least 40%; 7,750 C remains an unconditional ceiling.
controls = { rated = 1000000, lifecycleCeilings = { ["10"]={export=1050000} }, currentCycleCeilings = {}, lifecycleApplied = 1050000 }
target = governor.lifecycleTarget(controls, reactor(10, 39, 1050000, 7600))
assert(target == 1000000, "hot probing below 40% containment must roll back")
controls = { rated = 1000000, lifecycleCeilings = { ["10"]={export=1050000} }, currentCycleCeilings = {}, lifecycleApplied = 1050000 }
target = governor.lifecycleTarget(controls, reactor(10, 40, 1050000, 7600))
assert(target == 1050000, "40% containment may use the conditional temperature leeway")
controls = { rated = 1000000, lifecycleCeilings = { ["10"]={export=1050000} }, currentCycleCeilings = {}, lifecycleApplied = 1050000 }
target = governor.lifecycleTarget(controls, reactor(10, 60, 1050000, 7751))
assert(target == 1000000, "adaptive probing must always roll back above 7,750 C")

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
assert(recovery == 2850000,
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

-- Automatic supervision requires three independently persisted danger votes.
-- One bad reading must not stop a reactor, while a sustained power-collapse
-- pattern must be classified with enough telemetry to explain the shutdown.
local safetyTrend = {}
local votes, voteCount
for sample = 1, 13 do
    votes, voteCount = governor.updateAutomaticSafetyVotes({
        reactor = {
            status="running", fieldStrength=70-sample, maxFieldStrength=100,
            energySaturation=70-sample, maxEnergySaturation=100,
            temperature=4000, generationRate=1000000, fieldDrainRate=2000000,
        },
        inputFlow=1000000, inputSet=1900000,
        outputFlow=2000000, outputSet=2800000,
    }, safetyTrend)
end
assert(voteCount >= 3, "sustained power loss must produce a three-vote shutdown quorum")
local labels = table.concat(votes, ",")
assert(labels:find("field falling",1,true) and labels:find("injector shortfall",1,true) and
    labels:find("field power deficit",1,true),
    "shutdown votes must identify the field trend and its power-delivery deficits")
safetyTrend = {}
votes, voteCount = governor.updateAutomaticSafetyVotes({
    reactor = {
        status="running", fieldStrength=69, maxFieldStrength=100,
        energySaturation=69, maxEnergySaturation=100,
        temperature=4000, generationRate=1000000, fieldDrainRate=2000000,
    }, inputFlow=1000000, inputSet=1900000, outputFlow=2000000, outputSet=2800000,
}, safetyTrend)
assert(voteCount==0, "a single anomalous sample must not cast persisted danger votes")
safetyTrend = {}
for sample = 1, 8 do
    votes, voteCount = governor.updateAutomaticSafetyVotes({
        reactor = {
            status="running", fieldStrength=70, maxFieldStrength=100,
            energySaturation=70, maxEnergySaturation=100,
            temperature=4000, generationRate=6000000, fieldDrainRate=500000,
        }, inputFlow=1900000, inputSet=1900000, outputFlow=5680000, outputSet=0,
    }, safetyTrend)
end
assert(table.concat(votes, ","):find("export gate failed closed",1,true),
    "continued export after a zero command must become an explicit safety vote")
safetyTrend = {}
for sample = 1, 13 do
    votes, voteCount = governor.updateAutomaticSafetyVotes({
        reactor = {
            status="running", fieldStrength=70, maxFieldStrength=100,
            energySaturation=70-sample, maxEnergySaturation=100,
            temperature=4000, generationRate=1000000, fieldDrainRate=500000,
        }, inputFlow=1900000, inputSet=1900000, outputFlow=1000000, outputSet=2000000,
    }, safetyTrend, true)
end
assert(voteCount==1 and votes[1]=="saturation falling",
    "normal commissioning ramp lag must not manufacture generation and export mismatch votes")

print("draconic lifecycle governor tests passed")
