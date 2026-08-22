-- @section MODULE PACK DOWNLOAD AND VALIDATION
local manager = {}
local BASE_URL = "https://raw.githubusercontent.com/ssj8vegetrunks/HELIOS/agent/alpha14-release/module-pack"
local MODULE_DIR = "/helios/modules"
local STAGE_DIR = "/.helios-module-update"
local BACKUP_DIR = "/helios/modules.previous"

local function fetchText(url)
    if not http or not http.get then
        return nil, "CC:Tweaked HTTP is disabled"
    end
    local handle, reason = http.get(url)
    if not handle then return nil, tostring(reason) end
    local contents = handle.readAll()
    handle.close()
    return contents
end

local function writeFile(path, contents)
    local parent = fs.getDir(path)
    if parent ~= "" and not fs.exists(parent) then fs.makeDir(parent) end
    local handle, reason = fs.open(path, "w")
    if not handle then return false, reason end
    local wrote, writeReason = pcall(handle.write, contents)
    local closed, closeReason = pcall(handle.close)
    if not wrote or not closed then
        if fs.exists(path) then pcall(fs.delete, path) end
        return false, tostring(wrote and closeReason or writeReason)
    end
    return true
end

local function safeRelativePath(path)
    return type(path) == "string" and path ~= "" and
        string.sub(path, 1, 1) ~= "/" and
        not string.find(path, "..", 1, true) and
        not string.find(path, "\\", 1, true)
end

local function validateManifest(manifest)
    if type(manifest) ~= "table" or manifest.schema_version ~= 1 or
       type(manifest.pack) ~= "table" or type(manifest.pack.version) ~= "string" or
       type(manifest.compatible_core_versions) ~= "table" or
       type(manifest.modules) ~= "table" then
        return false, "Downloaded Module Pack manifest is invalid"
    end
    local moduleIds, capabilities = {}, {}
    for _, module in ipairs(manifest.modules) do
        if type(module) ~= "table" or type(module.id) ~= "string" or module.id == "" or
           type(module.name) ~= "string" or type(module.version) ~= "string" or
           type(module.provides) ~= "table" then
            return false, "Downloaded Module Pack contains invalid module metadata"
        end
        if moduleIds[module.id] then
            return false, "Downloaded Module Pack duplicates module id " .. module.id
        end
        moduleIds[module.id] = true
        for _, provider in ipairs(module.provides) do
            if type(provider) ~= "table" or type(provider.capability) ~= "string" or
               provider.capability == "" or not safeRelativePath(provider.path) then
                return false, "Downloaded Module Pack contains an invalid capability provider"
            end
            if capabilities[provider.capability] then
                return false, "Downloaded Module Pack duplicates capability " .. provider.capability
            end
            capabilities[provider.capability] = true
        end
    end
    return true
end

local function compatible(manifest, coreVersion)
    for _, version in ipairs(manifest.compatible_core_versions or {}) do
        if version == coreVersion then return true end
    end
    return false
end

local function download(coreVersion)
    local encoded, reason = fetchText(BASE_URL .. "/manifest.json")
    if not encoded then return nil, "Could not download Module Pack manifest: " .. reason end
    local ok, manifest = pcall(textutils.unserializeJSON, encoded)
    if not ok or type(manifest) ~= "table" then
        return nil, "Downloaded Module Pack manifest is invalid"
    end
    local valid, validationReason = validateManifest(manifest)
    if not valid then return nil, validationReason end
    if not compatible(manifest, coreVersion) then
        return nil, "Module Pack " .. tostring(manifest.pack.version or "unknown") ..
            " is incompatible with HELIOS Core " .. tostring(coreVersion)
    end

    if fs.exists(STAGE_DIR) then fs.delete(STAGE_DIR) end
    fs.makeDir(STAGE_DIR)
    local downloaded = {}
    for _, module in ipairs(manifest.modules) do
        for _, provider in ipairs(module.provides or {}) do
            local path = provider.path
            if not safeRelativePath(path) then
                fs.delete(STAGE_DIR)
                return nil, "Module Pack contains an unsafe path: " .. tostring(path)
            end
            if not downloaded[path] then
                local contents, fileReason = fetchText(BASE_URL .. "/" .. path)
                if not contents then
                    fs.delete(STAGE_DIR)
                    return nil, "Could not download " .. path .. ": " .. tostring(fileReason)
                end
                local wrote, writeReason = writeFile(fs.combine(STAGE_DIR, path), contents)
                if not wrote then
                    fs.delete(STAGE_DIR)
                    return nil, "Could not stage " .. path .. ": " .. tostring(writeReason)
                end
                downloaded[path] = true
            end
        end
    end
    local wrote, writeReason = writeFile(fs.combine(STAGE_DIR, "manifest.json"), encoded)
    if not wrote then
        fs.delete(STAGE_DIR)
        return nil, "Could not stage manifest: " .. tostring(writeReason)
    end
    return manifest
end

-- @section ATOMIC MODULE PACK UPDATE
function manager.update(coreVersion)
    local manifest, reason = download(coreVersion)
    if not manifest then return false, reason end
    if fs.exists(BACKUP_DIR) then fs.delete(BACKUP_DIR) end
    if fs.exists(MODULE_DIR) then fs.move(MODULE_DIR, BACKUP_DIR) end
    local ok, moveReason = pcall(fs.move, STAGE_DIR, MODULE_DIR)
    if not ok then
        if fs.exists(MODULE_DIR) then fs.delete(MODULE_DIR) end
        if fs.exists(BACKUP_DIR) then fs.move(BACKUP_DIR, MODULE_DIR) end
        return false, "Module Pack update rolled back: " .. tostring(moveReason)
    end
    if fs.exists(BACKUP_DIR) then fs.delete(BACKUP_DIR) end
    return true, manifest.pack.version
end

return manager
