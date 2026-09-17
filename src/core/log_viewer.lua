local viewer = {}

function viewer.run(config, wantedSeverity, wantedSubsystem)
    local log = dofile("/helios/core/event_log.lua")
    local i18n = dofile("/helios/core/i18n.lua").new(config)
    local function translatedValues(record)
        local values = {}
        for key, value in pairs(record.values or {}) do values[key] = value end
        for key, value in pairs(record.values or {}) do
            local target = key:match("^(.-)_key$")
            if target then values[target] = i18n.get(value, nil, value) end
        end
        return values
    end
    local function tag(prefix, value)
        return i18n.get(prefix .. tostring(value):lower(), nil, tostring(value))
    end
    local function waitForAction(prompt, label)
        print(prompt)
        local x, y = term.getCursorPos()
        local text = "[" .. label .. "]"
        term.setTextColor(colors.cyan);write(text);term.setTextColor(colors.white)
        while true do
            local event, a, b, c = os.pullEvent()
            if event == "key" and (a == keys.enter or a == keys.numPadEnter) then return end
            if event == "monitor_touch" or event == "mouse_click" then
                local touchX, touchY = b, c
                if touchY == y and touchX >= x and touchX < x + #text then return end
            end
        end
    end
    local function choose(title, entries)
        if #entries == 0 then
            term.clear();term.setCursorPos(1, 1);print(title);print("")
            print(i18n.get("log.no_entries", nil, "No entries."));print("")
            waitForAction(i18n.get("log.press_return", nil, "Press ENTER to return."), "BACK")
            return nil
        end
        local width, height = term.getSize()
        local pageSize, page, typed = math.max(3, height - 7), 1, ""
        local pageCount = math.max(1, math.ceil(#entries / pageSize))
        while true do
            term.clear();term.setCursorPos(1, 1);print(title);print("")
            local first, last = (page - 1) * pageSize + 1, math.min(#entries, page * pageSize)
            for index = first, last do print((("[%d] %s"):format(index, entries[index])):sub(1, width)) end
            term.setCursorPos(1, height - 2)
            term.clearLine();write(i18n.get("log.page", {page=page,total=pageCount}, "PAGE {page}/{total}"))
            term.setCursorPos(1, height - 1);term.clearLine()
            term.setTextColor(colors.cyan);write("[< PREVIOUS] [NEXT >] [BACK]");term.setTextColor(colors.white)
            term.setCursorPos(1, height);term.clearLine()
            write(i18n.get("log.select", nil, "Select number: ") .. typed)
            local event, a, b, c = os.pullEvent()
            if event == "char" then
                if a:match("%d") then typed = (typed .. a):sub(1, 6)
                elseif a:lower() == "n" then page = math.min(pageCount, page + 1);typed = ""
                elseif a:lower() == "p" then page = math.max(1, page - 1);typed = "" end
            elseif event == "key" then
                if a == keys.enter or a == keys.numPadEnter then
                    if typed == "" then return nil end
                    local selected = tonumber(typed)
                    if selected and entries[selected] then return selected end
                    typed = ""
                elseif a == keys.backspace then typed = typed:sub(1, -2) end
            elseif event == "monitor_touch" or event == "mouse_click" then
                local touchX, touchY = b, c
                if touchY >= 3 and touchY <= 2 + (last - first + 1) then
                    return first + touchY - 3
                elseif touchY == height - 1 then
                    if touchX <= 12 then page = math.max(1, page - 1)
                    elseif touchX <= 21 then page = math.min(pageCount, page + 1)
                    elseif touchX <= 28 then return nil end
                    typed = ""
                end
            end
        end
    end
    local days = log.days()
    local dayIndex = choose(i18n.get("log.days", nil, "CAPTAIN'S LOG // DAYS"), days)
    if not dayIndex then return end
    local day = days[dayIndex]
    local hours = log.hours(day)
    local hourIndex = choose(i18n.get("log.hours", {day=day}, "CAPTAIN'S LOG // {day} // HOURS"), hours)
    if not hourIndex then return end
    local hour = hours[hourIndex]
    local records = log.events(day, hour)
    wantedSeverity = wantedSeverity and tostring(wantedSeverity):lower() or nil
    wantedSubsystem = wantedSubsystem and tostring(wantedSubsystem):lower() or nil
    if wantedSeverity or wantedSubsystem then
        local filtered = {}
        for _, record in ipairs(records) do
            if (not wantedSeverity or record.severity == wantedSeverity) and
               (not wantedSubsystem or record.subsystem == wantedSubsystem) then filtered[#filtered + 1] = record end
        end
        records = filtered
    end
    local labels = {}
    for index, record in ipairs(records) do
        labels[index] = ("[%s] [%s] %s"):format(string.upper(tag("value.", record.severity)),
            tag("log.subsystem_", record.subsystem),
            i18n.get(record.key, translatedValues(record), record.key))
    end
    local selected = choose(i18n.get("log.events", {day=day,hour=hour}, "CAPTAIN'S LOG // {day} // {hour}"), labels)
    if not selected then return end
    local record = records[selected]
    term.clear();term.setCursorPos(1, 1)
    print(i18n.get(record.key, translatedValues(record), record.key));print("")
    print(i18n.get("log.severity", nil, "Severity") .. ": " .. string.upper(tag("value.", record.severity)))
    print(i18n.get("log.subsystem", nil, "Subsystem") .. ": " .. tag("log.subsystem_", record.subsystem))
    print(i18n.get("log.event", nil, "Event") .. ": " .. record.id)
    print("")
    waitForAction(i18n.get("log.open_book", nil, "Press ENTER to open the event book."), "OPEN")
    local storedPages = record.pages or {}
    if #storedPages == 0 then storedPages = { i18n.get("log.no_details", nil, "No additional details.") } end
    local width, height = term.getSize()
    local linesPerPage, displayPages = math.max(3, height - 4), {}
    for _, storedPage in ipairs(storedPages) do
        local lines = {}
        for sourceLine in (tostring(storedPage) .. "\n"):gmatch("(.-)\n") do
            if sourceLine == "" then lines[#lines + 1] = "" end
            while #sourceLine > 0 do
                lines[#lines + 1] = sourceLine:sub(1, width)
                sourceLine = sourceLine:sub(width + 1)
            end
        end
        for first = 1, math.max(1, #lines), linesPerPage do
            local page = {}
            for line = first, math.min(#lines, first + linesPerPage - 1) do page[#page + 1] = lines[line] end
            displayPages[#displayPages + 1] = page
        end
    end
    for index, page in ipairs(displayPages) do
        term.clear();term.setCursorPos(1, 1)
        print(i18n.get("log.page", {page=index,total=#displayPages}, "PAGE {page}/{total}"));print("")
        for _, line in ipairs(page) do print(line) end
        if index < #displayPages then
            print("")
            waitForAction(i18n.get("log.next_page", nil, "Press ENTER for the next page."), "NEXT")
        end
    end
    print("")
    waitForAction(i18n.get("log.close_book", nil, "Press ENTER to close the book."), "CLOSE")
end

return viewer
