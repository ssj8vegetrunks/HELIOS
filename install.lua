-- HELIOS modular bootstrap installer
-- Downloads only the Core, role, and optional packages selected for this computer.

local VERSION = "1.6.0-alpha.27"
local BASE_URL = "https://raw.githubusercontent.com/ssj8vegetrunks/HELIOS/testing/public-alpha"
local MANIFEST_URL = BASE_URL .. "/packages/manifest.json"
local INSTALL_DIR, LOCAL_STAGE = "/helios", "/.helios-install"

local function colour(value) if term.isColor() then term.setTextColor(value) end end
local function title(value)
    term.setBackgroundColor(colors.black);term.clear();term.setCursorPos(1, 1)
    colour(colors.yellow);print("HELIOS");colour(colors.white)
    print("Industrial Power Management Suite")
    colour(colors.lightGray);print(tostring(value or "Installer") .. "  " .. VERSION);print("")
    colour(colors.white)
end
local function confirm(prompt, defaultYes)
    write(prompt .. (defaultYes and " [Y/n] " or " [y/N] "))
    local answer = read():lower()
    if answer == "" then return defaultYes == true end
    return answer == "y" or answer == "yes"
end
local function choose(prompt, options, defaultIndex)
    while true do
        print(prompt)
        for index, option in ipairs(options) do
            print((index == defaultIndex and "* " or "  ") .. index .. ") " .. option.label)
        end
        write("> ");local answer = read()
        if answer == "" and defaultIndex then return options[defaultIndex].value end
        local index = tonumber(answer)
        if index and options[index] then return options[index].value end
        colour(colors.red);print("Please enter a number from the list.");colour(colors.white)
    end
end
local function fetch(url)
    if not http or type(http.get) ~= "function" then
        error("CC:Tweaked HTTP is disabled. Enable HTTP and run the HELIOS installer again.", 0)
    end
    local response, reason = http.get(url)
    if not response then error("Could not download " .. url .. ": " .. tostring(reason), 0) end
    local contents = response.readAll();response.close();return contents
end
local function writeFile(path, contents)
    local parent = fs.getDir(path)
    if parent ~= "" and not fs.exists(parent) then fs.makeDir(parent) end
    local handle, reason = fs.open(path, "w")
    if not handle then error("Could not write " .. path .. ": " .. tostring(reason), 0) end
    handle.write(contents);handle.close()
end
local function safePath(path)
    return type(path) == "string" and path ~= "" and path:sub(1, 1) ~= "/" and
        not path:find("..", 1, true) and not path:find("\\", 1, true)
end
local function loadManifest()
    local encoded = fetch(MANIFEST_URL)
    local ok, manifest = pcall(textutils.unserializeJSON, encoded)
    if not ok or type(manifest) ~= "table" or manifest.schema_version ~= 1 or
       manifest.core_version ~= VERSION or type(manifest.packages) ~= "table" then
        error("The HELIOS package manifest is invalid or belongs to another Core version.", 0)
    end
    return manifest
end
local function resolvePackages(manifest, requested)
    local ordered, included, visiting = {}, {}, {}
    local function include(id)
        if included[id] then return end
        if visiting[id] then error("Package dependency cycle involving " .. tostring(id), 0) end
        local package = manifest.packages[id]
        if type(package) ~= "table" or type(package.files) ~= "table" or type(package.required) ~= "table" then
            error("Package is missing or invalid: " .. tostring(id), 0)
        end
        visiting[id] = true
        for _, dependency in ipairs(package.required) do include(dependency) end
        visiting[id] = nil;included[id] = true;ordered[#ordered + 1] = id
    end
    for _, id in ipairs(requested) do include(id) end
    return ordered
end
local function packageFiles(manifest, packageIds)
    local files, destinations, total = {}, {}, 0
    for _, id in ipairs(packageIds) do
        for _, file in ipairs(manifest.packages[id].files) do
            if not safePath(file.source) or not safePath(file.path) or type(file.bytes) ~= "number" then
                error("Package " .. id .. " contains an unsafe file entry.", 0)
            end
            if destinations[file.path] and destinations[file.path] ~= file.source then
                error("Packages disagree about destination " .. file.path, 0)
            end
            if not destinations[file.path] then
                destinations[file.path] = file.source;files[#files + 1] = file;total = total + file.bytes
            end
        end
    end
    table.sort(files, function(a, b) return a.path < b.path end)
    return files, total
end
local function existingConfig()
    local path = fs.combine(INSTALL_DIR, "config.lua")
    if not fs.exists(path) then return nil end
    local ok, value = pcall(dofile, path)
    return ok and type(value) == "table" and value or nil
end
local function removePrograms()
    if not fs.exists(INSTALL_DIR) then return end
    for _, name in ipairs({ "core", "draconic", "gui", "mainframe", "modules", "terminal", "tools", "helios.lua" }) do
        local path = fs.combine(INSTALL_DIR, name)
        if fs.exists(path) then fs.delete(path) end
    end
end
local function externalStage(requiredBytes)
    if not fs.getDrive then return nil end
    local localDrive = fs.getDrive("/")
    for _, name in ipairs(fs.list("/")) do
        local mount = "/" .. name
        if fs.isDir(mount) and fs.getDrive(mount) ~= localDrive and
           (not fs.isReadOnly or not fs.isReadOnly(mount)) then
            local free = fs.getFreeSpace(mount)
            if type(free) == "number" and free >= requiredBytes then
                return fs.combine(mount, ".helios-install"), mount
            end
        end
    end
end
local function installStage(stage)
    if not fs.exists(INSTALL_DIR) then fs.makeDir(INSTALL_DIR) end
    local sameDrive = not fs.getDrive or fs.getDrive(stage) == fs.getDrive(INSTALL_DIR)
    for _, name in ipairs(fs.list(stage)) do
        local source, destination = fs.combine(stage, name), fs.combine(INSTALL_DIR, name)
        if name == "lang" and fs.isDir(source) then
            if not fs.exists(destination) then fs.makeDir(destination) end
            for _, child in ipairs(fs.list(source)) do
                local target = fs.combine(destination, child)
                if fs.exists(target) then fs.delete(target) end
                if sameDrive then fs.move(fs.combine(source, child), target)
                else fs.copy(fs.combine(source, child), target) end
            end
        else
            if fs.exists(destination) then fs.delete(destination) end
            if sameDrive then fs.move(source, destination) else fs.copy(source, destination) end
        end
    end
    fs.delete(stage)
end
local function installStartup()
    if fs.exists("/startup") and not fs.isDir("/startup") then
        print("An existing startup program was found.")
        if not confirm("Preserve it and create a startup directory?", true) then return false end
        local temporary = "/.helios-existing-startup.lua"
        if fs.exists(temporary) then fs.delete(temporary) end
        fs.move("/startup", temporary);fs.makeDir("/startup");fs.move(temporary, "/startup/00-user.lua")
    elseif not fs.exists("/startup") then fs.makeDir("/startup") end
    if fs.exists("/startup/99-helios.lua") then fs.delete("/startup/99-helios.lua") end
    writeFile("/startup/50-helios.lua", 'shell.run("/helios/helios.lua")\n');return true
end
local function configure(previous, role, language, logging, renderer, display, guardianId, networkEnabled, networkKey)
    local config = previous or {}
    config.version = VERSION;config.role = role;config.computerId = os.getComputerID();config.display = display
    config.ui = config.ui or {};config.ui.language = language
    config.ui.accessibilityProfile = config.ui.accessibilityProfile or "high_contrast"
    config.ui.statusSymbols = config.ui.statusSymbols ~= false;config.ui.renderer = renderer or "default"
    config.network = config.network or {};if role == "profiler" then config.network.guardianId = guardianId end
    config.network.securityEnabled = networkEnabled == true
    config.network.securityKey = networkEnabled and networkKey or ""
    config.logging = config.logging or {};config.logging.enabled = logging == true
    config.logging.retentionDays = tonumber(config.logging.retentionDays) or 7
    config.control = config.control or {};config.control.mode = "automatic"
    config.control.actuatorsEnabled = role == "mainframe";return config
end

local function run()
    local previous = existingConfig();title("Modular Installer")
    local roles = {
        {label="Mainframe",value="mainframe"},{label="Remote Terminal",value="terminal"},
        {label="Draconic Guardian",value="guardian"},{label="Draconic Profiler",value="profiler"},
    }
    local defaultRole = 1
    if previous then for index, item in ipairs(roles) do if item.value == previous.role then defaultRole = index end end end
    local role = choose("Select this computer's role:", roles, defaultRole)
    local languages = {
        {label="English",value="en_us"},{label="Espanol",value="es_es"},
        {label="Francais (Canada)",value="fr_ca"},{label="Deutsch",value="de_de"},
        {label="Pirate English",value="en_pi"},
    }
    local defaultLanguage, oldLanguage = 1, previous and previous.ui and previous.ui.language
    for index, item in ipairs(languages) do if item.value == oldLanguage then defaultLanguage = index end end
    local language = choose("Select a language pack:", languages, defaultLanguage)
    local requested, logging = { role }, false
    if language ~= "en_us" then requested[#requested + 1] = "language_" .. language end
    if role == "mainframe" then
        logging = confirm("Install Captain's Log?", previous == nil or not previous.logging or previous.logging.enabled ~= false)
        if logging then requested[#requested + 1] = "captains_log" end
    end
    local renderer = "default"
    if role == "mainframe" or role == "terminal" then
        local hadControlRoom = previous == nil or
            (previous.ui and previous.ui.renderer == "control-room") or fs.exists("/helios/gui/control-room/manifest.lua")
        if confirm("Install the Control Room graphical interface?", hadControlRoom) then
            requested[#requested + 1] = "control_room";renderer = "control-room"
        end
    end
    local hadProbe = previous == nil or fs.exists("/helios/tools/discovery_probe.lua")
    if role == "mainframe" and confirm("Install the read-only hardware discovery probe?", hadProbe) then
        requested[#requested + 1] = "discovery_probe"
    end
    local display, guardianId
    if role == "terminal" then
        display = choose("Select the terminal view:", {
            {label="All systems",value="all"},{label="Reactors",value="reactor"},
            {label="Turbines",value="turbine"},{label="Power storage",value="battery"},
        }, 1)
    elseif role == "profiler" then
        print("Enter the Draconic Guardian computer ID:");write("> ");guardianId = tonumber(read())
        if not guardianId or guardianId < 0 or guardianId ~= math.floor(guardianId) then
            error("Guardian computer ID must be a whole number.", 0)
        end
    end

    local networkEnabled = previous and previous.network and previous.network.securityEnabled == true or false
    local networkKey = networkEnabled and tostring(previous.network.securityKey or "") or ""
    local modemDetected = false
    for _, name in ipairs(peripheral.getNames()) do
        for _, kind in ipairs({ peripheral.getType(name) }) do
            if kind == "modem" then modemDetected = true break end
        end
        if modemDetected then break end
    end
    if modemDetected and confirm("Enable HELIOS network protection on this computer?", networkEnabled) then
        print(networkEnabled and "Enter a replacement key, or leave blank to keep the current key:" or
            "Enter the shared HELIOS network key (8-128 characters):")
        write("> ");local entered = read("*")
        if entered ~= "" then networkKey = entered end
        if #networkKey < 8 or #networkKey > 128 then error("Network keys must contain 8-128 characters.", 0) end
        networkEnabled = true
    elseif modemDetected then networkEnabled = false;networkKey = "" end

    title("Reading Package Manifest")
    local manifest = loadManifest();local packageIds = resolvePackages(manifest, requested)
    local files, payloadBytes = packageFiles(manifest, packageIds)
    print("Role: " .. role);print("Packages: " .. #packageIds);print("Files: " .. #files)
    print("Download: approximately " .. math.ceil(payloadBytes / 1024) .. " KiB")
    if not confirm("Install these HELIOS packages?", true) then print("Installation cancelled.");return end

    local config = configure(previous, role, language, logging, renderer, display, guardianId, networkEnabled, networkKey)
    local required, localFree = payloadBytes + (32 * 1024), fs.getFreeSpace("/")
    local stage, mount = LOCAL_STAGE
    if type(localFree) == "number" and localFree < required then stage, mount = externalStage(required) end
    local lowSpace = not mount and type(localFree) == "number" and localFree < required
    if lowSpace then
        title("Low-Space Upgrade")
        print("Preserving configuration, calibration, data, and installed languages.")
        print("Removing the old program payload before downloading this role...")
        removePrograms();localFree = fs.getFreeSpace("/")
        if type(localFree) == "number" and localFree < required then
            error("This role needs approximately " .. required .. " free bytes; only " .. localFree .. " are available.", 0)
        end
    elseif mount then print("Using " .. mount .. " as the temporary installation workspace.") end

    if fs.exists(stage) then fs.delete(stage) end;fs.makeDir(stage);title("Downloading Selected Packages")
    for index, file in ipairs(files) do
        term.setCursorPos(1, 6);term.clearLine();write(index .. "/" .. #files .. "  " .. file.path)
        local contents = fetch(BASE_URL .. "/" .. file.source)
        if #contents ~= file.bytes then fs.delete(stage);error("Size verification failed for " .. file.source, 0) end
        writeFile(fs.combine(stage, file.path), contents)
    end
    writeFile(fs.combine(stage, "config.lua"), "return " .. textutils.serialize(config))
    if not lowSpace then removePrograms() end
    if mount then
        local finalFree = fs.getFreeSpace("/")
        if type(finalFree) == "number" and finalFree < payloadBytes + 4096 then
            error("The selected packages do not fit on this computer after preserving its data.", 0)
        end
    end
    installStage(stage);writeFile("/helios.lua", 'shell.run("/helios/helios.lua", ...)\n')
    local startup = installStartup();title("Installation Complete")
    colour(colors.lime);print("HELIOS " .. VERSION .. " installed successfully.");colour(colors.white)
    print("Installed only: " .. table.concat(packageIds, ", "))
    print(startup and "HELIOS will start after reboot." or "Run now with: helios")
end

local ok, reason = pcall(run)
if not ok then colour(colors.red);print("");print("HELIOS installation failed:");print(tostring(reason));colour(colors.white) end
