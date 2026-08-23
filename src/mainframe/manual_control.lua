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

function manual.newSafetyState()
    return { armed = false }
end

function manual.activateReactors(reactors, setActive)
    if type(setActive) ~= "function" then
        return false, { "Reactor activation writer is unavailable" }
    end
    local errors = {}
    for _, reactor in ipairs(reactors or {}) do
        local ok, _, reason = setActive(reactor, true)
        if not ok then
            errors[#errors + 1] = tostring(reactor.name or "reactor") ..
                ": " .. tostring(reason or "activation rejected")
        end
    end
    return #errors == 0, errors
end

function manual.shouldFailover(state, storages, threshold)
    state = type(state) == "table" and state or manual.newSafetyState()
    local reserve = manual.minimumReserve(storages)
    threshold = tonumber(threshold) or 2

    -- Manual control is also the recovery path for an already depleted grid.
    -- Do not immediately eject the operator when manual authority begins below
    -- the threshold. Arm the failover only after this session has first reached
    -- a safe reserve, then protect against a subsequent fall below it.
    if reserve ~= nil and reserve >= threshold then state.armed = true end
    return state.armed == true and reserve ~= nil and reserve < threshold,
        reserve, state.armed == true
end

return manual
