local ui = {}
local idConflicts = {}

function ui.setIdConflicts(conflicts)
    idConflicts = {}
    if type(conflicts) == "table" then
        for _, id in ipairs(conflicts) do idConflicts[#idConflicts + 1] = tostring(id) end
    end
end

function ui.hasIdConflict()
    return #idConflicts > 0
end

function ui.button(label, colour)
    local x, y = term.getCursorPos()
    term.setTextColor(colour or colors.cyan)
    local text = "[ " .. label .. " ]"
    print(text)
    term.setTextColor(colors.white)
    return { x1 = x, x2 = x + #text - 1, y = y }
end

function ui.inlineButton(label, colour)
    local x, y = term.getCursorPos()
    term.setTextColor(colour or colors.cyan)
    local text = "[" .. label .. "]"
    write(text)
    term.setTextColor(colors.white)
    return { x1 = x, x2 = x + #text - 1, y = y }
end

function ui.hit(button, x, y)
    return button and y == button.y and x >= button.x1 and x <= button.x2
end

function ui.eventPoint(event, first, second, third)
    if event == "monitor_touch" or event == "mouse_click" then
        return second, third
    end
    return nil, nil
end

function ui.prepare()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
end

function ui.header(role, subtitle)
    ui.prepare()
    if #idConflicts > 0 then
        local width = select(1, term.getSize())
        term.setBackgroundColor(colors.red)
        term.setTextColor(colors.white)
        local warning = " ID CONFLICT: " .. table.concat(idConflicts, ", ") .. " "
        print(string.sub(warning .. string.rep(" ", width), 1, width))
        term.setBackgroundColor(colors.black)
    end
    term.setTextColor(colors.yellow)
    print("HELIOS // " .. string.upper(role))
    term.setTextColor(colors.lightGray)
    print(subtitle)
    term.setTextColor(colors.gray)
    print(string.rep("-", math.min(select(1, term.getSize()), 40)))
    term.setTextColor(colors.white)
end

function ui.status(label, value, colour)
    term.setTextColor(colors.lightGray)
    write(label .. ": ")
    term.setTextColor(colour or colors.white)
    print(tostring(value))
    term.setTextColor(colors.white)
end

function ui.waitForExit(render)
    while true do
        local event, key = os.pullEvent()
        if event == "key" and key == keys.q then
            ui.prepare()
            return
        elseif event == "term_resize" or event == "monitor_resize" or
               event == "peripheral" or event == "peripheral_detach" then
            render()
        end
    end
end

return ui
