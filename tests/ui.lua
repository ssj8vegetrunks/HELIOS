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
ui.setVersion("1.4.0-alpha.14")
ui.header("mainframe", "Central control authority")

assert(rows[1]:sub(1, 19) == "HELIOS // MAINFRAME",
    "header role is not left aligned")
assert(rows[1]:sub(width - #"v1.4.0-alpha.14" + 1) == "v1.4.0-alpha.14",
    "installed version is not right aligned")

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
