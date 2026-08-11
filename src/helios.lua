local args = { ... }
local config = dofile("/helios/core/config.lua").load()

if args[1] == "unpair" then
    if config.role ~= "terminal" then
        error("Only a HELIOS remote terminal can be unpaired.", 0)
    end
    config.mainframeId = nil
    local ok, reason = dofile("/helios/core/config.lua").save(config)
    if not ok then error("Could not save HELIOS configuration: " .. tostring(reason), 0) end
    print("Remote terminal unpaired. Restart HELIOS to discover a mainframe.")
    return
end

if args[1] == "status" then
    print("HELIOS " .. tostring(config.version))
    print("Role: " .. tostring(config.role))
    if config.role == "terminal" then
        print("Display: " .. tostring(config.display))
        print("Mainframe ID: " .. tostring(config.mainframeId or "not paired"))
    end
    print("Computer ID: " .. tostring(config.computerId))
    return
end

if args[1] == "scan" then
    if config.role ~= "mainframe" then
        error("Only the HELIOS mainframe can scan attached hardware.", 0)
    end
    local registry = dofile("/helios/mainframe/device_registry.lua")
    local devices = registry.scan()
    registry.save(devices)
    registry.printReport(devices)
    return
end

if args[1] == "reactors" then
    if config.role ~= "mainframe" then
        error("Only the HELIOS mainframe can read reactor telemetry.", 0)
    end
    local registry = dofile("/helios/mainframe/device_registry.lua")
    local adapter = dofile("/helios/mainframe/reactor_adapter.lua")
    local formatter = dofile("/helios/core/power_format.lua")
    local devices = registry.scan()
    adapter.printReport(adapter.readAll(devices), config, formatter)
    return
end

if args[1] == "turbines" then
    if config.role ~= "mainframe" then
        error("Only the HELIOS mainframe can read turbine telemetry.", 0)
    end
    local registry = dofile("/helios/mainframe/device_registry.lua")
    local adapter = dofile("/helios/mainframe/turbine_adapter.lua")
    local formatter = dofile("/helios/core/power_format.lua")
    local devices = registry.scan()
    adapter.printReport(adapter.readAll(devices), config, formatter)
    return
end

if args[1] == "storage" or args[1] == "batteries" then
    if config.role ~= "mainframe" then
        error("Only the HELIOS mainframe can read energy-storage telemetry.", 0)
    end
    local registry = dofile("/helios/mainframe/device_registry.lua")
    local adapter = dofile("/helios/mainframe/storage_adapter.lua")
    local formatter = dofile("/helios/core/power_format.lua")
    local devices = registry.scan()
    adapter.printReport(adapter.readAll(devices, config.power), config, formatter)
    return
end

if config.role == "mainframe" then
    dofile("/helios/mainframe/main.lua").run(config)
elseif config.role == "terminal" then
    dofile("/helios/terminal/main.lua").run(config)
else
    error("Unknown HELIOS role in /helios/config.lua: " .. tostring(config.role), 0)
end
