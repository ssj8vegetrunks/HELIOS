local function surface(width, height)
    return {
        write=function() end, blit=function() end, clear=function() end, clearLine=function() end,
        getCursorPos=function() return 1,1 end, setCursorPos=function() end,
        setCursorBlink=function() end, getCursorBlink=function() return false end,
        isColor=function() return true end, getSize=function() return width,height end,
        scroll=function() end, setTextColor=function() end, getTextColor=function() return 1 end,
        setBackgroundColor=function() end, getBackgroundColor=function() return 2 end,
        setPaletteColor=function() end, getPaletteColor=function() return 0,0,0 end,
        getTextScale=function() return 0.5 end, setTextScale=function() end,
    }
end
local native, monitor = surface(51,19), surface(57,38)
local current = native
term = {
    current=function() return native end,
    redirect=function(target) current=target; return native end,
    getSize=function() return current.getSize() end,
}
peripheral = {
    getNames=function() return {"left"} end,
    getType=function() return "monitor" end,
    wrap=function() return monitor end,
}
local display = dofile("src/core/display.lua")
display.start({ui={monitorTextScale=0.5}})
local w,h = term.getSize()
assert(w==51 and h==19, "mirrored built-in canvas must fit the native terminal")
w,h = display.monitorSize()
assert(w==57 and h==38, "custom monitor canvas must expose monitor dimensions")
display.useMonitors(); w,h=term.getSize()
assert(w==57 and h==38, "monitor-only output must use the large canvas")
display.useNative(); w,h=term.getSize()
assert(w==51 and h==19, "native output must restore compact terminal dimensions")
print("dual display tests passed")
