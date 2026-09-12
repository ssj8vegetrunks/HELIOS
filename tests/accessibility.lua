colors = {
    white=1, orange=2, magenta=4, lightBlue=8, yellow=16, lime=32, pink=64,
    gray=128, lightGray=256, cyan=512, purple=1024, blue=2048, brown=4096,
    green=8192, red=16384, black=32768,
}

local writes = {}
local target = {
    setPaletteColor = function(colour, rgb) writes[colour] = rgb end,
}
local accessibility = dofile("src/core/accessibility.lua")
assert(#accessibility.profiles() == 5, "all accessibility profiles must be available")
assert(accessibility.apply(target, {ui={accessibilityProfile="deuteranopia"}}),
    "a colour-capable terminal must accept the selected palette")
assert(writes[colors.red] == 0xD55E00 and writes[colors.green] == 0x0072B2,
    "deuteranopia palette must separate fault and healthy colours")
assert(accessibility.decorate("FAULT", "critical", {ui={statusSymbols=true}}) == "[X] FAULT",
    "critical status needs a redundant symbol")
assert(accessibility.decorate("READY", "healthy", {ui={statusSymbols=true}}) == "[+] READY",
    "healthy status needs a redundant symbol")
assert(accessibility.decorate("READY", "healthy", {ui={statusSymbols=false}}) == "READY",
    "symbols must remain user-configurable")
print("accessibility tests passed")
