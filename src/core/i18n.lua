local i18n = {}

local DEFAULT_LANGUAGE = "en_us"
local PACK_DIR = "/helios/lang"

local function validId(value)
    return type(value) == "string" and value:match("^[a-z][a-z]_[a-z][a-z]$") ~= nil
end

local function loadPack(id)
    if not validId(id) then return nil, "invalid language id" end
    local path = PACK_DIR .. "/" .. id .. ".lua"
    if not fs.exists(path) then return nil, "language pack is not installed" end
    local ok, pack = pcall(dofile, path)
    if not ok or type(pack) ~= "table" or pack.id ~= id or
       type(pack.name) ~= "string" or type(pack.strings) ~= "table" then
        return nil, "language pack is invalid"
    end
    for key, value in pairs(pack.strings) do
        if type(key) ~= "string" or type(value) ~= "string" then
            return nil, "language pack contains a non-text entry"
        end
    end
    return pack
end

local function replace(template, values)
    values = type(values) == "table" and values or {}
    return (tostring(template):gsub("{([%w_]+)}", function(key)
        local value = values[key]
        return value == nil and "{" .. key .. "}" or tostring(value)
    end))
end

local function valueKey(value)
    return "value." .. tostring(value):lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
end

function i18n.available()
    local result = {}
    if fs.exists(PACK_DIR) and fs.isDir(PACK_DIR) then
        for _, file in ipairs(fs.list(PACK_DIR)) do
            local id = file:match("^([a-z][a-z]_[a-z][a-z])%.lua$")
            if id then
                local pack = loadPack(id)
                if pack then result[#result + 1] = { id = id, name = pack.name or id } end
            end
        end
    end
    table.sort(result, function(a, b) return a.id < b.id end)
    return result
end

function i18n.new(config)
    config = type(config) == "table" and config or {}
    local wanted = config.ui and config.ui.language or DEFAULT_LANGUAGE
    if not validId(wanted) then wanted = DEFAULT_LANGUAGE end
    local fallback = loadPack(DEFAULT_LANGUAGE)
    if not fallback then error("HELIOS English language pack is missing", 0) end
    local selected, reason = wanted == DEFAULT_LANGUAGE and fallback or loadPack(wanted)
    if not selected then selected, wanted = fallback, DEFAULT_LANGUAGE end
    local service = { id = wanted, name = selected.name or wanted, loadError = reason }
    function service.get(key, values, explicitFallback)
        local value = selected.strings[key] or fallback.strings[key] or explicitFallback or key
        return replace(value, values)
    end
    function service.fit(key, width, values, explicitFallback)
        local value = service.get(key, values, explicitFallback)
        width = math.max(0, math.floor(tonumber(width) or #value))
        if #value <= width then return value end
        if width <= 3 then return value:sub(1, width) end
        return value:sub(1, width - 3) .. "..."
    end
    -- Translate API/governor enum values only when a language pack explicitly
    -- provides a mapping. Unknown device text is deliberately preserved.
    function service.value(value)
        if value == nil then return service.get("common.unknown") end
        local key = valueKey(value)
        return replace(selected.strings[key] or fallback.strings[key] or tostring(value))
    end
    return service
end

return i18n
