local realPrint, realWrite = print, write
local width, cursorX, cursorY = 51, 1, 1
local rows = {}

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
    cursorX, cursorY = 1, cursorY + 1
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
        return width, 19
    end,
}

local ui = dofile("src/core/ui.lua")
ui.setVersion("1.4.0-alpha.14")
ui.header("mainframe", "Central control authority")

assert(rows[1]:sub(1, 19) == "HELIOS // MAINFRAME",
    "header role is not left aligned")
assert(rows[1]:sub(width - #"v1.4.0-alpha.14" + 1) == "v1.4.0-alpha.14",
    "installed version is not right aligned")

print, write = realPrint, realWrite
print("ui tests passed")
