local width, height = 57, 38
colors = { black=1, white=2, gray=3, lightGray=4, lime=5, orange=6,
    red=7, cyan=8, yellow=9 }
keys = { a = 1 }
term = { getSize = function() return width, height end }
local drawn = {}
local gui = {
    prepare = function() drawn = {} end,
    text = function(x, y, value) drawn[#drawn + 1] = tostring(value) end,
    progress = function() end,
    button = function(x, y, label) return {x1=x,x2=x+#label+1,y=y} end,
}
local formatter = {
    power = function(value, _, perTick) return tostring(math.floor(value or 0)) .. (perTick and " FE/t" or " FE") end,
}
local renderer = dofile("src/gui/control-room/renderer.lua")
local state = {}
local buttons = renderer.render({
    version="1.6.0-alpha.4", aliases={}, power={unit="FE"},
    control={reactorProfiles={R0={learnedMaximumSteam=5000}}},
    reactors={{name="R0",mode="steam",steamProduction=1000,energyProduction=0,active=true,
        governor={state="STABLE",reason="Steam target held"}}},
    turbines={{name="T0",flowRate=900,energyProduction=500,active=true,
        governor={state="HOLDING",reason="Holding 1800 RPM"}}},
    storages={{stored=5000,capacity=10000,input=600,output=400,percent=50}},
}, state, {gui=gui,powerFormat=formatter})
assert(buttons.advanced and state.page == "home", "control room must render navigation")
local output = table.concat(drawn, "\n")
assert(string.find(output, "POWER STORAGE", 1, true), "home must show combined storage")
assert(string.find(output, "STEAM PRODUCTION", 1, true), "home must show aggregate steam")
assert(string.find(output, "POWER PRODUCTION", 1, true), "home must show aggregate power")
assert(string.find(output, "HELIOS ACTIVITY", 1, true), "home must explain governor activity")
assert(string.find(output, "1000 / 5000 mB/t", 1, true),
    "steam instrument must show actual output against learned maximum")
print("control room GUI tests passed")
