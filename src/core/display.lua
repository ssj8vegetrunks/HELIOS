local display = {}

-- @section MONITOR DISCOVERY AND MIRRORING
local native = term.current()
local monitors = {}
local proxy
local monitorProxy
local active = false
local textScale = 0.5

local function isMonitor(name)
    local types = { peripheral.getType(name) }
    for _, peripheralType in ipairs(types) do
        if peripheralType == "monitor" then return true end
    end
    return false
end

local function refreshMonitors()
    local found = {}
    for _, name in ipairs(peripheral.getNames()) do
        if isMonitor(name) then
            local monitor = peripheral.wrap(name)
            if monitor then
                local ok, currentScale = pcall(monitor.getTextScale)
                if not ok or currentScale ~= textScale then
                    pcall(monitor.setTextScale, textScale)
                end
                pcall(monitor.setBackgroundColor, native.getBackgroundColor())
                pcall(monitor.setTextColor, native.getTextColor())
                pcall(monitor.setCursorBlink, native.getCursorBlink())
                found[#found + 1] = monitor
            end
        end
    end
    monitors = found
end

local function mirror(method, ...)
    local results = { native[method](...) }
    for _, monitor in ipairs(monitors) do
        pcall(monitor[method], ...)
    end
    return table.unpack(results)
end

local function monitorMirror(method, ...)
    for _, monitor in ipairs(monitors) do pcall(monitor[method], ...) end
end

local function monitorValue(method, fallback, ...)
    local monitor = monitors[1]
    if monitor then
        local ok, a, b = pcall(monitor[method], ...)
        if ok then return a, b end
    end
    return fallback[method](...)
end

local function buildProxy()
    local target = {}
    target.write = function(...) return mirror("write", ...) end
    target.blit = function(...) return mirror("blit", ...) end
    target.clear = function(...)
        refreshMonitors()
        return mirror("clear", ...)
    end
    target.clearLine = function(...) return mirror("clearLine", ...) end
    target.getCursorPos = function(...) return native.getCursorPos(...) end
    target.setCursorPos = function(...) return mirror("setCursorPos", ...) end
    target.setCursorBlink = function(...) return mirror("setCursorBlink", ...) end
    target.getCursorBlink = function(...) return native.getCursorBlink(...) end
    target.isColor = function(...) return native.isColor(...) end
    target.getSize = function(...)
        local width, height = native.getSize(...)
        for _, monitor in ipairs(monitors) do
            local ok, monitorWidth, monitorHeight = pcall(monitor.getSize)
            if ok then
                width = math.min(width, monitorWidth)
                height = math.min(height, monitorHeight)
            end
        end
        return width, height
    end
    target.scroll = function(...) return mirror("scroll", ...) end
    target.setTextColor = function(...) return mirror("setTextColor", ...) end
    target.getTextColor = function(...) return native.getTextColor(...) end
    target.setTextColour = target.setTextColor
    target.getTextColour = target.getTextColor
    target.setBackgroundColor = function(...) return mirror("setBackgroundColor", ...) end
    target.getBackgroundColor = function(...) return native.getBackgroundColor(...) end
    target.setBackgroundColour = target.setBackgroundColor
    target.getBackgroundColour = target.getBackgroundColor
    target.isColour = target.isColor
    target.setPaletteColor = function(...) return mirror("setPaletteColor", ...) end
    target.getPaletteColor = function(...) return native.getPaletteColor(...) end
    target.setPaletteColour = target.setPaletteColor
    target.getPaletteColour = target.getPaletteColor
    return target
end


local function buildMonitorProxy()
    local target = {}
    target.write = function(...) return monitorMirror("write", ...) end
    target.blit = function(...) return monitorMirror("blit", ...) end
    target.clear = function(...) refreshMonitors(); return monitorMirror("clear", ...) end
    target.clearLine = function(...) return monitorMirror("clearLine", ...) end
    target.getCursorPos = function(...) return monitorValue("getCursorPos", native, ...) end
    target.setCursorPos = function(...) return monitorMirror("setCursorPos", ...) end
    target.setCursorBlink = function(...) return monitorMirror("setCursorBlink", ...) end
    target.getCursorBlink = function(...) return monitorValue("getCursorBlink", native, ...) end
    target.isColor = function(...) return monitorValue("isColor", native, ...) end
    target.getSize = function(...)
        local width, height
        for _, monitor in ipairs(monitors) do
            local ok, monitorWidth, monitorHeight = pcall(monitor.getSize)
            if ok then
                width = width and math.min(width, monitorWidth) or monitorWidth
                height = height and math.min(height, monitorHeight) or monitorHeight
            end
        end
        if not width then return native.getSize(...) end
        return width, height
    end
    target.scroll = function(...) return monitorMirror("scroll", ...) end
    target.setTextColor = function(...) return monitorMirror("setTextColor", ...) end
    target.getTextColor = function(...) return monitorValue("getTextColor", native, ...) end
    target.setTextColour = target.setTextColor
    target.getTextColour = target.getTextColor
    target.setBackgroundColor = function(...) return monitorMirror("setBackgroundColor", ...) end
    target.getBackgroundColor = function(...) return monitorValue("getBackgroundColor", native, ...) end
    target.setBackgroundColour = target.setBackgroundColor
    target.getBackgroundColour = target.getBackgroundColor
    target.isColour = target.isColor
    target.setPaletteColor = function(...) return monitorMirror("setPaletteColor", ...) end
    target.getPaletteColor = function(...) return monitorValue("getPaletteColor", native, ...) end
    target.setPaletteColour = target.setPaletteColor
    target.getPaletteColour = target.getPaletteColor
    return target
end

-- @section DISPLAY LIFECYCLE
function display.start(config)
    if active then return end
    textScale = tonumber(config and config.ui and config.ui.monitorTextScale) or 0.5
    textScale = math.max(0.5, math.min(5, textScale))
    refreshMonitors()
    proxy = buildProxy()
    monitorProxy = buildMonitorProxy()
    term.redirect(proxy)
    active = true
end

function display.useNative()
    term.redirect(native)
end

function display.useMonitors()
    refreshMonitors()
    term.redirect(monitorProxy)
end

function display.useMirrored()
    refreshMonitors()
    term.redirect(proxy)
end

function display.monitorSize()
    refreshMonitors()
    if #monitors == 0 then return nil end
    return monitorProxy.getSize()
end

function display.stop()
    if not active then return end
    term.redirect(native)
    active = false
end

function display.count()
    refreshMonitors()
    return #monitors
end

return display
