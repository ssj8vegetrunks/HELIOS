local eventLog = {}

local ROOT = "/helios/data/logs"
local DEFAULT_RETENTION_DAYS = 7
local MAX_EVENTS_PER_HOUR = 256
local MAX_VALUE_LENGTH = 512
local MAX_DETAIL_PAGES = 20
local MAX_PAGE_LENGTH = 1024

local function safeSegment(value)
    return tostring(value or "unknown"):gsub("[^%w_.-]", "_"):sub(1, 80)
end

local function nowParts()
    local milliseconds = type(os.epoch) == "function" and os.epoch("utc") or math.floor(os.clock() * 1000)
    local seconds = math.floor(milliseconds / 1000)
    if type(os.date) == "function" then
        local okDay, day = pcall(os.date, "!%Y-%m-%d", seconds)
        local okHour, hour = pcall(os.date, "!%H", seconds)
        if okDay and okHour and day and hour then return milliseconds, day, hour end
    end
    local day = type(os.day) == "function" and os.day() or 0
    local hour = type(os.time) == "function" and math.floor(os.time()) or 0
    return milliseconds, ("day-%05d"):format(day), ("%02d"):format(hour)
end

local function cleanValues(values)
    local clean = {}
    for key, value in pairs(type(values) == "table" and values or {}) do
        local kind = type(value)
        if kind == "string" or kind == "number" or kind == "boolean" then
            clean[safeSegment(key)] = tostring(value):sub(1, MAX_VALUE_LENGTH)
        end
    end
    return clean
end

local function cleanPages(pages)
    if type(pages) == "string" then pages = { pages } end
    local clean = {}
    for index, page in ipairs(type(pages) == "table" and pages or {}) do
        if index > MAX_DETAIL_PAGES then break end
        clean[index] = tostring(page):sub(1, MAX_PAGE_LENGTH)
    end
    return clean
end

local function listDirectories(path)
    local result = {}
    if not fs.exists(path) or not fs.isDir(path) then return result end
    for _, name in ipairs(fs.list(path)) do
        if fs.isDir(fs.combine(path, name)) then result[#result + 1] = name end
    end
    table.sort(result)
    return result
end

local function listFiles(path)
    local result = {}
    if not fs.exists(path) or not fs.isDir(path) then return result end
    for _, name in ipairs(fs.list(path)) do
        if not fs.isDir(fs.combine(path, name)) and name:match("%.lua$") then result[#result + 1] = name end
    end
    table.sort(result)
    return result
end

local function readRecord(path)
    local handle = fs.open(path, "r")
    if not handle then return nil end
    local contents = handle.readAll();handle.close()
    contents = contents:gsub("^%s*return%s+", "", 1)
    local record = textutils.unserialize(contents)
    return type(record) == "table" and record or nil
end

function eventLog.prune(retentionDays)
    retentionDays = math.max(1, math.floor(tonumber(retentionDays) or DEFAULT_RETENTION_DAYS))
    local days = listDirectories(ROOT)
    while #days > retentionDays do
        fs.delete(fs.combine(ROOT, table.remove(days, 1)))
    end
end

function eventLog.append(key, options)
    options = type(options) == "table" and options or {}
    local timestamp, day, hour = nowParts()
    local hourPath = fs.combine(fs.combine(ROOT, safeSegment(day)), safeSegment(hour))
    fs.makeDir(hourPath)
    local existing = listFiles(hourPath)
    while #existing >= MAX_EVENTS_PER_HOUR do
        fs.delete(fs.combine(hourPath, table.remove(existing, 1)))
    end
    local base = ("event-%013d-%d"):format(timestamp, os.getComputerID and os.getComputerID() or 0)
    local fileName, suffix = base .. ".lua", 0
    while fs.exists(fs.combine(hourPath, fileName)) do suffix = suffix + 1;fileName = base .. "-" .. suffix .. ".lua" end
    local record = {
        version = 1, id = fileName:gsub("%.lua$", ""), timestamp = timestamp,
        day = day, hour = hour, severity = safeSegment(options.severity or "info"),
        subsystem = safeSegment(options.subsystem or "core"), key = tostring(key or "log.unknown"),
        values = cleanValues(options.values), pages = cleanPages(options.pages),
    }
    local handle, reason = fs.open(fs.combine(hourPath, fileName), "w")
    if not handle then return nil, reason end
    handle.write("return " .. textutils.serialize(record));handle.close()
    eventLog.prune(options.retentionDays)
    return record
end

function eventLog.days() return listDirectories(ROOT) end
function eventLog.hours(day) return listDirectories(fs.combine(ROOT, safeSegment(day))) end
function eventLog.events(day, hour)
    local path = fs.combine(fs.combine(ROOT, safeSegment(day)), safeSegment(hour))
    local records = {}
    for _, fileName in ipairs(listFiles(path)) do
        local record = readRecord(fs.combine(path, fileName))
        if record then records[#records + 1] = record end
    end
    return records
end
function eventLog.get(day, hour, id)
    return readRecord(fs.combine(fs.combine(fs.combine(ROOT, safeSegment(day)), safeSegment(hour)), safeSegment(id) .. ".lua"))
end

return eventLog
