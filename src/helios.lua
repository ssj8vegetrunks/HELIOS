-- @section PROGRAM ENTRYPOINT
local args = { ... }
local config = dofile("/helios/core/config.lua").load()

if args[1] == "logs" then
    if not fs.exists("/helios/core/log_viewer.lua") then
        error("Captain's Log is not installed on this computer.", 0)
    end
    dofile("/helios/core/log_viewer.lua").run(config, args[2], args[3])
    return
end

if args[1] == "archive" then
    if not fs.exists("/helios/core/event_log.lua") then
        error("Captain's Log is not installed on this computer.", 0)
    end
    local action = args[2] or "status"
    local markerName = ".helios-storage"
    local computerId = os.getComputerID and os.getComputerID() or 0
    local function externalMounts()
        local mounts, localDrive = {}, fs.getDrive and fs.getDrive("/") or "hdd"
        if fs.getDrive then
            for _, name in ipairs(fs.list("/")) do
                local path = "/" .. name
                if fs.isDir(path) and fs.getDrive(path) ~= localDrive then mounts[#mounts + 1] = path end
            end
        end
        table.sort(mounts);return mounts
    end
    if action == "status" then
        local state = dofile("/helios/core/event_log.lua").storage()
        print("Captain's Log storage: " .. state.path)
        print(state.external and "HELIOS archive disk online." or "Using limited local computer storage.")
    elseif action == "attach" then
        local wanted = args[3]
        if wanted and wanted:sub(1, 1) ~= "/" then wanted = "/" .. wanted end
        local mounts = externalMounts()
        local mount = wanted
        if not mount then
            if #mounts ~= 1 then error("Attach one writable disk, or use: helios archive attach <mount>", 0) end
            mount = mounts[1]
        end
        local valid = false
        for _, candidate in ipairs(mounts) do if candidate == mount then valid = true break end end
        if not valid then error("That path is not an attached data disk: " .. tostring(mount), 0) end
        local marker = fs.combine(mount, markerName)
        local handle, reason = fs.open(marker, "w")
        if not handle then error("The disk is not writable: " .. tostring(reason), 0) end
        handle.write(textutils.serialize({ kind = "helios-archive", computerId = computerId, version = 1 }));handle.close()
        fs.makeDir(fs.combine(mount, "helios-archive/logs"))
        print("HELIOS archive disk attached at " .. mount .. ".")
        print("Control and safety remain on the computer if this disk is removed.")
    elseif action == "detach" then
        local removed = 0
        for _, mount in ipairs(externalMounts()) do
            local marker = fs.combine(mount, markerName)
            if fs.exists(marker) then
                local handle = fs.open(marker, "r")
                local value = handle and textutils.unserialize(handle.readAll()) or nil
                if handle then handle.close() end
                if type(value) == "table" and value.kind == "helios-archive" and value.computerId == computerId then
                    fs.delete(marker);removed = removed + 1
                end
            end
        end
        print("Detached " .. removed .. " HELIOS archive disk(s). Existing archives were not deleted.")
    else
        error("Usage: helios archive [status|attach <mount>|detach]", 0)
    end
    return
end

if args[1] == "network" then
    local security = dofile("/helios/core/network_security.lua")
    local action = args[2] or "status"
    config.network = config.network or {}
    local function save()
        local ok, reason = dofile("/helios/core/config.lua").save(config)
        if not ok then error("Could not save HELIOS configuration: " .. tostring(reason), 0) end
    end
    local function readKey(prompt)
        print(prompt);write("> ")
        local value = read("*")
        if not security.validKey(value) then error("Network keys must contain 8-128 characters.", 0) end
        print("Re-enter the HELIOS network key to verify it:");write("> ")
        local verified = read("*")
        if value ~= verified then error("The HELIOS network keys do not match. No changes were made.", 0) end
        return value
    end
    if action == "status" then
        print("Network protection: " .. (security.enabled(config) and "ENABLED" or "DISABLED"))
        print("Network code: " .. security.networkId(config))
        print("Site: " .. tostring(config.network.siteId or "default"))
    elseif action == "enable" then
        config.network.securityKey = readKey("Enter the shared HELIOS network key:")
        config.network.securityEnabled = true;save()
        print("Network protection enabled. Network code: " .. security.networkId(config))
        print("Restart HELIOS to reconnect using the protected network.")
    elseif action == "generate" then
        config.network.securityKey = security.generateKey();config.network.securityEnabled = true;save()
        print("Generated pairing key: " .. config.network.securityKey)
        print("Network code: " .. security.networkId(config))
        print("Copy the pairing key to every HELIOS computer, then restart them.")
    elseif action == "key" then
        config.network.securityKey = readKey("Enter the replacement HELIOS network key:")
        config.network.securityEnabled = true;save()
        print("Network key replaced. Restart every HELIOS computer.")
    elseif action == "disable" then
        config.network.securityEnabled = false;save()
        print("Network protection disabled. Restart HELIOS to use the open network.")
    else
        error("Usage: helios network [status|enable|generate|key|disable]", 0)
    end
    return
end

if args[1] == "language" then
    local i18n = dofile("/helios/core/i18n.lua")
    local action = args[2] or "list"
    local catalog = { de_de = "Deutsch", en_pi = "Pirate English", es_es = "Espanol", fr_ca = "Francais (Canada)" }
    local catalogOrder = { "de_de", "en_pi", "es_es", "fr_ca" }
    local baseUrl = "https://raw.githubusercontent.com/ssj8vegetrunks/HELIOS/testing/public-alpha/src/lang/"
    local function download(id)
        if not catalog[id] then error("Unknown HELIOS language pack: " .. tostring(id), 0) end
        if not http or type(http.get) ~= "function" then error("HTTP is disabled; language pack cannot be downloaded.", 0) end
        local response, reason = http.get(baseUrl .. id .. ".lua")
        if not response then error("Language download failed: " .. tostring(reason), 0) end
        local contents = response.readAll();response.close()
        local temporary = "/helios/lang/." .. id .. ".download"
        local handle, writeReason = fs.open(temporary, "w")
        if not handle then error("Could not save language pack: " .. tostring(writeReason), 0) end
        handle.write(contents);handle.close()
        local ok, pack = pcall(dofile, temporary)
        if not ok or type(pack) ~= "table" or pack.id ~= id or type(pack.strings) ~= "table" then
            fs.delete(temporary);error("Downloaded language pack is invalid.", 0)
        end
        local destination = "/helios/lang/" .. id .. ".lua"
        if fs.exists(destination) then fs.delete(destination) end
        fs.move(temporary, destination)
        return pack
    end
    if action == "list" then
        for _, pack in ipairs(i18n.available()) do
            print((pack.id == config.ui.language and "* " or "  ") .. pack.id .. " - " .. pack.name)
        end
        print("Available downloads:")
        for _, id in ipairs(catalogOrder) do
            local name = catalog[id]
            if not fs.exists("/helios/lang/" .. id .. ".lua") then print("  " .. id .. " - " .. name) end
        end
    elseif action == "install" then
        local id = tostring(args[3] or "")
        local pack = download(id)
        print("Installed " .. pack.name .. ". Use: helios language set " .. id)
    elseif action == "remove" then
        local id = tostring(args[3] or "")
        if id == "en_us" then error("English is the required HELIOS fallback and cannot be removed.", 0) end
        if not catalog[id] then error("Unknown HELIOS language pack: " .. id, 0) end
        local path = "/helios/lang/" .. id .. ".lua"
        if fs.exists(path) then fs.delete(path) end
        if config.ui.language == id then
            config.ui.language = "en_us"
            local ok, reason = dofile("/helios/core/config.lua").save(config)
            if not ok then error("Could not save HELIOS configuration: " .. tostring(reason), 0) end
        end
        print("Removed " .. id .. ".")
    elseif action == "set" then
        local wanted, found = tostring(args[3] or ""), false
        for _, pack in ipairs(i18n.available()) do if pack.id == wanted then found = true break end end
        if not found then error("Language pack is not installed: " .. wanted, 0) end
        config.ui.language = wanted
        local ok, reason = dofile("/helios/core/config.lua").save(config)
        if not ok then error("Could not save HELIOS configuration: " .. tostring(reason), 0) end
        print("HELIOS language set to " .. wanted .. ". Restart HELIOS to apply it.")
    else
        error("Usage: helios language [list|install <id>|remove <id>|set <id>]", 0)
    end
    return
end

if args[1] == "accessibility" then
    local service = dofile("/helios/core/accessibility.lua")
    local action = args[2] or "list"
    if action == "list" then
        for _, profile in ipairs(service.profiles()) do
            print((profile == config.ui.accessibilityProfile and "* " or "  ") .. profile)
        end
        print("Status symbols: " .. (config.ui.statusSymbols and "enabled" or "disabled"))
    elseif action == "set" then
        local profile = tostring(args[3] or "")
        if not service.valid(profile) then error("Unknown accessibility profile: " .. profile, 0) end
        config.ui.accessibilityProfile = profile
        local ok, reason = dofile("/helios/core/config.lua").save(config)
        if not ok then error("Could not save HELIOS configuration: " .. tostring(reason), 0) end
        print("HELIOS accessibility profile set to " .. profile .. ". Restart HELIOS to apply it.")
    elseif action == "symbols" then
        local wanted = tostring(args[3] or ""):lower()
        if wanted ~= "on" and wanted ~= "off" then
            error("Usage: helios accessibility symbols <on|off>", 0)
        end
        config.ui.statusSymbols = wanted == "on"
        local ok, reason = dofile("/helios/core/config.lua").save(config)
        if not ok then error("Could not save HELIOS configuration: " .. tostring(reason), 0) end
        print("HELIOS status symbols " .. (config.ui.statusSymbols and "enabled." or "disabled."))
    else
        error("Usage: helios accessibility [list|set <profile>|symbols <on|off>]", 0)
    end
    return
end

if args[1] == nil and config.role == "guardian" then
    dofile("/helios/draconic/controller.lua")
    return
end

if args[1] == nil and config.role == "profiler" then
    dofile("/helios/draconic/profiler.lua")
    return
end

if args[1] == "probe" then
    if not fs.exists("/helios/tools/discovery_probe.lua") then
        error("The discovery probe is not installed on this computer.", 0)
    end
    dofile("/helios/tools/discovery_probe.lua")
    return
end

if args[1] == "draconic" then
    if not fs.exists("/helios/draconic/guardian.lua") then
        error("The legacy Draconic diagnostic module is not installed on this computer.", 0)
    end
    local guardian = dofile("/helios/draconic/guardian.lua")
    guardian.run(args[2] or "check")
    return
end

if args[1] == "gui" then
    if not fs.exists("/helios/core/gui_loader.lua") then
        error("Graphical interface management is not installed for this computer role.", 0)
    end
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
    local MAX_REGISTRY_BYTES, MAX_FACILITIES, YIELD_EVERY = 65536, 256, 8
    local function watchdogYield(index)
        if index % YIELD_EVERY == 0 then sleep(0) end
    end
    local function loadFacilities()
        if not fs.exists(path) then return {} end
        local size = fs.getSize(path)
        if size > MAX_REGISTRY_BYTES then
            error("Facility registry is too large (" .. tostring(size) ..
                " bytes). Run 'helios facilities prune' after moving the file aside.", 0)
        end
        local handle, reason = fs.open(path, "r")
        if not handle then error("Could not read facility registry: " .. tostring(reason), 0) end
        local contents = handle.readAll()
        handle.close()
        sleep(0)
        contents = contents:gsub("^%s*return%s+", "", 1)
        local loaded = textutils.unserialize(contents)
        if type(loaded) ~= "table" then error("Facility registry is malformed.", 0) end
        local clean, keys = {}, {}
        for nodeId, facility in pairs(loaded) do
            if type(nodeId) == "string" and type(facility) == "table" then
                keys[#keys + 1] = nodeId
            end
        end
        table.sort(keys)
        if #keys > MAX_FACILITIES then
            error("Facility registry contains too many entries (maximum " ..
                tostring(MAX_FACILITIES) .. ").", 0)
        end
        for index, nodeId in ipairs(keys) do
            clean[nodeId] = loaded[nodeId]
            watchdogYield(index)
        end
        return clean, keys
    end
    local facilities, facilityKeys = loadFacilities()
    if args[2] == "prune" then
        local now = os.epoch("utc") / 1000
        local removed = 0
        for index, nodeId in ipairs(facilityKeys) do
            local facility = facilities[nodeId]
            if now - (tonumber(facility.lastSeen) or 0) > 30 then
                facilities[nodeId] = nil
                removed = removed + 1
            end
            watchdogYield(index)
        end
        if not fs.exists("/helios/data") then fs.makeDir("/helios/data") end
        local handle, reason = fs.open(path, "w")
        if not handle then error("Could not update facility registry: " .. tostring(reason), 0) end
        handle.write("return " .. textutils.serialize(facilities))
        handle.close()
        print("Removed " .. removed .. " stale facility registration" .. (removed == 1 and "." or "s."))
        return
    elseif args[2] ~= nil then
        error("Usage: helios facilities [prune]", 0)
    end
    local count = 0
    for index, nodeId in ipairs(facilityKeys) do
        local facility = facilities[nodeId]
        count = count + 1
        print(("%s  %s  %s %s  computer %s"):format(
            tostring(nodeId), tostring(facility.facilityType or "unknown"),
            tostring(facility.software or "unknown"),
            tostring(facility.softwareVersion or "unknown"),
            tostring(facility.id or "unknown")))
        watchdogYield(index)
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
