local realPrint, realWrite = print, write
local width, height, cursorX, cursorY = 51, 19, 1, 1
local rows = {}
local scrollCount = 0

colors = {
    black = 1,
    white = 2,
    yellow = 3,
    lightGray = 4,
    gray = 5,
    red = 6,
    cyan = 7,
}

local function put(text)
    text = tostring(text or "")
    rows[cursorY] = rows[cursorY] or string.rep(" ", width)
    local row = rows[cursorY]
    rows[cursorY] = row:sub(1, cursorX - 1) .. text ..
        row:sub(cursorX + #text)
    cursorX = cursorX + #text
end

write = put
print = function(text)
    put(text)
    cursorX = 1
    if cursorY >= height then
        scrollCount = scrollCount + 1
        for row = 1, height - 1 do rows[row] = rows[row + 1] end
        rows[height] = nil
        cursorY = height
    else
        cursorY = cursorY + 1
    end
end

term = {
    setBackgroundColor = function() end,
    setTextColor = function() end,
    clear = function()
        rows = {}
    end,
    setCursorPos = function(x, y)
        cursorX, cursorY = x, y
    end,
    getCursorPos = function()
        return cursorX, cursorY
    end,
    getSize = function()
        return width, height
    end,
}

local ui = dofile("src/core/ui.lua")
ui.setVersion("1.4.0-alpha.15")
ui.header("mainframe", "Central control authority")

assert(rows[1]:sub(1, 19) == "HELIOS // MAINFRAME",
    "header role is not left aligned")
assert(rows[1]:sub(width - #"v1.4.0-alpha.15" + 1) == "v1.4.0-alpha.15",
    "installed version is not right aligned")

rows, cursorX, cursorY, scrollCount = {}, 1, 5, 0
ui.status("Control", string.rep("LONG STATUS ", 10), colors.red)
assert(cursorY == 6, "long status must occupy exactly one display row")
assert(#rows[5] == width, "long status must be clipped to display width")
ui.line("!! " .. string.rep("LONG ALARM ", 10), colors.red)
assert(cursorY == 7, "long alarm must occupy exactly one display row")
assert(scrollCount == 0, "clipped UI lines must not scroll the display")

rows, cursorX, cursorY, scrollCount = {}, 1, 12, 0
local alarmText = "!! BigReactors-Turbine_0 CALIBRATION FAILED: " ..
    "Cannot maintain calibration steam: 1799 of 2000 mB/t"
ui.block(alarmText, colors.red, 3)
local silenceRow = cursorY
ui.line("[ SILENCE ALARM ]", colors.white)
term.setCursorPos(1, height - 2)
local reactorButton = ui.inlineButton("REACTORS", colors.cyan)
print("")
ui.inlineButton("CONTROL", colors.cyan)
term.setCursorPos(1, height)
write("Keyboard: V/G/E/C/R/S | Q exit")
assert((rows[12] .. rows[13]):sub(1, #alarmText) == alarmText,
    "complete two-line alarm must remain visible")
assert(silenceRow == 14, "alarm block must report its fixed row count")
assert(scrollCount == 0, "fixed dashboard footer must never scroll")
assert(ui.hit(reactorButton, reactorButton.x1, height - 2),
    "fixed dashboard footer must retain its touch target")

-- The calibration page deliberately uses two compact action rows. Advancing
-- beyond row 19 would scroll the visible buttons away from these hitboxes.
rows, cursorX, cursorY, scrollCount = {}, 1, 16, 0
local deleteButton = ui.inlineButton("DELETE CALIBRATION DATA", colors.red)
write(" ")
local recalibrateButton = ui.inlineButton("RECALIBRATE", colors.yellow)
print("")
local saveButton = ui.inlineButton("SAVE CURRENT REACTOR SETUP", colors.cyan)
write(" ")
local closeButton = ui.inlineButton("CLOSE", colors.cyan)

assert(scrollCount == 0, "calibration action rows must not scroll the display")
assert(deleteButton.y == 16 and recalibrateButton.y == 16,
    "first calibration action row has incorrect hitboxes")
assert(saveButton.y == 17 and closeButton.y == 17,
    "second calibration action row has incorrect hitboxes")
assert(ui.hit(closeButton, closeButton.x1, 17),
    "visible close action does not match its touch target")

print, write = realPrint, realWrite
print("ui tests passed")
