-- HELIOS modular bootstrap installer
-- Downloads only the Core, role, and optional packages selected for this computer.

local VERSION = "1.6.0-alpha.61"
local REPOSITORY = "ssj8vegetrunks/HELIOS"
local BRANCH_API = "https://api.github.com/repos/" .. REPOSITORY .. "/commits/testing%2Fpublic-alpha"
local BASE_URL
local INSTALL_DIR, LOCAL_STAGE = "/helios", "/.helios-install"
local DOWNLOAD_NONCE = tostring(os.epoch and os.epoch("utc") or os.getComputerID())

-- The installer must carry its own small catalogue because the selected
-- language package is not available until after installation completes.
local installerLanguage = "en_us"
local installerStrings = {
    es_es = {
        installer="Instalador", suite="Suite de gestion de energia industrial",
        accessibility="Accesibilidad", select_accessibility="Selecciona el perfil de color de accesibilidad:",
        high_contrast="Alto contraste (predeterminado de HELIOS)", classic="Clasico",
        category="Instalador modular", select_category="Selecciona una categoria de instalacion:",
        mainframe="Instalar mainframe", terminal="Instalar terminal remoto", modules="Modulos",
        select_module="Selecciona un modulo:", probe="Sonda de hardware (una ejecucion, solo lectura)",
        guardian="Guardian del reactor draconico", optional="Funciones opcionales",
        event_viewer="Instalar visor de eventos?", terminal_config="Configuracion del terminal remoto",
        select_view="Selecciona la vista del terminal:", all_systems="Todos los sistemas",
        reactors="Reactores", turbines="Turbinas", power_storage="Almacenamiento de energia",
        network="Proteccion de red", enable_network="Activar la proteccion de red HELIOS en este ordenador?",
        reading="Leyendo el manifiesto de paquetes", role="Funcion", packages="Paquetes", files="Archivos",
        download="Descarga", install_prompt="Instalar estos paquetes de HELIOS?",
        downloading="Descargando paquetes seleccionados", complete="Instalacion completa",
        installed="instalado correctamente.", installed_only="Instalado solamente",
        reboot="HELIOS se iniciara despues de reiniciar.", run_now="Ejecutar ahora con: helios",
        cancelled="Instalacion cancelada.", failed="La instalacion de HELIOS ha fallado:",
        invalid_choice="Introduce un numero de la lista.", existing_startup="Se encontro un programa de inicio existente.",
        preserve_startup="Conservarlo y crear un directorio de inicio?"
    },
    fr_ca = {
        installer="Programme d'installation", suite="Suite de gestion energetique industrielle",
        accessibility="Accessibilite", select_accessibility="Selectionnez le profil de couleurs d'accessibilite :",
        high_contrast="Contraste eleve (valeur HELIOS)", classic="Classique",
        category="Installation modulaire", select_category="Selectionnez une categorie d'installation :",
        mainframe="Installer l'ordinateur central", terminal="Installer un terminal distant", modules="Modules",
        select_module="Selectionnez un module :", probe="Sonde materielle (une execution, lecture seule)",
        guardian="Gardien du reacteur draconique", optional="Fonctions facultatives",
        event_viewer="Installer le journal des evenements?", terminal_config="Configuration du terminal distant",
        select_view="Selectionnez l'affichage du terminal :", all_systems="Tous les systemes",
        reactors="Reacteurs", turbines="Turbines", power_storage="Stockage d'energie",
        network="Protection du reseau", enable_network="Activer la protection reseau HELIOS sur cet ordinateur?",
        reading="Lecture du manifeste des paquets", role="Role", packages="Paquets", files="Fichiers",
        download="Telechargement", install_prompt="Installer ces paquets HELIOS?",
        downloading="Telechargement des paquets selectionnes", complete="Installation terminee",
        installed="installe avec succes.", installed_only="Installe seulement",
        reboot="HELIOS demarrera apres le redemarrage.", run_now="Executer maintenant avec : helios",
        cancelled="Installation annulee.", failed="Echec de l'installation de HELIOS :",
        invalid_choice="Entrez un numero de la liste.", existing_startup="Un programme de demarrage existe deja.",
        preserve_startup="Le conserver et creer un repertoire de demarrage?"
    },
    de_de = {
        installer="Installationsprogramm", suite="Industrielle Energieverwaltung",
        accessibility="Barrierefreiheit", select_accessibility="Barrierefreies Farbprofil waehlen:",
        high_contrast="Hoher Kontrast (HELIOS-Standard)", classic="Klassisch",
        category="Modulare Installation", select_category="Installationskategorie waehlen:",
        mainframe="Mainframe installieren", terminal="Remote-Terminal installieren", modules="Module",
        select_module="Modul waehlen:", probe="Hardware-Sonde (einmalig, nur lesend)",
        guardian="Draconic-Reaktorwaechter", optional="Optionale Funktionen",
        event_viewer="Ereignisanzeige installieren?", terminal_config="Remote-Terminal-Konfiguration",
        select_view="Terminalansicht waehlen:", all_systems="Alle Systeme", reactors="Reaktoren",
        turbines="Turbinen", power_storage="Energiespeicher", network="Netzwerkschutz",
        enable_network="HELIOS-Netzwerkschutz auf diesem Computer aktivieren?",
        reading="Paketmanifest wird gelesen", role="Rolle", packages="Pakete", files="Dateien",
        download="Download", install_prompt="Diese HELIOS-Pakete installieren?",
        downloading="Ausgewaehlte Pakete werden geladen", complete="Installation abgeschlossen",
        installed="erfolgreich installiert.", installed_only="Nur installiert",
        reboot="HELIOS startet nach dem Neustart.", run_now="Jetzt ausfuehren mit: helios",
        cancelled="Installation abgebrochen.", failed="HELIOS-Installation fehlgeschlagen:",
        invalid_choice="Bitte eine Nummer aus der Liste eingeben.", existing_startup="Ein vorhandenes Startprogramm wurde gefunden.",
        preserve_startup="Beibehalten und ein Startverzeichnis erstellen?"
    }
}
local englishStrings = {
    installer="Installer", suite="Industrial Power Management Suite", accessibility="Accessibility",
    select_accessibility="Select accessibility colour profile:", high_contrast="High contrast (HELIOS default)",
    classic="Classic", category="Modular Installer", select_category="Select an installation category:",
    mainframe="Install Mainframe", terminal="Install Remote Terminal", modules="Modules",
    select_module="Select a module:", probe="Hardware Probe (run once, read-only)",
    guardian="Draconic Reactor Guardian", optional="Optional Features", event_viewer="Install Event Viewer?",
    terminal_config="Remote Terminal Configuration", select_view="Select the terminal view:",
    all_systems="All systems", reactors="Reactors", turbines="Turbines", power_storage="Power storage",
    network="Network Protection", enable_network="Enable HELIOS network protection on this computer?",
    reading="Reading Package Manifest", role="Role", packages="Packages", files="Files", download="Download",
    install_prompt="Install these HELIOS packages?", downloading="Downloading Selected Packages",
    complete="Installation Complete", installed="installed successfully.", installed_only="Installed only",
    reboot="HELIOS will start after reboot.", run_now="Run now with: helios", cancelled="Installation cancelled.",
    failed="HELIOS installation failed:", invalid_choice="Please enter a number from the list.",
    existing_startup="An existing startup program was found.", preserve_startup="Preserve it and create a startup directory?"
}
local function it(key)
    local selected = installerStrings[installerLanguage]
    return selected and selected[key] or englishStrings[key] or key
end

local function colour(value) if term.isColor() then term.setTextColor(value) end end
local function title(value)
    term.setBackgroundColor(colors.black);term.clear();term.setCursorPos(1, 1)
    colour(colors.yellow);print("HELIOS");colour(colors.white)
    print(it("suite"))
    colour(colors.lightGray);print(tostring(value or it("installer")) .. "  " .. VERSION);print("")
    colour(colors.white)
end
local function confirm(prompt, defaultYes)
    write(prompt .. (defaultYes and " [Y/n] " or " [y/N] "))
    local answer = read():lower()
    if answer == "" then return defaultYes == true end
    return answer == "y" or answer == "yes"
end
local function choose(prompt, options, defaultIndex, hiddenOptions)
    while true do
        print(prompt)
        for index, option in ipairs(options) do
            print((index == defaultIndex and "* " or "  ") .. index .. ") " .. option.label)
        end
        write("> ");local answer = read()
        if answer == "" and defaultIndex then return options[defaultIndex].value end
        local hidden = hiddenOptions and hiddenOptions[answer:lower()]
        if hidden then return hidden end
        local index = tonumber(answer)
        if index and options[index] then return options[index].value end
        colour(colors.red);print(it("invalid_choice"));colour(colors.white)
    end
end
local function selectLanguage(existing)
    title("Language / Idioma / Langue / Sprache")
    local options = {
        {label="English (US)",value="en_us"},{label="Francais (Canada)",value="fr_ca"},
        {label="Deutsch",value="de_de"},{label="Espanol",value="es_es"},
    }
    local selected = 1
    for index, option in ipairs(options) do if option.value == existing then selected = index end end
    return choose("Select installer language:", options, selected, { p = "en_pi" })
end
local function selectAccessibility(existing)
    title(it("accessibility"))
    local options = {
        {label=it("high_contrast"),value="high_contrast"},
        {label=it("classic"),value="standard"},{label="Deuteranopia",value="deuteranopia"},
        {label="Protanopia",value="protanopia"},{label="Tritanopia",value="tritanopia"},
    }
    local selected = 1
    for index, option in ipairs(options) do if option.value == existing then selected = index end end
    return choose(it("select_accessibility"), options, selected)
end
local function fetch(url)
    if not http or type(http.get) ~= "function" then
        error("CC:Tweaked HTTP is disabled. Enable HTTP and run the HELIOS installer again.", 0)
    end
    local separator = url:find("?", 1, true) and "&" or "?"
    local response, reason = http.get(url .. separator .. "helios_install=" .. DOWNLOAD_NONCE)
    if not response then error("Could not download " .. url .. ": " .. tostring(reason), 0) end
    local contents = response.readAll();response.close();return contents
end
local function pinRevision()
    if BASE_URL then return end
    local encoded = fetch(BRANCH_API)
    local ok, revision = pcall(textutils.unserializeJSON, encoded)
    local sha = ok and type(revision) == "table" and revision.sha or nil
    if type(sha) ~= "string" or not sha:match("^[0-9a-f]+$") or #sha ~= 40 then
        error("Could not resolve the HELIOS testing branch to a Git revision.", 0)
    end
    BASE_URL = "https://raw.githubusercontent.com/" .. REPOSITORY .. "/" .. sha
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
    pinRevision()
    local encoded = fetch(BASE_URL .. "/packages/manifest.json")
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
        print(it("existing_startup"))
        if not confirm(it("preserve_startup"), true) then return false end
        local temporary = "/.helios-existing-startup.lua"
        if fs.exists(temporary) then fs.delete(temporary) end
        fs.move("/startup", temporary);fs.makeDir("/startup");fs.move(temporary, "/startup/00-user.lua")
    elseif not fs.exists("/startup") then fs.makeDir("/startup") end
    if fs.exists("/startup/99-helios.lua") then fs.delete("/startup/99-helios.lua") end
    writeFile("/startup/50-helios.lua", 'shell.run("/helios/helios.lua")\n');return true
end
local function configure(previous, role, language, accessibility, logging, renderer, display, guardianId, networkEnabled, networkKey)
    local config = previous or {}
    config.version = VERSION;config.role = role;config.computerId = os.getComputerID();config.display = display
    config.ui = config.ui or {};config.ui.language = language
    config.ui.accessibilityProfile = accessibility or "high_contrast"
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
    local previous = existingConfig()
    local previousUi = previous and previous.ui or {}
    local language = selectLanguage(previousUi.language)
    installerLanguage = language
    local accessibility = selectAccessibility(previousUi.accessibilityProfile)
    title(it("category"))
    local defaultCategory = previous and previous.role == "terminal" and 2 or
        (previous and (previous.role == "guardian" or previous.role == "profiler") and 3 or 1)
    local category = choose(it("select_category"), {
        {label=it("mainframe"),value="mainframe"},
        {label=it("terminal"),value="terminal"},
        {label=it("modules"),value="modules"},
    }, defaultCategory)
    local role = category
    if category == "modules" then
        title(it("modules"))
        local module = choose(it("select_module"), {
            {label=it("probe"),value="probe"},
            {label=it("guardian"),value="guardian"},
        }, previous and previous.role == "guardian" and 2 or 1, { d = "profiler" })
        if module == "probe" then
            title("Hardware Probe")
            local temporary = "/.helios-probe-run.lua"
            if fs.exists(temporary) then fs.delete(temporary) end
            writeFile(temporary, fetch(BASE_URL .. "/discovery_probe.lua"))
            local ran, probeReason = shell.run(temporary)
            if fs.exists(temporary) then fs.delete(temporary) end
            if not ran then error("Hardware Probe failed: " .. tostring(probeReason), 0) end
            return
        end
        role = module
    end
    local requested, logging = { role }, false
    if language ~= "en_us" then requested[#requested + 1] = "language_" .. language end
    if role == "mainframe" then
        title(it("optional"))
        logging = confirm(it("event_viewer"), previous == nil or not previous.logging or previous.logging.enabled ~= false)
        if logging then requested[#requested + 1] = "captains_log" end
    end
    local renderer = previousUi.renderer or "default"
    if role == "mainframe" or role == "terminal" then
        -- The official GUI is available in HELIOS's GUI selector. Installation
        -- does not choose or activate a GUI on the operator's behalf.
        requested[#requested + 1] = "control_room"
    end
    local display, guardianId
    if role == "terminal" then
        title(it("terminal_config"))
        display = choose(it("select_view"), {
            {label=it("all_systems"),value="all"},{label=it("reactors"),value="reactor"},
            {label=it("turbines"),value="turbine"},{label=it("power_storage"),value="battery"},
        }, 1)
    elseif role == "profiler" then
        title("Profiler Pairing")
        print("Enter the Draconic Guardian computer ID:");write("> ");guardianId = tonumber(read())
        if not guardianId or guardianId < 0 or guardianId ~= math.floor(guardianId) then
            error("Guardian computer ID must be a whole number.", 0)
        end
    end

    local networkEnabled = previous and type(previous.network) == "table" and
        previous.network.securityEnabled == true or false
    local networkKey = ""
    if networkEnabled and type(previous.network.securityKey) == "string" then
        networkKey = previous.network.securityKey
    end
    local modemDetected = false
    for _, name in ipairs(peripheral.getNames()) do
        for _, kind in ipairs({ peripheral.getType(name) }) do
            if kind == "modem" then modemDetected = true break end
        end
        if modemDetected then break end
    end
    if modemDetected then title(it("network")) end
    if modemDetected and confirm(it("enable_network"), networkEnabled) then
        print(networkEnabled and "Enter a new HELIOS network key, or leave blank to keep the current network key:" or
            "Enter the shared HELIOS network key (8-128 characters):")
        write("> ");local entered = read("*")
        if entered ~= "" then
            print("Re-enter the HELIOS network key to verify it:")
            write("> ");local verified = read("*")
            if entered ~= verified then error("The HELIOS network keys do not match. No changes were made.", 0) end
            networkKey = entered
        end
        if #networkKey < 8 or #networkKey > 128 then error("Network keys must contain 8-128 characters.", 0) end
        networkEnabled = true
    elseif modemDetected then networkEnabled = false;networkKey = "" end

    title(it("reading"))
    local manifest = loadManifest();local packageIds = resolvePackages(manifest, requested)
    local files, payloadBytes = packageFiles(manifest, packageIds)
    print(it("role") .. ": " .. role);print(it("packages") .. ": " .. #packageIds);print(it("files") .. ": " .. #files)
    print(it("download") .. ": approximately " .. math.ceil(payloadBytes / 1024) .. " KiB")
    if not confirm(it("install_prompt"), true) then print(it("cancelled"));return end

    local config = configure(previous, role, language, accessibility, logging, renderer, display, guardianId, networkEnabled, networkKey)
    local required, localFree = payloadBytes + (32 * 1024), fs.getFreeSpace("/")
    local stage, mount = LOCAL_STAGE
    if type(localFree) == "number" and localFree < required then
        local external, externalMount = externalStage(required)
        if external then stage, mount = external, externalMount end
    end
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

    if fs.exists(stage) then fs.delete(stage) end;fs.makeDir(stage);title(it("downloading"))
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
    local startup = installStartup();title(it("complete"))
    colour(colors.lime);print("HELIOS " .. VERSION .. " " .. it("installed"));colour(colors.white)
    print(it("installed_only") .. ": " .. table.concat(packageIds, ", "))
    print(startup and it("reboot") or it("run_now"))
end

local ok, reason = pcall(run)
if not ok then colour(colors.red);print("");print(it("failed"));print(tostring(reason));colour(colors.white) end
