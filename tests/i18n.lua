local originalDofile = dofile
local french = {
    id = "fr_ca", name = "Francais (Canada)",
    strings = { ["nav.home"] = "ACCUEIL", ["test.template"] = "Bonjour {name}" },
}

fs = {
    exists = function(path) return path == "/helios/lang" or
        path == "/helios/lang/en_us.lua" or path == "/helios/lang/fr_ca.lua" end,
    isDir = function(path) return path == "/helios/lang" end,
    list = function() return { "fr_ca.lua", "ignored.txt", "en_us.lua" } end,
}

dofile = function(path)
    if path == "/helios/lang/en_us.lua" then return originalDofile("src/lang/en_us.lua") end
    if path == "/helios/lang/fr_ca.lua" then return french end
    return originalDofile(path)
end

local i18n = originalDofile("src/core/i18n.lua")
local packs = i18n.available()
assert(#packs == 2 and packs[1].id == "en_us" and packs[2].id == "fr_ca",
    "installed language packs should be discovered and sorted")

local language = i18n.new({ ui = { language = "fr_ca" } })
assert(language.get("nav.home") == "ACCUEIL", "selected translations should take precedence")
assert(language.get("nav.power") == "POWER", "missing translations should fall back to English")
assert(language.get("test.template", { name = "Alex" }) == "Bonjour Alex",
    "named placeholders should be substituted")
assert(language.fit("test.template", 8, { name = "Alex" }) == "Bonjo...",
    "long labels should be safely shortened")

local missing = i18n.new({ ui = { language = "zz_zz" } })
assert(missing.id == "en_us" and missing.get("nav.home") == "HOME",
    "missing packs should fail safely to English")

print("i18n tests passed")
