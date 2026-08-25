local width, height = 51, 19
local cursorX, cursorY = 1, 1
local cells = {}

colors = { black = 1, white = 2, gray = 3, lime = 4, orange = 5, red = 6 }
term = {
    setBackgroundColor = function() end,
    setTextColor = function() end,
    clear = function() cells = {} end,
    setCursorPos = function(x, y) cursorX, cursorY = x, y end,
    getSize = function() return width, height end,
    write = function(text)
        for index = 1, #text do cells[cursorY .. ":" .. (cursorX + index - 1)] = text:sub(index, index) end
        cursorX = cursorX + #text
    end,
}

local gui = dofile("src/core/gui.lua")
local button = gui.button(2, 3, "POWER", colors.white, colors.gray)
assert(gui.hit(button, 2, 3) and gui.hit(button, 8, 3), "button bounds must be touchable")
assert(not gui.hit(button, 9, 3), "button hitbox must end with visible button")
assert(gui.progress(1, 5, 10, 50, colors.lime, colors.gray) == 5,
    "progress bar must fill the requested percentage")
assert(gui.rpmGauge(1, 7, 21, 900) >= 8, "RPM marker must map into the 900 band")
assert(gui.rpmGauge(1, 8, 21, 1800) >= 16, "RPM marker must map into the 1800 band")

print("gui tests passed")
