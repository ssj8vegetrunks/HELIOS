-- @section PROGRAM ENTRYPOINT
local args = { ... }
local config = dofile("/helios/core/config.lua").load()

if args[1] == "language" then
    local i18n = dofile("/helios/core/i18n.lua")
    local action = args[2] or "list"
    if action == "list" then
        for _, pack in ipairs(i18n.available()) do
            print((pack.id == config.ui.language and "* " or "  ") .. pack.id .. " - " .. pack.name)
        end
    elseif action == "set" then
        local wanted, found = tostring(args[3] or ""), false
        for _, pack in ipairs(i18n.available()) do if pack.id == wanted then found = true break end end
        if not found then error("Language pack is not installed: " .. wanted, 0) end
        config.ui.language = wanted
        local ok, reason = dofile("/helios/core/config.lua").save(config)
        if not ok then error("Could not save HELIOS configuration: " .. tostring(reason), 0) end
        print("HELIOS language set to " .. wanted .. ". Restart HELIOS to apply it.")
    else
        error("Usage: helios language [list|set <language_id>]", 0)
    end
    return
end

if config.role == "guardian" then
    dofile("/helios/draconic/controller.lua")
    return
end

if config.role == "profiler" then
    dofile("/helios/draconic/profiler.lua")
    return
end

if args[1] == "probe" then
    dofile("/helios/tools/discovery_probe.lua")
    return
end

if args[1] == "draconic" then
    local guardian = dofile("/helios/draconic/guardian.lua")
    guardian.run(args[2] or "check")
    return
end

if args[1] == "gui" then
    local loader = dofile("/helios/core/gui_loader.lua")
    local action = args[2] or "status"
    if action == "list" or action == "rescan" then
        for _, module in ipairs(loader.scan(config.version)) do
            local selected = module.id == config.ui.renderer and " *" or ""
            print(("%s - %s%s"):format(module.id, module.name, selected))
        end
    elseif action == "set" then
        local id = tostring(args[3] or "")
        local module, reason = loader.resolve(id, config.version)
        if not module then error(reason, 0) end
        config.ui.renderer = id
        local ok, saveReason = dofile("/helios/core/config.lua").save(config)
        if not ok then error(saveReason, 0) end
        print("Graphical interface set to " .. module.name .. ". Restart HELIOS to apply it.")
    elseif action == "install" then
        local module, reason = loader.install(args[3], config.version)
        if not module then error(reason, 0) end
        print("Installed GUI module " .. module.name .. ".")
        print("Select it with: helios gui set " .. module.id)
    elseif action == "status" then
        local module, reason = loader.resolve(config.ui.renderer, config.version)
        print("Selected GUI: " .. tostring(module and module.name or config.ui.renderer))
        if reason then print("Status: ERROR - " .. reason) end
    else
        error("Usage: helios gui [list|rescan|status|set <id>|install <url>]", 0)
    end
    return
end

if args[1] == "modules" and args[2] == "update" then
    if config.role ~= "mainframe" then
        error("Only a HELIOS mainframe installs peripheral modules.", 0)
    end
    print("Updating HELIOS Module Pack...")
    local ok, result = dofile("/helios/core/module_manager.lua").update(config.version)
    if not ok then error(result, 0) end
    print("Module Pack " .. tostring(result) .. " installed. Restart HELIOS to load it.")
    return
end

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
    print("HELIOS Core: " .. tostring(config.version))
    print("Role: " .. tostring(config.role))
    if config.role == "mainframe" then
        local moduleLoader = dofile("/helios/core/module_loader.lua")
        local versions, reason = moduleLoader.versions(config.version)
        if versions then
            print("Module Pack: " .. tostring(versions.pack))
            for _, module in ipairs(versions.modules) do
                print(("  %s: %s"):format(module.name or module.id, module.version or "unknown"))
            end
        else
            print("Module Pack: ERROR - " .. tostring(reason))
        end
    end
    if config.role == "terminal" then
        print("Display: " .. tostring(config.display))
        print("Mainframe ID: " .. tostring(config.mainframeId or "not paired"))
    end
    print("Computer ID: " .. tostring(config.computerId))
    return
end

if args[1] == "facilities" then
    if config.role ~= "mainframe" then
        error("Only the HELIOS mainframe maintains the facility registry.", 0)
    end
    local path = "/helios/data/facilities.lua"
    local facilities = fs.exists(path) and dofile(path) or {}
    local count = 0
    for nodeId, facility in pairs(facilities) do
        count = count + 1
        print(("%s  %s  %s %s  computer %s"):format(
            tostring(nodeId), tostring(facility.facilityType or "unknown"),
            tostring(facility.software or "unknown"),
            tostring(facility.softwareVersion or "unknown"),
            tostring(facility.id or "unknown")))
    end
    if count == 0 then print("No facilities have registered yet.") end
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
    local adapter, reason = dofile("/helios/core/module_loader.lua").load("reactor_adapter", config.version)
    if not adapter then error(reason, 0) end
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
    local adapter, reason = dofile("/helios/core/module_loader.lua").load("turbine_adapter", config.version)
    if not adapter then error(reason, 0) end
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
    local adapter, reason = dofile("/helios/core/module_loader.lua").load("storage_adapter", config.version)
    if not adapter then error(reason, 0) end
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
