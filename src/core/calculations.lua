-- @section SHARED, HARDWARE-INDEPENDENT CALCULATIONS
-- This is a stable Core interface for HELIOS roles and modules. Keep device
-- API translation and fail-safe Guardian policy in their owning packages.
local calculations = { apiVersion = 1 }

function calculations.number(value)
    value = tonumber(value)
    if not value or value ~= value or value == math.huge or value == -math.huge then
        return nil
    end
    return value
end

function calculations.clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

function calculations.round(value, places)
    local scale = 10 ^ (places or 0)
    if value >= 0 then return math.floor(value * scale + 0.5) / scale end
    return math.ceil(value * scale - 0.5) / scale
end

function calculations.percent(value, maximum)
    value, maximum = calculations.number(value), calculations.number(maximum)
    if not value or not maximum or maximum <= 0 then return nil end
    return calculations.clamp(value / maximum * 100, 0, 100)
end

function calculations.normalizedPercent(reported, value, maximum)
    reported = calculations.number(reported)
    if reported ~= nil then
        if reported >= 0 and reported <= 1 then reported = reported * 100 end
        return calculations.clamp(reported, 0, 100)
    end
    return calculations.percent(value, maximum)
end

return calculations
