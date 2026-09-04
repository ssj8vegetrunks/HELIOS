local gui = {}

local function textLength(value)
    local _, count = tostring(value or ""):gsub("[^\128-\191]", "")
    return count
end

local function textSlice(value, limit)
    local text, count, finish = tostring(value or ""), 0, 0
    for index = 1, #text do
        local byte = text:byte(index)
        if byte < 128 or byte >= 192 then
            count = count + 1
            if count > limit then break end
        end
        finish = index
    end
    return text:sub(1, finish)
end

gui.length = textLength

local function clamp(value, low, high)
    value = tonumber(value) or 0
    return math.max(low, math.min(high, value))
end

function gui.prepare()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
end

function gui.text(x, y, value, foreground, background, width)
    local screenWidth, screenHeight = term.getSize()
    if y < 1 or y > screenHeight or x > screenWidth then return end
    x = math.max(1, x)
    local text = tostring(value or "")
    width = math.max(0, math.min(tonumber(width) or textLength(text), screenWidth - x + 1))
    text = textSlice(text, width)
    local length = textLength(text)
    if length < width then text = text .. string.rep(" ", width - length) end
    term.setCursorPos(x, y)
    term.setBackgroundColor(background or colors.black)
    term.setTextColor(foreground or colors.white)
    term.write(text)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
end

function gui.button(x, y, label, foreground, background)
    local text = "[" .. tostring(label) .. "]"
    gui.text(x, y, text, foreground, background)
    return { x1 = x, x2 = x + textLength(text) - 1, y = y }
end

function gui.hit(button, x, y)
    return button and x and y and y == button.y and x >= button.x1 and x <= button.x2
end

function gui.progress(x, y, width, percent, foreground, background)
    width = math.max(1, math.floor(tonumber(width) or 1))
    percent = clamp(percent, 0, 100)
    local filled = math.floor(width * percent / 100 + 0.5)
    gui.text(x, y, string.rep(" ", filled), colors.white, foreground or colors.lime)
    gui.text(x + filled, y, string.rep(" ", width - filled), colors.white,
        background or colors.gray)
    return filled
end

function gui.rpmGauge(x, y, width, rpm)
    width = math.max(10, math.floor(tonumber(width) or 10))
    local zones = {
        { limit = 800, colour = colors.orange },
        { limit = 1000, colour = colors.lime },
        { limit = 1700, colour = colors.orange },
        { limit = 1900, colour = colors.lime },
        { limit = 2100, colour = colors.red },
    }
    local previous, used = 0, 0
    for index, zone in ipairs(zones) do
        local segment
        if index == #zones then
            segment = width - used
        else
            segment = math.max(1, math.floor(width * (zone.limit - previous) / 2100))
        end
        gui.text(x + used, y, string.rep(" ", segment), colors.white, zone.colour)
        used = used + segment
        previous = zone.limit
    end
    local marker = math.floor(clamp(rpm, 0, 2100) / 2100 * (width - 1))
    gui.text(x + marker, y, "^", colors.white, colors.black)
    return marker
end

return gui
