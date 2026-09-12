local originalDofile = dofile
local french = {
    id = "fr_ca", name = "Francais (Canada)",
    strings = { ["nav.home"] = "ACCUEIL", ["test.template"] = "Bonjour {name}" },
}

fs = {
    exists = function(path) return path == "/helios/lang" or
        path == "/helios/lang/en_us.lua" or path == "/helios/lang/fr_ca.lua" or
        path == "/helios/lang/en_pi.lua" or path == "/helios/lang/es_es.lua" end,
    isDir = function(path) return path == "/helios/lang" end,
    list = function() return { "fr_ca.lua", "ignored.txt", "en_us.lua", "en_pi.lua", "es_es.lua" } end,
}

dofile = function(path)
    if path == "/helios/lang/en_us.lua" then return originalDofile("src/lang/en_us.lua") end
    if path == "/helios/lang/fr_ca.lua" then return french end
    if path == "/helios/lang/en_pi.lua" then return originalDofile("src/lang/en_pi.lua") end
    if path == "/helios/lang/es_es.lua" then return originalDofile("src/lang/es_es.lua") end
    return originalDofile(path)
end

local i18n = originalDofile("src/core/i18n.lua")
local packs = i18n.available()
assert(#packs == 3 and packs[1].id == "en_us" and packs[2].id == "es_es" and
    packs[3].id == "fr_ca",
    "installed language packs should be discovered and sorted: " ..
    table.concat((function() local ids={} for _, pack in ipairs(packs) do ids[#ids+1]=pack.id end return ids end)(), ","))

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

local english = originalDofile("src/lang/en_us.lua")
local canadianFrench = originalDofile("src/lang/fr_ca.lua")
local pirate = originalDofile("src/lang/en_pi.lua")
local spanish = originalDofile("src/lang/es_es.lua")
for key in pairs(english.strings) do
    assert(type(canadianFrench.strings[key]) == "string", "French pack is missing " .. key)
    assert(type(pirate.strings[key]) == "string", "Pirate pack is missing " .. key)
    assert(type(spanish.strings[key]) == "string", "Spanish pack is missing " .. key)
end

print("i18n tests passed")
