-- HELIOS single-file installer
-- Milestone 1: role selection, persistent configuration, and role-aware boot.

local VERSION = "0.1.0-alpha.1"
local INSTALL_DIR = "/helios"
local STAGE_DIR = "/.helios-install"

local function clear()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
end

local function title(subtitle)
    clear()
    term.setTextColor(colors.yellow)
    print("HELIOS")
    term.setTextColor(colors.lightGray)
    print("Industrial Power Management Suite")
    term.setTextColor(colors.gray)
    print(subtitle or "")
    term.setTextColor(colors.white)
    print("")
end

local function choose(prompt, options)
    while true do
        print(prompt)
        for index, option in ipairs(options) do
            print(("  [%d] %s"):format(index, option.label))
        end
        term.setTextColor(colors.yellow)
        write("> ")
        term.setTextColor(colors.white)
        local answer = read()
        local selected = tonumber(answer)
        if selected and options[selected] then
            return options[selected].value
        end
        term.setTextColor(colors.red)
        print("Please enter a number from the list.")
        term.setTextColor(colors.white)
    end
end

local function confirm(prompt)
    write(prompt .. " [y/N] ")
    local answer = read():lower()
    return answer == "y" or answer == "yes"
end

local function writeFile(path, contents)
    local parent = fs.getDir(path)
    if parent ~= "" and not fs.exists(parent) then
        fs.makeDir(parent)
    end
    local handle, reason = fs.open(path, "w")
    if not handle then error("Could not write " .. path .. ": " .. tostring(reason), 0) end
    handle.write(contents)
    handle.close()
end

local FILES = {
    ["helios.lua"] = [=[
local args = { ... }
local config = dofile("/helios/core/config.lua").load()

if args[1] == "status" then
    print("HELIOS " .. tostring(config.version))
    print("Role: " .. tostring(config.role))
    if config.role == "terminal" then
        print("Display: " .. tostring(config.display))
    end
    print("Computer ID: " .. tostring(config.computerId))
    return
end

if config.role == "mainframe" then
    dofile("/helios/mainframe/main.lua").run(config)
elseif config.role == "terminal" then
    dofile("/helios/terminal/main.lua").run(config)
else
    error("Unknown HELIOS role in /helios/config.lua: " .. tostring(config.role), 0)
end
]=],

    ["core/config.lua"] = [=[
local config = {}

function config.load()
    if not fs.exists("/helios/config.lua") then
        error("HELIOS configuration is missing. Run the installer again.", 0)
    end
    local loaded = dofile("/helios/config.lua")
    if type(loaded) ~= "table" then
        error("HELIOS configuration is invalid.", 0)
    end
    if loaded.role ~= "mainframe" and loaded.role ~= "terminal" then
        error("HELIOS configuration contains an invalid role.", 0)
    end
    return loaded
end

return config
]=],

    ["core/ui.lua"] = [=[
local ui = {}

function ui.prepare()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
end

function ui.header(role, subtitle)
    ui.prepare()
    term.setTextColor(colors.yellow)
    print("HELIOS // " .. string.upper(role))
    term.setTextColor(colors.lightGray)
    print(subtitle)
    term.setTextColor(colors.gray)
    print(string.rep("-", math.min(select(1, term.getSize()), 40)))
    term.setTextColor(colors.white)
end

function ui.status(label, value, colour)
    term.setTextColor(colors.lightGray)
    write(label .. ": ")
    term.setTextColor(colour or colors.white)
    print(tostring(value))
    term.setTextColor(colors.white)
end

function ui.waitForExit(render)
    while true do
        local event, key = os.pullEvent()
        if event == "key" and key == keys.q then
            ui.prepare()
            return
        elseif event == "term_resize" then
            render()
        end
    end
end

return ui
]=],

    ["mainframe/main.lua"] = [=[
local mainframe = {}

function mainframe.run(config)
    local ui = dofile("/helios/core/ui.lua")
    local function render()
        ui.header("MAINFRAME", "Central control authority")
        ui.status("System", "ONLINE", colors.lime)
        ui.status("Computer ID", config.computerId)
        ui.status("Device registry", "Not configured", colors.orange)
        ui.status("Network protocol", "Next milestone", colors.orange)
        print("")
        term.setTextColor(colors.gray)
        print("Press Q to exit HELIOS.")
    end
    render()
    ui.waitForExit(render)
end

return mainframe
]=],

    ["terminal/main.lua"] = [=[
local terminal = {}

function terminal.run(config)
    local ui = dofile("/helios/core/ui.lua")
    local function render()
        ui.header("REMOTE TERMINAL", "Mainframe-restricted display")
        ui.status("System", "ONLINE", colors.lime)
        ui.status("Computer ID", config.computerId)
        ui.status("Display assignment", string.upper(config.display or "all"), colors.cyan)
        ui.status("Mainframe link", "Awaiting protocol", colors.orange)
        print("")
        term.setTextColor(colors.gray)
        print("This terminal has no device-control authority.")
        print("Press Q to exit HELIOS.")
    end
    render()
    ui.waitForExit(render)
end

return terminal
]=],
}

local function installStartup()
    if fs.exists("/startup") and not fs.isDir("/startup") then
        print("An existing /startup program was found.")
        print("HELIOS can preserve it as /startup/00-user.lua.")
        if not confirm("Convert startup to a startup directory?") then
            return false, "Autostart was skipped; run 'helios' manually."
        end
        local oldStartup = "/.helios-existing-startup.lua"
        if fs.exists(oldStartup) then fs.delete(oldStartup) end
        fs.move("/startup", oldStartup)
        fs.makeDir("/startup")
        fs.move(oldStartup, "/startup/00-user.lua")
    elseif not fs.exists("/startup") then
        fs.makeDir("/startup")
    end

    writeFile("/startup/99-helios.lua", [=[
if fs.exists("/helios/helios.lua") then
    shell.run("/helios/helios.lua")
end
]=])
    return true
end

local function buildConfig(role, display)
    return ("return {\n" ..
        "    version = %q,\n" ..
        "    role = %q,\n" ..
        "    display = %s,\n" ..
        "    computerId = %d,\n" ..
        "}\n"):format(
            VERSION,
            role,
            display and string.format("%q", display) or "nil",
            os.getComputerID()
        )
end

local function runInstaller()
    title("Installer " .. VERSION)
    local role = choose("Select this computer's role:", {
        { label = "Mainframe", value = "mainframe" },
        { label = "Remote Terminal", value = "terminal" },
    })

    local display
    if role == "terminal" then
        title("Remote Terminal Configuration")
        display = choose("Select the information this terminal will request:", {
            { label = "Reactor", value = "reactor" },
            { label = "Turbine", value = "turbine" },
            { label = "Battery", value = "battery" },
            { label = "All systems overview", value = "all" },
        })
    end

    title("Ready to Install")
    print("Role: " .. role)
    if display then print("Display: " .. display) end
    print("Location: " .. INSTALL_DIR)
    print("")
    if not confirm("Install HELIOS?") then
        print("Installation cancelled.")
        return
    end

    if fs.exists(STAGE_DIR) then fs.delete(STAGE_DIR) end
    fs.makeDir(STAGE_DIR)
    for relativePath, contents in pairs(FILES) do
        writeFile(fs.combine(STAGE_DIR, relativePath), contents)
    end
    writeFile(fs.combine(STAGE_DIR, "config.lua"), buildConfig(role, display))

    local previousInstall
    if fs.exists(INSTALL_DIR) then
        previousInstall = "/helios.previous"
        if fs.exists(previousInstall) then
            error("Cannot preserve the current install: " .. previousInstall .. " already exists.", 0)
        end
        fs.move(INSTALL_DIR, previousInstall)
    end

    local ok, reason = pcall(function()
        fs.move(STAGE_DIR, INSTALL_DIR)
        writeFile("/helios.lua", [=[
shell.run("/helios/helios.lua", ...)
]=])
    end)
    if not ok then
        if fs.exists(INSTALL_DIR) then fs.delete(INSTALL_DIR) end
        if previousInstall and fs.exists(previousInstall) then fs.move(previousInstall, INSTALL_DIR) end
        error("Installation failed and the previous install was restored: " .. tostring(reason), 0)
    end

    local autoStarted, startupNote = installStartup()

    title("Installation Complete")
    term.setTextColor(colors.lime)
    print("HELIOS " .. VERSION .. " installed successfully.")
    term.setTextColor(colors.white)
    print("Role: " .. role)
    if display then print("Display: " .. display) end
    if previousInstall then print("Previous version: " .. previousInstall) end
    if autoStarted then
        print("HELIOS will start automatically after reboot.")
    else
        print(startupNote)
    end
    print("")
    print("Run now with: helios")
    print("Check setup with: helios status")
end

local ok, reason = pcall(runInstaller)
if not ok then
    term.setTextColor(colors.red)
    print("")
    print("HELIOS installation failed:")
    print(tostring(reason))
    term.setTextColor(colors.white)
end
