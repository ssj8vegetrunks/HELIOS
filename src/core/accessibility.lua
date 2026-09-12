local accessibility = {}

local PROFILES = { "standard", "deuteranopia", "protanopia", "tritanopia", "high_contrast" }
local VALID = {}
for _, id in ipairs(PROFILES) do VALID[id] = true end

-- CC:Tweaked's palette is configurable per terminal. These palettes preserve
-- HELIOS's semantic colour names while separating warning, fault, information,
-- and healthy states for common colour-vision deficiencies.
local PALETTES = {
    standard = {
        white=0xF0F0F0, orange=0xF2B233, magenta=0xE57FD8, lightBlue=0x99B2F2,
        yellow=0xDEDE6C, lime=0x7FCC19, pink=0xF2B2CC, gray=0x4C4C4C,
        lightGray=0x999999, cyan=0x4C99B2, purple=0xB266E5, blue=0x3366CC,
        brown=0x7F664C, green=0x57A64E, red=0xCC4C4C, black=0x111111,
    },
    deuteranopia = {
        red=0xD55E00, orange=0xE69F00, yellow=0xF0E442, lime=0x56B4E9,
        green=0x0072B2, cyan=0x56B4E9, blue=0x0072B2, magenta=0xCC79A7,
    },
    protanopia = {
        red=0xCC79A7, orange=0xE69F00, yellow=0xF0E442, lime=0x56B4E9,
        green=0x0072B2, cyan=0x56B4E9, blue=0x0072B2, magenta=0xCC79A7,
    },
    tritanopia = {
        red=0xD55E00, orange=0xCC79A7, yellow=0xE69F00, lime=0x009E73,
        green=0x009E73, cyan=0x56B4E9, blue=0x0072B2, magenta=0xCC79A7,
    },
    high_contrast = {
        white=0xFFFFFF, lightGray=0xD0D0D0, gray=0x707070, black=0x000000,
        red=0xFF4040, orange=0xFFAA00, yellow=0xFFFF00, lime=0x40FF40,
        green=0x00C060, cyan=0x00FFFF, lightBlue=0x80C0FF, blue=0x4080FF,
        purple=0xC060FF, magenta=0xFF60FF, pink=0xFF90C0, brown=0xB08050,
    },
}

local function settings(config)
    local ui = type(config) == "table" and type(config.ui) == "table" and config.ui or {}
    local profile = VALID[ui.accessibilityProfile] and ui.accessibilityProfile or "standard"
    return profile, ui.statusSymbols ~= false
end

function accessibility.profiles()
    local result = {}
    for index, id in ipairs(PROFILES) do result[index] = id end
    return result
end

function accessibility.valid(id) return VALID[id] == true end

function accessibility.apply(target, config)
    if not target or type(target.setPaletteColor) ~= "function" then return false end
    local profile = settings(config)
    local palette = {}
    for name, rgb in pairs(PALETTES.standard) do palette[name] = rgb end
    if profile ~= "standard" then
        for name, rgb in pairs(PALETTES[profile]) do palette[name] = rgb end
    end
    for name, rgb in pairs(palette) do
        if colors[name] then pcall(target.setPaletteColor, colors[name], rgb) end
    end
    return true
end

function accessibility.symbols(config)
    local _, enabled = settings(config)
    return enabled
end

function accessibility.marker(level, config)
    if not accessibility.symbols(config) then return "" end
    local markers = {
        critical="[X]", fault="[X]", warning="[!]", caution="[!]",
        healthy="[+]", ready="[+]", information="[i]", inactive="[-]",
    }
    return markers[tostring(level or ""):lower()] or "[*]"
end

function accessibility.levelForColour(colour)
    if colour == colors.red then return "critical" end
    if colour == colors.orange or colour == colors.yellow then return "warning" end
    if colour == colors.lime or colour == colors.green then return "healthy" end
    if colour == colors.gray or colour == colors.lightGray then return "inactive" end
    return "information"
end

function accessibility.decorate(value, level, config)
    value = tostring(value or "")
    if not accessibility.symbols(config) or value:match("^%[[X!+i%*%-]%]%s") then return value end
    return accessibility.marker(level, config) .. " " .. value
end

return accessibility
