local boot = {}

local MARKER = "/helios/data/boot-sequence-complete"

local function pause(seconds)
    if type(sleep) == "function" then sleep(seconds) end
end

local function fit(value, width)
    value = tostring(value or "")
    if #value <= width then return value end
    return width > 3 and value:sub(1, width - 3) .. "..." or value:sub(1, width)
end

local function centered(target, row, value, color)
    local width = select(1, target.getSize())
    value = fit(value, width)
    target.setCursorPos(math.max(1, math.floor((width - #value) / 2) + 1), row)
    target.setTextColor(color or colors.white)
    target.write(value)
end

local function hasPeripheral(fragment)
    fragment = string.lower(fragment)
    for _, name in ipairs(peripheral.getNames()) do
        for _, kind in ipairs({ peripheral.getType(name) }) do
            if string.find(string.lower(tostring(kind or "")), fragment, 1, true) then
                return true
            end
        end
    end
    return false
end

local function checks(config)
    local devices = #peripheral.getNames()
    local role = tostring(config.role or "unknown")
    local statePath = role == "guardian" and "/helios/data/draconic_guardian.lua" or
        "/helios/data/devices.lua"
    return {
        { "CONFIGURATION", type(config) == "table" and config.version ~= nil, role:upper() },
        { "CORE SERVICES", fs.exists("/helios/core/config.lua") and fs.exists("/helios/core/network.lua"), tostring(config.version or "unknown") },
        { "PERIPHERAL BUS", true, tostring(devices) .. " DEVICE" .. (devices == 1 and "" or "S") },
        { "CONTROL NETWORK", hasPeripheral("modem"), hasPeripheral("modem") and "ONLINE" or "LOCAL" },
        { "SAVED STATE", fs.exists(statePath), fs.exists(statePath) and "RESTORED" or "NEW" },
    }
end

local function statusLine(target, row, label, ok, detail)
    local width = select(1, target.getSize())
    local suffix = ok and (detail or "OK") or (detail == "LOCAL" and "LOCAL" or "CHECK")
    local dots = math.max(1, width - #label - #suffix - 3)
    target.setCursorPos(1, row)
    target.setTextColor(colors.lightGray)
    target.write(fit(label .. " " .. string.rep(".", dots) .. " ", math.max(0, width - #suffix)))
    target.setTextColor(ok and colors.lime or colors.orange)
    target.write(fit(suffix, math.min(#suffix, width)))
end

local function logo(target, config, firstBoot)
    local width, height = target.getSize()
    target.setBackgroundColor(colors.black)
    target.setTextColor(colors.white)
    target.clear()
    local top = math.max(1, math.floor(height / 2) - 5)
    centered(target, top, "\\   |   /", colors.orange)
    centered(target, top + 1, "\\  |  /", colors.yellow)
    centered(target, top + 2, "-- [*] --", colors.yellow)
    centered(target, top + 3, "/  |  \\", colors.yellow)
    centered(target, top + 4, "/   |   \\", colors.orange)
    centered(target, top + 6, "H E L I O S", colors.yellow)
    if width >= 48 then
        centered(target, top + 8, "HOLISTIC ENERGY LOGISTICS & INDUSTRIAL OPERATIONS SYSTEM", colors.lightGray)
    else
        centered(target, top + 8, "INDUSTRIAL OPERATIONS SYSTEM", colors.lightGray)
    end
    centered(target, math.min(height, top + 10), firstBoot and "LET THERE BE LIGHT." or
        ("SYSTEM " .. tostring(config.version or "") .. " READY"), colors.lime)
end

function boot.run(config, target)
    target = target or term.current()
    local firstBoot = not fs.exists(MARKER)
    local width = select(1, target.getSize())
    target.setBackgroundColor(colors.black)
    target.setTextColor(colors.white)
    target.clear()
    target.setCursorPos(1, 1)
    target.setTextColor(colors.yellow)
    target.write("HELIOS INITIALIZATION")
    target.setCursorPos(1, 2)
    target.setTextColor(colors.gray)
    target.write(fit("Holistic Energy Logistics & Industrial Operations System", width))

    local report = checks(config)
    local shown = firstBoot and #report or math.min(3, #report)
    for index = 1, shown do
        local item = report[index]
        statusLine(target, index + 3, item[1], item[2], item[3])
        pause(firstBoot and 0.30 or 0.10)
    end
    if firstBoot then
        target.setCursorPos(1, shown + 5)
        target.setTextColor(colors.cyan)
        target.write(fit("FACILITY DISCOVERY COMPLETE", width))
        pause(0.35)
    end
    logo(target, config, firstBoot)
    pause(firstBoot and 1.25 or 0.45)

    if firstBoot then
        local parent = fs.getDir(MARKER)
        if parent ~= "" and not fs.exists(parent) then fs.makeDir(parent) end
        local handle = fs.open(MARKER, "w")
        if handle then handle.write(tostring(os.epoch and os.epoch("utc") or os.clock()));handle.close() end
    end
    target.setBackgroundColor(colors.black)
    target.setTextColor(colors.white)
    target.clear()
    target.setCursorPos(1, 1)
    return report
end

return boot
