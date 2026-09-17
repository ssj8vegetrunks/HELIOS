local formatter = {}

-- @section POWER UNIT CONVERSION AND FORMATTING
local function addCommas(value)
    local sign = value < 0 and "-" or ""
    local digits = tostring(math.floor(math.abs(value) + 0.5))
    local changed
    repeat
        digits, changed = digits:gsub("^(%d+)(%d%d%d)", "%1,%2")
    until changed == 0
    return sign .. digits
end

function formatter.convert(value, powerConfig)
    value = tonumber(value)
    if not value then return nil end
    local unit = powerConfig.unit or "FE"
    local ratio = tonumber((powerConfig.ratios or {})[unit]) or 1
    return value * ratio
end

-- Convert a device's native energy value back to HELIOS's FE base unit.
function formatter.toBase(value, nativeUnit, powerConfig)
    value = tonumber(value)
    if not value then return nil end
    if nativeUnit == "FE" then return value end
    local fallback = nativeUnit == "J" and 2.5 or 1
    local ratio = tonumber(((powerConfig or {}).ratios or {})[nativeUnit]) or fallback
    if ratio <= 0 then return nil end
    return value / ratio
end

function formatter.duration(seconds)
    seconds = tonumber(seconds)
    if not seconds or seconds ~= seconds or seconds == math.huge then return "N/A" end
    seconds = math.max(0, math.floor(seconds + 0.5))
    local days = math.floor(seconds / 86400)
    local hours = math.floor((seconds % 86400) / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local remaining = seconds % 60
    if days > 0 then return ("%dd %dh"):format(days, hours) end
    if hours > 0 then return ("%dh %dm"):format(hours, minutes) end
    if minutes > 0 then return ("%dm %ds"):format(minutes, remaining) end
    return remaining .. "s"
end

function formatter.number(value, powerConfig)
    value = tonumber(value)
    if not value then return "N/A" end
    if powerConfig.numberFormat == "full" then return addCommas(value) end
    local absolute = math.abs(value)
    local scale, suffix = 1, ""
    if absolute >= 1e18 then scale, suffix = 1e18, "Qi"
    elseif absolute >= 1e15 then scale, suffix = 1e15, "Qa"
    elseif absolute >= 1e12 then scale, suffix = 1e12, "T"
    elseif absolute >= 1e9 then scale, suffix = 1e9, "B"
    elseif absolute >= 1e6 then scale, suffix = 1e6, "M"
    elseif absolute >= 1e3 then scale, suffix = 1e3, "k"
    end
    if scale == 1 then
        local rounded = value >= 0 and math.floor(value + 0.5) or math.ceil(value - 0.5)
        return tostring(rounded)
    end
    local decimals = math.max(1, math.min(2, math.floor(tonumber(powerConfig.decimals) or 1)))
    return (("%." .. decimals .. "f%s"):format(value / scale, suffix))
end

function formatter.power(value, powerConfig, perTick)
    local converted = formatter.convert(value, powerConfig)
    if converted == nil then return "N/A" end
    return formatter.number(converted, powerConfig) .. " " .. (powerConfig.unit or "FE") .. (perTick and "/t" or "")
end

return formatter
