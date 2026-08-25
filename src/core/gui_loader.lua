local loader = {}
local ROOT = "/helios/gui"

local function compatible(manifest, coreVersion)
    for _, version in ipairs(manifest.compatibleCoreVersions or {}) do
        if version == coreVersion or version == "*" then return true end
    end
    return false
end

local function inspect(id, coreVersion)
    if type(id) ~= "string" or id == "" or string.find(id, "[^%w_%-]") then
        return nil, "Invalid GUI module id"
    end
    local root = ROOT .. "/" .. id
    local manifestPath = root .. "/manifest.lua"
    if not fs.exists(manifestPath) then return nil, "Missing " .. manifestPath end
    local ok, manifest = pcall(dofile, manifestPath)
    if not ok or type(manifest) ~= "table" then return nil, "Invalid GUI manifest: " .. tostring(manifest) end
    if manifest.id ~= id or type(manifest.name) ~= "string" or
       tonumber(manifest.apiVersion) ~= 1 or type(manifest.entry) ~= "string" or
       string.find(manifest.entry, "..", 1, true) or string.find(manifest.entry, "[/\\]") then
        return nil, "GUI manifest contains invalid metadata"
    end
    if not compatible(manifest, coreVersion) then
        return nil, "GUI module is not compatible with HELIOS " .. tostring(coreVersion)
    end
    manifest.path = root .. "/" .. manifest.entry
    manifest.minimumWidth = math.max(1, math.floor(tonumber(manifest.minimumWidth) or 1))
    manifest.minimumHeight = math.max(1, math.floor(tonumber(manifest.minimumHeight) or 1))
    if not fs.exists(manifest.path) then return nil, "GUI renderer is missing: " .. manifest.path end
    return manifest
end

function loader.scan(coreVersion)
    local modules = {{ id = "default", name = "Built-in Default", apiVersion = 1,
        minimumWidth = 1, minimumHeight = 1, builtin = true }}
    if not fs.exists(ROOT) then return modules end
    for _, id in ipairs(fs.list(ROOT)) do
        if fs.isDir(ROOT .. "/" .. id) then
            local manifest = inspect(id, coreVersion)
            if manifest then modules[#modules + 1] = manifest end
        end
    end
    table.sort(modules, function(a, b)
        if a.builtin then return true end
        if b.builtin then return false end
        return a.name < b.name
    end)
    return modules
end

function loader.resolve(id, coreVersion)
    if id == nil or id == "default" then
        return { id = "default", name = "Built-in Default", builtin = true,
            minimumWidth = 1, minimumHeight = 1 }
    end
    return inspect(id, coreVersion)
end

function loader.load(id, coreVersion, width, height)
    local manifest, reason = loader.resolve(id, coreVersion)
    if not manifest then return nil, reason end
    if manifest.builtin then return nil, "Built-in renderer selected" end
    if width < manifest.minimumWidth or height < manifest.minimumHeight then
        return nil, ("%s requires at least %dx%d characters; this display is %dx%d"):
            format(manifest.name, manifest.minimumWidth, manifest.minimumHeight, width, height)
    end
    local ok, renderer = pcall(dofile, manifest.path)
    if not ok or type(renderer) ~= "table" or type(renderer.render) ~= "function" or
       type(renderer.handle) ~= "function" then
        return nil, "GUI renderer failed to load: " .. tostring(renderer)
    end
    return renderer, manifest
end

function loader.install(baseUrl, coreVersion)
    if not http or not http.get or type(baseUrl) ~= "string" then
        return nil, "HTTP is unavailable or the module URL is invalid"
    end
    baseUrl = string.gsub(baseUrl, "/+$", "")
    local function fetch(url)
        local handle, reason = http.get(url)
        if not handle then return nil, reason end
        local body = handle.readAll()
        handle.close()
        return body
    end
    local manifestText, reason = fetch(baseUrl .. "/manifest.lua")
    if not manifestText then return nil, "Could not download GUI manifest: " .. tostring(reason) end
    local fn, parseReason = load(manifestText, "gui manifest", "t", {})
    if not fn then return nil, "GUI manifest is invalid: " .. tostring(parseReason) end
    local ok, manifest = pcall(fn)
    if not ok or type(manifest) ~= "table" or type(manifest.id) ~= "string" or
       string.find(manifest.id, "[^%w_%-]") or type(manifest.entry) ~= "string" or
       string.find(manifest.entry, "[/\\]") or string.find(manifest.entry, "..", 1, true) then
        return nil, "GUI manifest contains unsafe metadata"
    end
    local rendererText, rendererReason = fetch(baseUrl .. "/" .. manifest.entry)
    if not rendererText then return nil, "Could not download GUI renderer: " .. tostring(rendererReason) end
    local root = ROOT .. "/" .. manifest.id
    if not fs.exists(ROOT) then fs.makeDir(ROOT) end
    if not fs.exists(root) then fs.makeDir(root) end
    local function write(path, body)
        local handle, openReason = fs.open(path, "w")
        if not handle then return false, openReason end
        handle.write(body); handle.close(); return true
    end
    local wrote, writeReason = write(root .. "/manifest.lua", manifestText)
    if not wrote then return nil, writeReason end
    wrote, writeReason = write(root .. "/" .. manifest.entry, rendererText)
    if not wrote then return nil, writeReason end
    local installed, validationReason = inspect(manifest.id, coreVersion)
    if not installed then return nil, validationReason end
    return installed
end

return loader
