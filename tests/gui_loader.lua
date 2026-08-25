local nativeDofile = dofile
fs = {
    exists = function(path)
        return path == "/helios/gui" or path == "/helios/gui/control-room" or
            path == "/helios/gui/control-room/manifest.lua" or
            path == "/helios/gui/control-room/renderer.lua"
    end,
    list = function() return { "control-room" } end,
    isDir = function(path) return path == "/helios/gui/control-room" end,
}
local loader = nativeDofile("src/core/gui_loader.lua")
dofile = function(path)
    if path == "/helios/gui/control-room/manifest.lua" then
        return { id="control-room", name="Control Room", apiVersion=1,
            compatibleCoreVersions={"1.6.0-alpha.4"}, entry="renderer.lua",
            minimumWidth=50, minimumHeight=31 }
    elseif path == "/helios/gui/control-room/renderer.lua" then
        return { render=function() end, handle=function() end }
    end
    return nativeDofile(path)
end

local modules = loader.scan("1.6.0-alpha.4")
assert(#modules == 2 and modules[1].id == "default" and modules[2].id == "control-room",
    "scanner must include built-in and installed GUI modules")
local renderer, manifest = loader.load("control-room", "1.6.0-alpha.4", 50, 31)
assert(renderer and manifest.id == "control-room", "compatible large display must load module")
renderer = loader.load("control-room", "1.6.0-alpha.4", 49, 31)
assert(renderer == nil, "undersized display must reject custom module")
local missing = loader.resolve("missing", "1.6.0-alpha.4")
assert(missing == nil, "missing module must fail closed")
dofile = nativeDofile
print("GUI loader tests passed")
