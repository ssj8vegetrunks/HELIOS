-- HELIOS read-only adapter template.
-- Replace the example type and telemetry fields with probed hardware behavior.

local adapter = {
    id = "example_device",
    version = "0.1.0-alpha.1",
}

local function safeCall(name, method, ...)
    local ok, value = pcall(peripheral.call, name, method, ...)
    if not ok then return nil, tostring(value) end
    return value, nil
end

function adapter.matches(name)
    if type(name) ~= "string" or not peripheral.isPresent(name) then
        return false
    end
    return peripheral.hasType(name, "example_peripheral_type") == true
end

function adapter.read(device)
    local name = type(device) == "table" and device.name or device
    if not adapter.matches(name) then
        return { name = name, online = false, error = "Unsupported or missing peripheral" }
    end

    local reading, err = safeCall(name, "getExampleReading")
    if err then
        return { name = name, online = false, error = err }
    end

    return {
        name = name,
        online = true,
        reading = tonumber(reading),
    }
end

function adapter.readAll(devices)
    local results = {}
    for _, device in ipairs(devices or {}) do
        if adapter.matches(device.name or device) then
            results[#results + 1] = adapter.read(device)
        end
    end
    return results
end

-- Keep actuator support absent until request validation, safe ordering, and
-- hardware readback are implemented and tested for this exact device.
function adapter.command()
    return false, nil, "Actuation is not implemented by this read-only template"
end

return adapter
