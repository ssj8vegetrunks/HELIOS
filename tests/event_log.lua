local files, directories = {}, { ["/helios/data/logs"] = true }
local function combine(...)
    local parts = { ... }
    return (table.concat(parts, "/"):gsub("/+", "/"))
end
fs = {
    combine = combine,
    exists = function(path) return files[path] ~= nil or directories[path] == true end,
    isDir = function(path) return directories[path] == true end,
    makeDir = function(path)
        local current = ""
        for part in path:gmatch("[^/]+") do current = current .. "/" .. part;directories[current] = true end
    end,
    list = function(path)
        local found, prefix = {}, path .. "/"
        for candidate in pairs(files) do
            local rest = candidate:sub(1, #prefix) == prefix and candidate:sub(#prefix + 1) or nil
            if rest and not rest:find("/", 1, true) then found[rest] = true end
        end
        for candidate in pairs(directories) do
            local rest = candidate:sub(1, #prefix) == prefix and candidate:sub(#prefix + 1) or nil
            if rest and rest ~= "" and not rest:find("/", 1, true) then found[rest] = true end
        end
        local result = {};for name in pairs(found) do result[#result + 1] = name end;return result
    end,
    open = function(path, mode)
        if mode == "w" then return { write=function(value) files[path]=value end, close=function() end } end
        if mode == "r" and files[path] then return { readAll=function() return files[path] end, close=function() end } end
    end,
    delete = function(path)
        files[path], directories[path] = nil, nil
        for candidate in pairs(files) do if candidate:sub(1, #path + 1) == path .. "/" then files[candidate] = nil end end
        for candidate in pairs(directories) do if candidate:sub(1, #path + 1) == path .. "/" then directories[candidate] = nil end end
    end,
}
os.epoch = function() return 1789372800000 end
os.date = function(format) return format == "!%Y-%m-%d" and "2026-09-14" or "06" end
os.getComputerID = function() return 42 end

local log = dofile("src/core/event_log.lua")
local record = assert(log.append("log.test", { severity="warning", subsystem="reactor",
    values={ device="Reactor 1" }, pages={ "First page", "Second page" }, retentionDays=7 }))
assert(record.day == "2026-09-14" and record.hour == "06", "events should be grouped by day and hour")
assert(#log.days() == 1 and log.days()[1] == "2026-09-14", "day shelf should be discoverable")
assert(#log.hours("2026-09-14") == 1 and log.hours("2026-09-14")[1] == "06", "hour shelf should be discoverable")
local events = log.events("2026-09-14", "06")
assert(#events == 1 and events[1].key == "log.test", "event book should round-trip")
assert(#events[1].pages == 2 and events[1].pages[2] == "Second page", "detail pages should round-trip")

print("event log tests passed")
