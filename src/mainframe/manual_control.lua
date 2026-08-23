local manual = {}

-- @section MANUAL AUTHORITY SAFETY
function manual.minimumReserve(storages)
    local minimum
    for _, storage in ipairs(storages or {}) do
        local percent = tonumber(storage.percent)
        if storage.telemetryOk ~= false and percent then
            minimum = minimum and math.min(minimum, percent) or percent
        end
    end
    return minimum
end

function manual.shouldFailover(storages, threshold)
    local reserve = manual.minimumReserve(storages)
    threshold = tonumber(threshold) or 2
    return reserve ~= nil and reserve < threshold, reserve
end

return manual
